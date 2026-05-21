# Bootstrap — step by step

Quick walkthrough for everything in `infrastructure/scripts/`. Run the
scripts in order; they are all idempotent.

```
scripts/
├── bootstrap-terraform-project.sh   # one-shot setup of the tooling project
└── bootstrap-workload-project.sh    # per-project setup (workload OR shared host)
```

---

## 0. Prerequisites

You need:

- `gcloud` installed and authenticated (`gcloud auth login`).
- The active account (`gcloud config get-value account`) needs:
  - **Owner** (or `roles/iam.serviceAccountAdmin` + `roles/storage.admin` +
    `roles/serviceusage.serviceUsageAdmin`) on the **tooling project**
    `terraform-sandbox-kloudstax`.
  - **Owner** (or `roles/serviceusage.serviceUsageAdmin` +
    `roles/resourcemanager.projectIamAdmin`) on every **workload project**
    (`ks-crossinsurance-proj-test-01..04`) and on the **shared host
    project** (`ks-crossinsurance-proj-test-sh`).
- The org policy `iam.disableCrossProjectServiceAccountUsage` must **NOT**
  be enforced on the workload projects. If it is, hand
  [`docs/org-policy-cross-project-sa.md`](../docs/org-policy-cross-project-sa.md)
  to your org admin (it has the full justification and the exact
  commands), or see [Troubleshooting](#troubleshooting) below for the
  decentralized fallback.

---

## 1. Tooling project — `bootstrap-terraform-project.sh`

Provisions the central Terraform identity and storage in
`terraform-sandbox-kloudstax`.

**Creates:**

- APIs: `storage`, `iam`, `iamcredentials`, `serviceusage`,
  `cloudresourcemanager`, `logging`.
- Service Account `sa-terraform-ci@terraform-sandbox-kloudstax.iam.gserviceaccount.com`.
- GCS bucket `ks-test-crossinsurance-proj-terraform-state`
  (versioned, UBLA, public-access-prevented).
- GCS bucket `terraform-sandbox-ks-test-crossinsurance-vpc-cidr-validator`
  (same hardening).
- IAM:
  - SA gets `roles/storage.objectAdmin` on both buckets.
  - SA gets `roles/logging.logWriter` on the tooling project.

**Run once:**

```bash
cd infrastructure
./scripts/bootstrap-terraform-project.sh
```

**Override defaults:**

```bash
PROJECT=my-tf-project \
REGION=southamerica-east1 \
STATE_BUCKET=my-tf-state \
CIDR_BUCKET=my-cidr-registry \
SA_NAME=sa-tf-ci \
./scripts/bootstrap-terraform-project.sh
```

If a resource already exists it is left as-is and re-asserted (versioning,
UBLA, PAP, IAM).

---

## 2. Workload projects — `bootstrap-workload-project.sh`

Wires one workload project (or the shared host project) to the tooling
project's CI Service Account.

### 2.1 Workload mode (default)

For each `ks-crossinsurance-proj-test-XX` (and any future workload):

```bash
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-01
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-02
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-03
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-04
```

**What happens (in order):**

1. **Pre-flight checks**
   - The central SA must already exist (`bootstrap-terraform-project.sh`
     was run).
   - You must be able to see the workload project.
   - You must have `iam.serviceAccounts.setIamPolicy` on the central SA
     (this is the most common failure — see [Troubleshooting](#1-permission_denied-on-iamserviceaccountssetiampolicy)).
2. **Enable APIs** in the workload: `cloudbuild`, `iam`, `iamcredentials`,
   `compute`, `serviceusage`, `cloudresourcemanager`, `logging`.
3. **Create the Cloud Build P4SA** in the workload (idempotent).
4. **Allow that P4SA to impersonate the central SA**: grants
   `roles/iam.serviceAccountUser` and `roles/iam.serviceAccountTokenCreator`
   on the central SA (on the tooling project).
5. **Grant the central SA the roles it needs INSIDE the workload**:
   `roles/compute.networkAdmin`, `roles/serviceusage.serviceUsageAdmin`,
   `roles/logging.logWriter`.

### 2.2 Shared-host mode

The Shared VPC host project (`ks-crossinsurance-proj-test-sh`) doesn't run
Cloud Build; it just owns `vpc-shared`. Run **once**:

```bash
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-sh --shared-host
```

This grants the central SA only `roles/compute.networkAdmin` on the host
project — enough to create the host-side peering when the workload stack
applies.

### 2.3 Override defaults

If your tooling project / SA name diverged from the defaults:

```bash
TOOLING_PROJECT=my-tf-proj \
TF_SA_EMAIL=sa-other@my-tf-proj.iam.gserviceaccount.com \
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-01
```

---

## 3. After both scripts ran

Per workload project, complete two manual steps in the Console (these are
not scripted because they require human consent in the GitHub App OAuth
flow):

1. **Connect the GitHub repo** (`msantoroks/crossinsurance-vpc-shared-tf`)
   in *Cloud Build → Triggers → Connect repository* (1st gen, GitHub App).
2. **Create the plan + apply triggers** as described in
   [`docs/cross-cloudbuild-setup.md`](../docs/cross-cloudbuild-setup.md)
   §4 steps 8–9.

---

## Troubleshooting

### 1. `PERMISSION_DENIED` on `iam.serviceAccounts.setIamPolicy`

```
ERROR: (gcloud.iam.service-accounts.add-iam-policy-binding)
PERMISSION_DENIED: Permission 'iam.serviceAccounts.setIamPolicy' denied
on resource (or it may not exist).
```

**Cause:** the user running `bootstrap-workload-project.sh` is allowed to
*create* the central SA (`serviceAccounts.create`) but not to *modify its
IAM policy* (`serviceAccounts.setIamPolicy`). These are independent
permissions.

**Fix** — run as an Owner of the tooling project:

```bash
# Option A — project-wide (recommended for the human running these scripts)
gcloud projects add-iam-policy-binding terraform-sandbox-kloudstax \
  --member="user:<your-email>" \
  --role="roles/iam.serviceAccountAdmin"

# Option B — scoped to just this SA
gcloud iam service-accounts add-iam-policy-binding \
  sa-terraform-ci@terraform-sandbox-kloudstax.iam.gserviceaccount.com \
  --project=terraform-sandbox-kloudstax \
  --member="user:<your-email>" \
  --role="roles/iam.serviceAccountAdmin"
```

If even this fails, you don't have `resourcemanager.projects.setIamPolicy`
on the tooling project. Either go through the Console as Owner or ask
someone with Owner on `terraform-sandbox-kloudstax` to run it. After it
succeeds, re-run `bootstrap-workload-project.sh <workload>`; it picks up
where it left off.

> The script now pre-flights this permission and exits early with the
> exact `gcloud` command tailored to your active account, so you should
> not see the raw error in step 3 anymore.

### 2. `Failed to update trigger: The caller does not have permission`

When linking the central SA to a trigger in the Cloud Build UI of a
workload project. Two possible causes:

- **You** lack `roles/iam.serviceAccountUser` on the central SA. Grant
  yourself that role on the tooling project:
  ```bash
  gcloud iam service-accounts add-iam-policy-binding \
    sa-terraform-ci@terraform-sandbox-kloudstax.iam.gserviceaccount.com \
    --project=terraform-sandbox-kloudstax \
    --member="user:<your-email>" \
    --role="roles/iam.serviceAccountUser"
  ```
- The org policy `iam.disableCrossProjectServiceAccountUsage` is
  enforced on the workload project. Confirm with:
  ```bash
  gcloud resource-manager org-policies describe \
    iam.disableCrossProjectServiceAccountUsage \
    --project=ks-crossinsurance-proj-test-01 --effective
  ```
  If it shows `enforced: true`, hand
  [`docs/org-policy-cross-project-sa.md`](../docs/org-policy-cross-project-sa.md)
  to the org admin who owns the workload organization — that doc has
  the full rationale plus copy-pasteable `gcloud` commands to disable
  it. If the policy can't be changed, fall back to a **local SA per
  workload**: create `sa-terraform-ci@<workload>.iam.gserviceaccount.com`
  in each workload project, grant it the same roles as the central SA,
  and reference the local SA in the trigger.

### 3. `Repository mapping does not exist`

The Cloud Build GitHub App was not installed for that workload project.
Open the Console at:

```
https://console.cloud.google.com/cloud-build/triggers;region=global/connect?project=<workload-project>
```

and complete step 1 of [§3 above](#3-after-both-scripts-ran). 1st-gen
connections must be created per project — they are not org-wide.

### 4. `Build failed to run: build.service_account requires CLOUD_LOGGING_ONLY / NONE / logs_bucket`

The trigger is using a YAML revision that lacks the logging options.
`cloudbuild-plan.yaml` and `cloudbuild-apply.yaml` already pin both
`logging: CLOUD_LOGGING_ONLY` AND
`defaultLogsBucketBehavior: REGIONAL_USER_OWNED_BUCKET` at the bottom.
Make sure the trigger is pointing at the latest commit.

### 5. `env: can't execute 'bash': No such file or directory`

The `hashicorp/terraform` image is Alpine-based and ships only `sh`. The
YAMLs install `bash` (and Python) before invoking `deploy.sh`. If you see
this, the build is running an older revision of the YAML — check the
resolved commit in the build details.

### 6. Bucket creation fails with `409 conflict` on the same bucket name

GCS bucket names are globally unique. Pick a different name via
`STATE_BUCKET=` / `CIDR_BUCKET=` env vars when invoking
`bootstrap-terraform-project.sh`, then update:

- `infrastructure/test-XX/main.tf` (`cidr_registry_gcs_bucket`)
- `infrastructure/test-XX/deploy.sh` (`TF_STATE_BUCKET` default)
- `infrastructure/README.md` and this file (docs).

### 7. `bucket update failed: Public access prevention is restricted by org policy`

Some orgs enforce `storage.publicAccessPrevention=enforced` cluster-wide.
That's fine — the bucket already has it set; the explicit
`--public-access-prevention` flag in the create call is just defensive.

---

## Cheat-sheet

```bash
# 0) one-time tooling
./scripts/bootstrap-terraform-project.sh

# 1) per-workload (idempotent — re-run after recreating a project)
for P in ks-crossinsurance-proj-test-{01,02,03,04}; do
  ./scripts/bootstrap-workload-project.sh "$P"
done

# 2) shared VPC host (peering target)
./scripts/bootstrap-workload-project.sh ks-crossinsurance-proj-test-sh --shared-host

# 3) connect repo + create triggers (Console + docs/cross-cloudbuild-setup.md §4)
```
