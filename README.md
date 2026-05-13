# Cross Insurance — GCP Infrastructure

Terraform mono-repo for the **Cross Insurance** workloads on Google Cloud.
Each environment lives in its own stack directory and shares a single reusable
module (`modules/blueprint`).

## Repository layout

```
├── test-01/                       # Workload stack (one directory per project)
├── test-02/
├── test-03/
├── test-04/
│   ├── config/
│   │   ├── environments.yaml      # Shared + workload definitions (project, region, CIDR, subnets)
│   │   └── README.md
│   ├── credentials/               # SA key (local.json) — git-ignored
│   ├── scripts/
│   │   ├── connect-project.sh     # Optional: set gcloud project from SA key or YAML
│   │   └── ensure_state_bucket.sh # Create the remote-state GCS bucket if missing
│   ├── deploy.sh                  # Wrapper: init → plan / apply / destroy
│   ├── locals.tf                  # Reads environments.yaml
│   ├── main.tf                    # Calls module "workload" (blueprint)
│   ├── outputs.tf
│   ├── variables.tf
│   ├── versions.tf                # Terraform + provider versions, GCS backend
│   ├── terraform.tfvars           # Stack variables — git-ignored
│   └── terraform.tfvars.example   # Template (committed)
├── cloudbuild-plan.yaml           # CI: terraform plan (auto on push to main)
├── cloudbuild-apply.yaml          # CI: terraform apply (manual + require approval)
├── docs/
│   └── cross-cloudbuild-setup.md  # Step-by-step Cloud Build setup per project
└── modules/
    └── blueprint/                 # Reusable environment module
        ├── main.tf                # Orchestrates sub-modules (project_services → vpc → peering)
        ├── cidr_validation.tf     # data.external: geometry + overlap checks via Python
        ├── cidr_registry_gcs.tf   # null_resource: apply merges CIDR rows → GCS; destroy removes them
        ├── variables.tf
        ├── outputs.tf
        ├── terraform.tf           # Required providers (google, external, null)
        ├── scripts/
        │   ├── cidr_registry_gcs_sync.py   # validate | apply | destroy
        │   └── requirements-cidr.txt
        └── modules/
            ├── project_services/  # Enables GCP APIs (compute, IAM, etc.)
            ├── vpc/               # VPC + subnets + optional Shared VPC host/service attachment
            └── peering/           # Bidirectional VPC peering (workload ↔ shared)
```

## GCP projects

| Stack    | Workload project ID                | VPC name      | VPC CIDR        |
|----------|------------------------------------|---------------|-----------------|
| shared   | `ks-crossinsurance-proj-test-sh`   | `vpc-shared`  | 10.0.0.0/16     |
| test-01  | `ks-crossinsurance-proj-test-01`   | `vpc-test-01` | 10.20.0.0/16    |
| test-02  | `ks-crossinsurance-proj-test-02`   | `vpc-test-02` | 10.30.0.0/16    |
| test-03  | `ks-crossinsurance-proj-test-03`   | `vpc-test-03` | 10.40.0.0/16    |
| test-04  | `ks-crossinsurance-proj-test-04`   | `vpc-test-04` | 10.50.0.0/16    |

> CIDRs are defined in each stack's `config/environments.yaml` and validated
> against the central GCS registry before any resource is created.

## Prerequisites

- **Terraform** ≥ 1.14 (see `.tool-versions`)
- **Python 3** on `$PATH` (used by the CIDR validator / GCS sync script)
- **Google Cloud SDK** (`gcloud`) or `pip install google-cloud-storage`
- A **service account key** (or Application Default Credentials) with the necessary IAM roles

## Quick start (local)

```bash
# 1. Place your SA key
cp /path/to/sa-key.json test-01/credentials/local.json

# 2. (Optional) Copy the tfvars template
cp test-01/terraform.tfvars.example test-01/terraform.tfvars

# 3. Plan
cd test-01
./deploy.sh plan

# 4. Apply
./deploy.sh apply
```

Repeat for `test-02/`, `test-03/`, `test-04/`.

## deploy.sh

Each stack ships an identical `deploy.sh` that:

1. Resolves credentials (`credentials/local.json`, `$GOOGLE_APPLICATION_CREDENTIALS`,
   or ADC when `BUILD_ID` / `USE_ADC=1` is set — i.e. inside Cloud Build).
2. Optionally creates the remote-state GCS bucket (`RUN_ENSURE_BUCKET=1`).
3. Runs `terraform init -reconfigure` with the correct bucket and prefix
   (`terraform-state/workloads/<stack>`).
4. Executes the requested action (`plan`, `apply`, `destroy`, `validate`,
   `output`, `unlock`). In CI (`BUILD_ID` set) `apply`/`destroy` get
   `-auto-approve` automatically.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_STATE_BUCKET` | `ks-crossinsurance-proj-test-terraform-state` | GCS bucket for remote state |
| `BACKEND_PREFIX` | `terraform-state/workloads/<stack>` | Object prefix inside the bucket |
| `DEPLOY_CREDENTIALS` | `local` | Filename (without `.json`) inside `credentials/` |
| `USE_ADC` | `0` | Force Application Default Credentials (skip key file lookup) |
| `TF_AUTO_APPROVE` | `0` | Force `-auto-approve` on apply/destroy outside CI |
| `SKIP_GCLOUD` | `1` | Skip `gcloud config set project` |
| `CLEAN_TF` | `0` | Delete `.terraform/` before init |
| `RUN_ENSURE_BUCKET` | `0` | Create the state bucket if it does not exist |

## Remote state

Each stack stores its state in the **same GCS bucket** under a separate prefix:

```
gs://<TF_STATE_BUCKET>/terraform-state/workloads/test-01/
gs://<TF_STATE_BUCKET>/terraform-state/workloads/test-02/
gs://<TF_STATE_BUCKET>/terraform-state/workloads/test-03/
gs://<TF_STATE_BUCKET>/terraform-state/workloads/test-04/
```

## Cloud Build (CI/CD)

Plan and apply are run from Cloud Build. Topology:

- **One trigger pair per workload project**. The `cloudbuild-*.yaml` files
  live in this repo; each trigger lives in its own GCP project
  (`ks-crossinsurance-proj-test-01..04`) and overrides `_STACK` via
  `--substitutions=_STACK=test-XX`.
- **Single shared identity**: every trigger runs as
  `sa-terraform-ci@ks-crossinsurance-proj-test-sh.iam.gserviceaccount.com`
  via cross-project service account impersonation (so terraform always sees
  the same permissions, regardless of which workload project the trigger
  fires in).
- **Plan** triggers fire automatically on push to `main`.
- **Apply** triggers are manual and use `--require-approval`. An operator
  runs the trigger, then a separate approver (with
  `roles/cloudbuild.builds.approver`) approves the build before terraform
  apply runs.

See [`docs/cross-cloudbuild-setup.md`](docs/cross-cloudbuild-setup.md) for the
full setup script (API enablement, IAM bindings, trigger creation) for the
four projects.

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
10.20.0.0/16|ks-crossinsurance-proj-test-01|test-01|vpc
10.20.1.0/24|ks-crossinsurance-proj-test-01|test-01|subnet:sn-test-01-01
10.30.0.0/16|ks-crossinsurance-proj-test-02|test-02|vpc
10.30.1.0/24|ks-crossinsurance-proj-test-02|test-02|subnet:sn-test-02-01
10.40.0.0/16|ks-crossinsurance-proj-test-03|test-03|vpc
10.40.1.0/24|ks-crossinsurance-proj-test-03|test-03|subnet:sn-test-03-01
10.50.0.0/16|ks-crossinsurance-proj-test-04|test-04|vpc
10.50.1.0/24|ks-crossinsurance-proj-test-04|test-04|subnet:sn-test-04-01
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
   VPC CIDR overlap: 10.20.0.0/16 (test-01) vs 10.20.0.0/16 (test-02)
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
| `peer_env` | `string` | yes | Environment name (`test-01`..`test-04`) |
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

  - name: test-01
    project_id: ks-crossinsurance-proj-test-01
    region: us-central1
    vpc_name: vpc-test-01
    vpc_cidr: 10.20.0.0/16
    subnets:
      - name: sn-test-01-01
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
