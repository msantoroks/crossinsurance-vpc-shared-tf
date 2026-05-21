# Cloud Build setup — Cross Insurance Terraform

This doc explains how Cloud Build is currently wired in our **internal
sandbox** for the four workload stacks (`test-01` … `test-04`) in this
repo. It covers IAM, repository connection, and trigger creation for
both **plan** (auto on push) and **apply** (manual + require approval).

> **For Cross Insurance setup**, do not follow this doc — it
> describes the Kloudstax sandbox topology with our own project IDs.
> The Cross Insurance rollout uses different project IDs (all inside
> the Cross org) and is documented end-to-end in:
>
> - [`cross-it-onboarding.md`](cross-it-onboarding.md) — what to
>   create on the Cross side and what to send back to us.
> - [`org-policy-cross-project-sa.md`](org-policy-cross-project-sa.md)
>   — the org-policy override request for Cross's policy admins.
>
> This file remains here as the **factual record of how the sandbox
> is wired** so that anyone replicating the design has a worked
> example.

---

## 1. Topology

The setup uses **three project tiers**:

```
                ┌──────────────────────────────────────────────────────┐
                │  Tooling project                                      │
                │  terraform-sandbox-kloudstax                          │
                │                                                       │
                │   • SA: sa-terraform-ci@…                             │
                │   • GCS: terraform-sandbox-kloudstax-…-tf-state       │
                │   • GCS: terraform-sandbox-kloudstax-…-vpc-cidr-…     │
                └───────────────▲───────────────────────────────────────┘
                                │  (impersonates this SA via cross-project IAM)
                                │
                ┌───────────────┴───────────────┬───────────────────┐
                │                               │                   │
                │           ┌───────────────────┴───────────────┐   │
                │           │  Shared VPC host                   │   │
                │           │  ks-crossinsurance-proj-test-sh    │   │
                │           │   • vpc-shared (peering target)    │   │
                │           └────────────────────────────────────┘   │
                │                                                    │
        ┌───────┴────────┬───────────────┬───────────────┬───────────┴──┐
        │                │               │               │              │
┌───────┴───────┐ ┌──────┴────────┐ ┌────┴──────────┐ ┌──┴────────────┐
│ Workload      │ │ Workload      │ │ Workload      │ │ Workload      │
│ test-01       │ │ test-02       │ │ test-03       │ │ test-04       │
│ Cloud Build   │ │ Cloud Build   │ │ Cloud Build   │ │ Cloud Build   │
│  • plan trig. │ │  • plan trig. │ │  • plan trig. │ │  • plan trig. │
│  • apply trig.│ │  • apply trig.│ │  • apply trig.│ │  • apply trig.│
└───────────────┘ └───────────────┘ └───────────────┘ └───────────────┘
```

Key points:

- **Tooling project** (`terraform-sandbox-kloudstax`) holds the single CI
  service account, the remote-state bucket, and the CIDR-registry bucket.
  Nothing here changes when a workload comes or goes.
- **Shared VPC host project** (`ks-crossinsurance-proj-test-sh`) hosts
  `vpc-shared`. The blueprint module establishes bidirectional peering
  between every workload VPC and `vpc-shared`.
- **Workload projects** (`ks-crossinsurance-proj-test-01..04`) host the
  workload VPCs **and** their own Cloud Build triggers. There is one
  trigger pair per workload project (8 triggers total).
- **Single Terraform identity**: every trigger runs as
  `sa-terraform-ci@terraform-sandbox-kloudstax.iam.gserviceaccount.com`,
  regardless of the project the trigger lives in. Cross-project SA
  impersonation is granted once per workload project (see §4).
- Plan triggers fire on push to `main`. Apply triggers are **manual** and
  **require approval** before terraform runs.
- Both YAMLs are checked into the repo root (`cloudbuild-plan.yaml`,
  `cloudbuild-apply.yaml`) and parameterized by `_STACK` substitution.

> ⚠ Cross-project SA impersonation requires the org policy
> `iam.disableCrossProjectServiceAccountUsage` to **NOT** be enforced on the
> workload projects. If your org enforces it, see §8.

---

## 2. Inventory

| Resource | Value |
|---|---|
| Tooling project | `terraform-sandbox-kloudstax` |
| Shared VPC host | `ks-crossinsurance-proj-test-sh` (`vpc-shared`) |
| Workload projects | `ks-crossinsurance-proj-test-01..04` |
| Terraform CI SA | `sa-terraform-ci@terraform-sandbox-kloudstax.iam.gserviceaccount.com` |
| State bucket | `gs://ks-test-crossinsurance-proj-terraform-state` |
| CIDR registry bucket | `gs://terraform-sandbox-ks-test-crossinsurance-vpc-cidr-validator` |
| GitHub repo | `msantoroks/crossinsurance-vpc-shared-tf` |

---

## 3. One-time setup of the tooling project

Run once, by a project owner of `terraform-sandbox-kloudstax`:

```bash
./scripts/bootstrap-terraform-project.sh
```

This creates the SA, both GCS buckets (versioned, UBLA + PAP), and the
SA-side IAM bindings. Override defaults via `PROJECT`, `REGION`,
`STATE_BUCKET`, `CIDR_BUCKET`, `SA_NAME` env vars.

---

## 4. Setup commands (run **once** per workload project)

> **Shortcut**: steps 1–6 are wrapped by
> `./scripts/bootstrap-workload-project.sh <PROJECT_ID>`. Run that once per
> workload project (and `… --shared-host` once for the Shared VPC host
> project), then jump straight to step 7 (GitHub repo connection) + steps
> 8–9 (trigger creation), which still need to be done manually per project.
>
> The full block below is kept for transparency / auditing.

Run the block below in Cloud Shell, **changing only `STACK` and `WORKLOAD_PROJECT`**
for each of the four projects. Everything else is the same across all four.

```bash
# ── Variables (edit these two for each project) ────────────────────────────
STACK="test-01"                                           # test-01..04
WORKLOAD_PROJECT="ks-crossinsurance-proj-test-01"         # match STACK number

# ── Constants (do NOT change) ──────────────────────────────────────────────
TOOLING_PROJECT="terraform-sandbox-kloudstax"
SHARED_PROJECT="ks-crossinsurance-proj-test-sh"
TF_SA_EMAIL="sa-terraform-ci@${TOOLING_PROJECT}.iam.gserviceaccount.com"
TF_SA_FQN="projects/${TOOLING_PROJECT}/serviceAccounts/${TF_SA_EMAIL}"
STATE_BUCKET="ks-test-crossinsurance-proj-terraform-state"
CIDR_BUCKET="terraform-sandbox-ks-test-crossinsurance-vpc-cidr-validator"
REPO_OWNER="msantoroks"
REPO_NAME="crossinsurance-vpc-shared-tf"
REGION="global"

# ── 1. Enable APIs in the workload project ─────────────────────────────────
gcloud services enable cloudbuild.googleapis.com iam.googleapis.com \
  compute.googleapis.com serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="${WORKLOAD_PROJECT}"

# ── 2. Create the Cloud Build P4SA (idempotent) ────────────────────────────
gcloud beta services identity create \
  --service=cloudbuild.googleapis.com \
  --project="${WORKLOAD_PROJECT}"

WORKLOAD_PROJ_NUM="$(gcloud projects describe "${WORKLOAD_PROJECT}" \
  --format='value(projectNumber)')"
CB_P4SA="service-${WORKLOAD_PROJ_NUM}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

# ── 3. Cross-project: let this project's Cloud Build impersonate sa-terraform-ci
gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
  --project="${TOOLING_PROJECT}" \
  --member="serviceAccount:${CB_P4SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
  --project="${TOOLING_PROJECT}" \
  --member="serviceAccount:${CB_P4SA}" \
  --role="roles/iam.serviceAccountTokenCreator"

# ── 4. Roles for sa-terraform-ci INSIDE the workload project ───────────────
#  • compute.networkAdmin   → create the workload VPC, subnets, peering side
#  • serviceusage.…         → enable APIs (compute, iam, cloudresourcemanager)
#  • logging.logWriter      → Cloud Build logs go to the workload project
gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/compute.networkAdmin"

gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/serviceusage.serviceUsageAdmin"

gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/logging.logWriter"

# ── 5. Roles for sa-terraform-ci INSIDE the shared host project ────────────
#  Needed for the host-side peering on vpc-shared. Run only once per
#  shared-host project (same SA reused by all workloads).
gcloud projects add-iam-policy-binding "${SHARED_PROJECT}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/compute.networkAdmin"

# ── 6. Bucket access on the tooling project (one-time, but idempotent) ─────
#  Already granted by bootstrap-terraform-project.sh; re-asserted here so
#  rerunning this script is enough to recover from accidental removal.
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

gcloud storage buckets add-iam-policy-binding "gs://${CIDR_BUCKET}" \
  --member="serviceAccount:${TF_SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# ── 7. Connect the GitHub repo to this workload project ────────────────────
# REQUIRED MANUAL STEP (one-time per project) — install the Cloud Build
# GitHub App for ${REPO_OWNER}/${REPO_NAME} via the Console:
#   https://console.cloud.google.com/cloud-build/triggers;region=${REGION}/connect?project=${WORKLOAD_PROJECT}
# Then verify with:
gcloud beta builds repositories list \
  --project="${WORKLOAD_PROJECT}" \
  --region="${REGION}" 2>/dev/null \
  || gcloud builds repositories list --project="${WORKLOAD_PROJECT}" --region="${REGION}"

# ── 8. Create the PLAN trigger (auto on push to main) ──────────────────────
gcloud builds triggers create github \
  --name="cross-infra-${STACK}-plan-main" \
  --project="${WORKLOAD_PROJECT}" \
  --region="${REGION}" \
  --repo-owner="${REPO_OWNER}" \
  --repo-name="${REPO_NAME}" \
  --branch-pattern="^main$" \
  --build-config="cloudbuild-plan.yaml" \
  --substitutions="_STACK=${STACK}" \
  --service-account="${TF_SA_FQN}" \
  --description="Terraform plan for ${STACK} (auto on push to main)"

# ── 9. Create the APPLY trigger (manual + require approval) ────────────────
gcloud builds triggers create manual \
  --name="cross-infra-${STACK}-apply-main" \
  --project="${WORKLOAD_PROJECT}" \
  --region="${REGION}" \
  --repo="https://github.com/${REPO_OWNER}/${REPO_NAME}" \
  --repo-type=GITHUB \
  --branch="main" \
  --build-config="cloudbuild-apply.yaml" \
  --substitutions="_STACK=${STACK}" \
  --service-account="${TF_SA_FQN}" \
  --require-approval \
  --description="Terraform apply for ${STACK} (manual, requires approval)"

echo "===> Done for ${STACK} (${WORKLOAD_PROJECT})"
```

Run that block four times (one per stack). After all four runs you should see:

```bash
gcloud builds triggers list --project=ks-crossinsurance-proj-test-XX --region=global
# → cross-infra-test-XX-plan-main   (push)
# → cross-infra-test-XX-apply-main  (manual, require_approval=true)
```

---

## 5. Granting humans permission to approve

Apply triggers are gated by Cloud Build's approval mechanism. Whoever
approves needs `roles/cloudbuild.builds.approver` **on the workload project**:

```bash
APPROVERS=( marcelo.santoro@kloudstax.com )

for STACK in test-01 test-02 test-03 test-04; do
  WORKLOAD_PROJECT="ks-crossinsurance-proj-test-${STACK#test-}"
  for USER in "${APPROVERS[@]}"; do
    gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
      --member="user:${USER}" \
      --role="roles/cloudbuild.builds.approver"
  done
done
```

The same users probably also need `roles/cloudbuild.builds.editor` to be able
to RUN the apply trigger from the UI:

```bash
for STACK in test-01 test-02 test-03 test-04; do
  WORKLOAD_PROJECT="ks-crossinsurance-proj-test-${STACK#test-}"
  for USER in "${APPROVERS[@]}"; do
    gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
      --member="user:${USER}" \
      --role="roles/cloudbuild.builds.editor"
  done
done
```

---

## 6. Day-to-day flow

### Plan (automatic)

1. Open a PR against `main`.
2. Merge it.
3. The plan trigger in **every** workload project fires automatically on the
   commit hitting `main`. Each project plans its own stack.
4. Logs: Cloud Build → History (filter by trigger name) in each workload project.

> Currently each plan is isolated: a change touching only `test-02/` still
> triggers all four plans. They are cheap and surface unexpected drift, so
> we keep it that way for now. To restrict, add `--included-files=test-XX/**`
> to each plan trigger.

### Apply (manual + approval)

1. Make sure the latest plan in the target project is green.
2. Run the apply trigger:
   ```bash
   gcloud builds triggers run cross-infra-test-01-apply-main \
     --branch=main \
     --project=ks-crossinsurance-proj-test-01 \
     --region=global
   ```
   …or click **RUN** in the Cloud Build → Triggers page.
3. Build enters **Pending approval**. A different person (with
   `roles/cloudbuild.builds.approver`) reviews the plan logs and clicks
   **Approve**.
4. Cloud Build now runs `deploy.sh apply` with `BUILD_ID` set, so terraform
   automatically gets `-auto-approve` and runs unattended.

---

## 7. Local fallback (no Cloud Build)

If Cloud Build is unavailable, every operation can still be performed locally:

```bash
cd test-01
cp /path/to/sa-terraform-ci-key.json credentials/local.json   # one-time
./deploy.sh plan
./deploy.sh apply
```

The same SA must be used (or any SA with equivalent IAM roles).

---

## 8. Troubleshooting

### `Build failed to run: build.service_account requires CLOUD_LOGGING_ONLY / NONE / logs_bucket`

The build was launched without recognising the YAML's `options` block. Most
common causes:

- The trigger points to a wrong filename (`--build-config`).
- The trigger was created with conflicting flags (e.g. `--default-buckets-behavior`).
- The repo connection points to a fork that does not contain the latest YAML.

Both `cloudbuild-plan.yaml` and `cloudbuild-apply.yaml` already pin both
`logging: CLOUD_LOGGING_ONLY` AND
`defaultLogsBucketBehavior: REGIONAL_USER_OWNED_BUCKET`, which satisfies the
Cloud Build constraint. Verify the trigger config with:

```bash
gcloud builds triggers describe cross-infra-test-01-plan-main \
  --project=ks-crossinsurance-proj-test-01 --region=global \
  --format="yaml(filename,build,serviceAccount,substitutions)"
```

### `Permission denied: iam.serviceAccountTokenCreator on sa-terraform-ci`

Step 3 of §4 was skipped (or the binding was made on the wrong project).
The Cloud Build P4SA of the **workload** project must hold both
`iam.serviceAccountUser` and `iam.serviceAccountTokenCreator` on the
`sa-terraform-ci` SA in the **tooling** project (`terraform-sandbox-kloudstax`).

### `The caller does not have permission` when linking the SA in the trigger UI

Either:

- You don't have `roles/iam.serviceAccountUser` on the SA in the tooling
  project (give it to the human who is creating the trigger), **OR**
- The org policy `iam.disableCrossProjectServiceAccountUsage` is enforced
  on the workload project. Confirm with:
  ```bash
  gcloud resource-manager org-policies describe \
    iam.disableCrossProjectServiceAccountUsage \
    --project=ks-crossinsurance-proj-test-01 --effective
  ```
  If it shows `enforced: true`, share
  [`org-policy-cross-project-sa.md`](org-policy-cross-project-sa.md)
  with the workload organization's policy admin — it explains the
  request and gives the exact commands. As a last resort, fall back to
  local SAs per workload (one
  `sa-terraform-ci@<workload>.iam.gserviceaccount.com` per project,
  each granted the same roles as the central SA but local).

### `env: can't execute 'bash': No such file or directory`

The YAML installs `bash` (Alpine image lacks it) before invoking `deploy.sh`.
If you're seeing this, the build is running an older revision of the YAML.
Verify the resolved commit in the build details.

### `Repository mapping does not exist`

Step 7 (manual GitHub App install in the Console) was skipped for that
workload project, or it was installed on a different repo than the one the
trigger references.

---

## 9. Repo changes that enabled this

| Path | Why |
|---|---|
| `scripts/bootstrap-terraform-project.sh` | One-shot bootstrap of the tooling project (SA + buckets + IAM). |
| `<stack>/deploy.sh` | Detects `BUILD_ID` (Cloud Build) and `USE_ADC=1` to skip key files; auto-passes `-auto-approve` for `apply`/`destroy` in CI; tfvars is optional. |
| `<stack>/config/environments.yaml` | Single workload entry per stack, no extra envs. |
| `cloudbuild-plan.yaml` | One YAML for all plan triggers. `_STACK` substitution selects the directory. Pins both logging options. |
| `cloudbuild-apply.yaml` | Same as plan, but runs `deploy.sh apply`. Triggers must add `--require-approval`. |
| `docs/cross-cloudbuild-setup.md` | This document. |
