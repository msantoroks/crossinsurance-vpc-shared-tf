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

Before any resource is created, the module runs a **CIDR validation** step
(`data.external` → Python script in `validate` mode):

- Checks that every subnet CIDR fits inside `vpc_cidr`.
- Downloads the central registry from GCS and verifies there are no VPC CIDR overlaps across environments.

After validation passes, a **`null_resource`** runs the Python script in `apply`
mode:

1. Downloads `cidr-registry.txt` from GCS.
2. Removes any existing rows for this `peer_env`.
3. Appends the current VPC + subnet rows.
4. Uploads the merged file back to GCS.

On **`terraform destroy`** (or resource replacement), the destroy provisioner:

1. Downloads `cidr-registry.txt` from GCS.
2. Removes all rows belonging to this `peer_env`.
3. Uploads the cleaned file back to GCS.

The `null_resource` triggers include `peer_env`, `project_id`, `vpc_cidr`,
`subnets` (SHA-256), bucket, and object — any change replaces the resource
(destroy old rows, then apply new ones).

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
