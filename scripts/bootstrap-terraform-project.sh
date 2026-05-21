#!/usr/bin/env bash
#
# bootstrap-terraform-project.sh
#
# One-shot setup of the central Terraform tooling project for the
# CrossInsurance VPC stacks.
#
# What it provisions inside ${PROJECT}:
#   - Required APIs (storage, iam, iamcredentials, serviceusage, …).
#   - Service Account `${SA_NAME}` (the single CI identity used by every
#     workload-project Cloud Build trigger).
#   - GCS bucket for remote Terraform state (versioning + UBLA + PAP).
#   - GCS bucket for the CIDR registry (versioning + UBLA + PAP).
#   - IAM bindings allowing the SA to read/write both buckets and to
#     write its own logs.
#
# Idempotent: re-run any time. Existing resources are left as-is.
#
# Usage:
#   ./bootstrap-terraform-project.sh
#   PROJECT=my-tf-project ./bootstrap-terraform-project.sh
#   REGION=southamerica-east1 ./bootstrap-terraform-project.sh
#
# After this runs, perform per-workload bootstrap separately (it grants
# the workload's Cloud Build P4SA the right to impersonate ${SA_NAME},
# enables APIs in the workload, etc.). Workload IDs are not known yet,
# so that script is intentionally NOT invoked here.

set -euo pipefail

PROJECT="${PROJECT:-terraform-sandbox-kloudstax}"
REGION="${REGION:-us-central1}"

SA_NAME="${SA_NAME:-sa-terraform-ci}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

STATE_BUCKET="${STATE_BUCKET:-terraform-sandbox-kloudstax-crossinsurance-tf-state}"
CIDR_BUCKET="${CIDR_BUCKET:-terraform-sandbox-ks-test-crossinsurance-vpc-cidr-validator}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

require gcloud

log "Project        : ${PROJECT}"
log "Region         : ${REGION}"
log "Service Account: ${SA_EMAIL}"
log "State bucket   : gs://${STATE_BUCKET}"
log "CIDR bucket    : gs://${CIDR_BUCKET}"

# ─────────────────────────────────────────────────────────────────────────────
# 1) Enable APIs
# ─────────────────────────────────────────────────────────────────────────────
log "[1/5] Enabling APIs in ${PROJECT}"
gcloud services enable \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT}"

# ─────────────────────────────────────────────────────────────────────────────
# 2) Service Account (the single CI identity used cross-project)
# ─────────────────────────────────────────────────────────────────────────────
log "[2/5] Creating service account ${SA_EMAIL}"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "   already exists, skipping creation"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT}" \
    --display-name="Terraform CI" \
    --description="Used by Cloud Build in workload projects to run terraform plan/apply for CrossInsurance VPC stacks"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3) State bucket
# ─────────────────────────────────────────────────────────────────────────────
log "[3/5] Ensuring state bucket gs://${STATE_BUCKET}"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "   bucket exists, ensuring versioning + UBLA + PAP"
  gcloud storage buckets update "gs://${STATE_BUCKET}" \
    --versioning \
    --uniform-bucket-level-access \
    --public-access-prevention
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4) CIDR registry bucket
# ─────────────────────────────────────────────────────────────────────────────
log "[4/5] Ensuring CIDR registry bucket gs://${CIDR_BUCKET}"
if gcloud storage buckets describe "gs://${CIDR_BUCKET}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "   bucket exists, ensuring versioning + UBLA + PAP"
  gcloud storage buckets update "gs://${CIDR_BUCKET}" \
    --versioning \
    --uniform-bucket-level-access \
    --public-access-prevention
else
  gcloud storage buckets create "gs://${CIDR_BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
  gcloud storage buckets update "gs://${CIDR_BUCKET}" --versioning
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5) IAM
# ─────────────────────────────────────────────────────────────────────────────
log "[5/5] Granting IAM to ${SA_EMAIL}"

# State and CIDR buckets: full object access (read/write/list/delete)
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

gcloud storage buckets add-iam-policy-binding "gs://${CIDR_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

# Allow the SA to write logs in this project (Cloud Build logs are written
# to the *workload* project — that binding is granted by the per-workload
# bootstrap. This one keeps local terraform runs / debugging clean.)
gcloud projects add-iam-policy-binding "${PROJECT}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter" >/dev/null

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
✅ Done. Tooling project is ready.

   Project:        ${PROJECT}
   SA:             ${SA_EMAIL}
   State bucket:   gs://${STATE_BUCKET}
   CIDR bucket:    gs://${CIDR_BUCKET}

Next steps (run AFTER each workload project exists):

  1. Enable APIs in the workload (compute, cloudbuild, serviceusage, iam).

  2. Allow the workload's Cloud Build P4SA to impersonate ${SA_EMAIL}:

       WL=<workload-project-id>
       WL_NUM=\$(gcloud projects describe \${WL} --format='value(projectNumber)')
       CB_P4SA="service-\${WL_NUM}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

       gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \\
         --project="${PROJECT}" \\
         --member="serviceAccount:\${CB_P4SA}" \\
         --role="roles/iam.serviceAccountTokenCreator"

       gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \\
         --project="${PROJECT}" \\
         --member="serviceAccount:\${CB_P4SA}" \\
         --role="roles/iam.serviceAccountUser"

  3. Grant ${SA_EMAIL} the roles it needs INSIDE the workload:

       gcloud projects add-iam-policy-binding "\${WL}" \\
         --member="serviceAccount:${SA_EMAIL}" \\
         --role="roles/compute.networkAdmin"

       gcloud projects add-iam-policy-binding "\${WL}" \\
         --member="serviceAccount:${SA_EMAIL}" \\
         --role="roles/serviceusage.serviceUsageAdmin"

       gcloud projects add-iam-policy-binding "\${WL}" \\
         --member="serviceAccount:${SA_EMAIL}" \\
         --role="roles/logging.logWriter"

  4. Same compute.networkAdmin in the SHARED VPC host project (so the
     peering can be created on the host side).

  5. Create the plan + apply Cloud Build triggers in the workload (see
     docs/cross-cloudbuild-setup.md).

REMINDER: Cross-project SA usage requires the org policy
"iam.disableCrossProjectServiceAccountUsage" to NOT be enforced on the
workload project. If it is enforced, either reset the policy or fall
back to local SAs per workload.
──────────────────────────────────────────────────────────────────────────────
EOF
