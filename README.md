# Cross Insurance — GCP Infrastructure

Terraform mono-repo for the **Cross Insurance** workloads on Google Cloud.
Each environment lives in its own stack directory and shares a single reusable
module (`modules/blueprint`).

## Repository layout

```
├── dev/                          # Development stack
├── stg/                          # Staging stack
├── prod/                         # Production stack
│   ├── config/
│   │   └── environments.yaml     # Shared + workload definitions (project, region, CIDR, subnets)
│   ├── credentials/              # SA key (local.json) — git-ignored
│   ├── scripts/
│   │   ├── connect-project.sh    # Optional: set gcloud project from SA key or YAML
│   │   └── ensure_state_bucket.sh# Create the remote-state GCS bucket if missing
│   ├── deploy.sh                 # Wrapper: init → plan / apply / destroy
│   ├── locals.tf                 # Reads environments.yaml
│   ├── main.tf                   # Calls module "workload" (blueprint)
│   ├── outputs.tf
│   ├── variables.tf
│   ├── versions.tf               # Terraform + provider versions, GCS backend
│   ├── terraform.tfvars          # Stack variables — git-ignored
│   └── terraform.tfvars.example  # Template (committed)
└── modules/
    └── blueprint/                # Reusable environment module
        ├── main.tf               # Orchestrates sub-modules (project_services → vpc → peering)
        ├── cidr_validation.tf    # data.external: geometry + overlap checks via Python
        ├── cidr_registry_gcs.tf  # null_resource: apply merges CIDR rows → GCS; destroy removes them
        ├── variables.tf
        ├── outputs.tf
        ├── terraform.tf          # Required providers (google, external, null)
        ├── scripts/
        │   ├── cidr_registry_gcs_sync.py   # validate | apply | destroy
        │   └── requirements-cidr.txt
        └── modules/
            ├── project_services/  # Enables GCP APIs (compute, IAM, etc.)
            ├── vpc/               # VPC + subnets + optional Shared VPC host/service attachment
            └── peering/           # Bidirectional VPC peering (workload ↔ shared)
```

## GCP projects

| Environment | Project ID                        | VPC CIDR       |
|-------------|-----------------------------------|----------------|
| shared      | `ks-crossinsurance-proj-test-sh`  | 10.0.0.0/16    |
| dev         | `ks-crossinsurance-proj-test-01`  | 10.20.0.0/16   |
| stg         | `ks-crossinsurance-proj-test-02`  | 10.30.0.0/16   |
| prd         | `ks-crossinsurance-proj-test-03`  | 10.40.0.0/16   |

> CIDRs are defined in each stack's `config/environments.yaml` and validated
> against the central GCS registry before any resource is created.

## Prerequisites

- **Terraform** ≥ 1.14 (see `.tool-versions`)
- **Python 3** on `$PATH` (used by the CIDR validator / GCS sync script)
- **Google Cloud SDK** (`gcloud`) or `pip install google-cloud-storage`
- A **service account key** (or Application Default Credentials) with the necessary IAM roles

## Quick start

```bash
# 1. Place your SA key
cp /path/to/sa-key.json dev/credentials/local.json

# 2. Copy the tfvars template
cp dev/terraform.tfvars.example dev/terraform.tfvars

# 3. Plan
cd dev
./deploy.sh plan

# 4. Apply
./deploy.sh apply
```

Repeat for `stg/` and `prod/`.

## deploy.sh

Each stack has an identical `deploy.sh` that:

1. Resolves credentials (`credentials/local.json` or `$GOOGLE_APPLICATION_CREDENTIALS`).
2. Optionally creates the remote-state GCS bucket (`RUN_ENSURE_BUCKET=1`).
3. Runs `terraform init -reconfigure` with the correct bucket and prefix.
4. Executes the requested action (`plan`, `apply`, `destroy`, `validate`, `output`, `unlock`).

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_STATE_BUCKET` | `ks-crossinsurance-proj-test-terraform-state` | GCS bucket for remote state |
| `BACKEND_PREFIX` | `terraform-state/workloads/<stack>` | Object prefix inside the bucket |
| `DEPLOY_CREDENTIALS` | `local` | Filename (without `.json`) inside `credentials/` |
| `SKIP_GCLOUD` | `1` | Skip `gcloud config set project` |
| `CLEAN_TF` | `0` | Delete `.terraform/` before init |
| `RUN_ENSURE_BUCKET` | `0` | Create the state bucket if it does not exist |

## Remote state

Each stack stores its state in the **same GCS bucket** under a separate prefix:

```
gs://<TF_STATE_BUCKET>/terraform-state/workloads/dev/
gs://<TF_STATE_BUCKET>/terraform-state/workloads/stg/
gs://<TF_STATE_BUCKET>/terraform-state/workloads/prod/
```

## The blueprint module

`modules/blueprint` is called by every stack as `module "workload"`.
It creates, in order:

1. **project_services** — enables required GCP APIs.
2. **vpc** — creates the VPC, subnets, and optionally manages Shared VPC host/service attachment.
3. **peering** — establishes bidirectional VPC peering between the workload VPC and the shared VPC.

### CIDR validation & registry

Every environment must declare a non-overlapping VPC CIDR and subnet ranges.
The module enforces this automatically through a two-phase process backed by a
**central registry file** stored in GCS (`cidr-registry.txt`).

#### Registry file format

The registry is a plain-text file with one allocation per line:

```
cidr|project_id|environment|resource
```

Example:

```
10.0.0.0/16|ks-crossinsurance-proj-test-sh|shared|vpc
10.0.1.0/24|ks-crossinsurance-proj-test-sh|shared|subnet:subnet-shared-a
10.20.0.0/16|ks-crossinsurance-proj-test-01|dev|vpc
10.20.1.0/24|ks-crossinsurance-proj-test-01|dev|subnet:sn-dev-01
10.30.0.0/16|ks-crossinsurance-proj-test-02|stg|vpc
10.30.1.0/24|ks-crossinsurance-proj-test-02|stg|subnet:sn-stg-01
10.40.0.0/16|ks-crossinsurance-proj-test-03|prd|vpc
10.40.1.0/24|ks-crossinsurance-proj-test-03|prd|subnet:sn-prd-01
```

The file lives at `gs://<cidr_registry_gcs_bucket>/<cidr_registry_gcs_object>`
(defaults to `cidr-registry.txt` inside the shared project bucket).

#### Phase 1 — Validation (`data.external`, runs on every plan)

Before any resource is created the module invokes a Python script
(`cidr_registry_gcs_sync.py validate`) via `data.external`. This step:

1. **Parses `vpc_cidr` and `subnets`** from the Terraform variables.
2. **Validates subnet geometry** — every subnet CIDR must be a valid IPv4
   network that fits entirely inside `vpc_cidr`.
3. **Downloads the current registry** from GCS (or starts empty if the object
   does not exist yet).
4. **Simulates a merge** — removes any existing rows for this `peer_env` and
   appends the new VPC + subnet rows.
5. **Checks for VPC CIDR overlap** — compares every pair of VPC rows across
   different environments. If any two VPC ranges overlap, the plan fails
   immediately with a clear error message:

   ```
   VPC CIDR overlap: 10.20.0.0/16 (dev) vs 10.20.0.0/16 (stg)
   ```

If `cidr_registry_gcs_bucket` is `null`, only local geometry checks (step 2)
are performed and the GCS download is skipped.

#### Phase 2 — GCS sync (`null_resource`, runs on apply / destroy)

After validation passes, a `null_resource` with `local-exec` provisioners
manages the registry file:

**On `terraform apply`** (or resource replacement):

1. Downloads `cidr-registry.txt` from GCS.
2. Removes any existing rows for this `peer_env`.
3. Appends the current VPC + subnet rows.
4. Re-runs the overlap check on the merged result.
5. Uploads the updated file back to GCS.

**On `terraform destroy`** (or resource replacement — destroy runs first):

1. Downloads `cidr-registry.txt` from GCS.
2. Removes all rows belonging to this `peer_env`.
3. Uploads the cleaned file back to GCS.

The `null_resource` triggers include `peer_env`, `project_id`, `vpc_cidr`,
`subnets` (SHA-256), bucket, object, and the script hash — any change replaces
the resource (destroy old rows first, then apply new ones).

#### Sequence diagram

```
terraform plan
  │
  ├─ data.external "cidr_registry_validation"
  │    └─ python3 cidr_registry_gcs_sync.py validate
  │         ├─ validate subnet ⊂ vpc_cidr
  │         ├─ download gs://bucket/cidr-registry.txt
  │         ├─ simulate merge (remove old peer_env rows, add new)
  │         ├─ check VPC overlap across all environments
  │         └─ return { valid: "true" }   ← plan continues
  │                                        (or fails with overlap error)
  │
terraform apply
  │
  ├─ module.project_services  (depends on validation token)
  │
  ├─ null_resource.cidr_registry_gcs  (depends on validation)
  │    └─ provisioner "local-exec" (apply)
  │         ├─ download gs://bucket/cidr-registry.txt
  │         ├─ remove old peer_env rows
  │         ├─ append new VPC + subnet rows
  │         ├─ verify no overlap
  │         └─ upload merged file to GCS
  │
  ├─ module.vpc
  └─ module.peering

terraform destroy
  │
  └─ null_resource.cidr_registry_gcs
       └─ provisioner "local-exec" (when = destroy)
            ├─ download gs://bucket/cidr-registry.txt
            ├─ remove all rows for this peer_env
            └─ upload cleaned file to GCS
```

#### GCS access

The Python script tries to use the `google-cloud-storage` library first (fast,
native). If not installed, it falls back to `gcloud storage cp` / `gsutil cp`
on `$PATH`. Install the library with:

```bash
pip install -r modules/blueprint/scripts/requirements-cidr.txt
```

If the registry object does not exist yet (first apply on a new bucket), the
script treats it as an empty file and creates it on upload.

### Module inputs

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `project_id` | `string` | yes | Workload GCP project ID |
| `vpc_name` | `string` | yes | VPC name to create |
| `subnets` | `list(object)` | yes | Subnets (`name`, `region`, `cidr`) |
| `shared_project_id` | `string` | yes | Shared/host project ID |
| `peer_env` | `string` | yes | Environment name (`dev`, `stg`, `prd`) |
| `host_vpc_name` | `string` | yes | VPC name in the shared project |
| `vpc_cidr` | `string` | yes | VPC CIDR block |
| `attach_shared_vpc_service_project` | `bool` | yes | Attach as Shared VPC service project |
| `cidr_registry_gcs_bucket` | `string` | no | GCS bucket for the CIDR registry (`null` = skip) |
| `cidr_registry_gcs_object` | `string` | no | Object name (default: `cidr-registry.txt`) |
| `cidr_python_executable` | `string` | no | Python binary (default: `python3`) |
| `name_prefix` | `string` | no | Peering name prefix |

### Module outputs

| Output | Description |
|--------|-------------|
| `project_id` | Workload project ID |
| `network_self_link` | VPC self-link |
| `subnet_self_links` | Map of subnet self-links |
| `cidr_registry_gcs_uri` | `gs://` URI of the CIDR registry object |

## environments.yaml

Each stack reads its own `config/environments.yaml`. The file contains exactly
two entries: `shared` (the host project) and the workload for that stack.

```yaml
environments:
  - name: shared
    project_id: ks-crossinsurance-proj-test-sh
    region: us-central1
    vpc_name: vpc-shared

  - name: dev
    project_id: ks-crossinsurance-proj-test-01
    region: us-central1
    vpc_name: vpc-dev
    vpc_cidr: 10.20.0.0/16
    subnets:
      - name: sn-dev-01
        region: us-central1
        cidr: 10.20.1.0/24
```

## Using the module from another repo

See `modules/blueprint/main.git.tf.example` for an example of calling the
module via a Git source:

```hcl
module "workload" {
  source = "git::https://github.com/<org>/crossinsurance-modules.git//blueprint?ref=main"
  # ...
}
```

Ensure `python3` is available and install the optional GCS library:

```bash
pip install -r modules/blueprint/scripts/requirements-cidr.txt
```
