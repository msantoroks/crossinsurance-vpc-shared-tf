#!/usr/bin/env bash
#
# bootstrap-workload-project.sh
#
# Per-project bootstrap that grants the central CI Service Account
#   ${TF_SA_EMAIL}
# (created by ./bootstrap-terraform-project.sh in ${TOOLING_PROJECT})
# everything it needs to run terraform plan/apply against this project.
#
# Two modes:
#   • workload (default): full setup for a workload project that also hosts
#     a Cloud Build trigger pair (test-01..04 and similar).
#       - enables required APIs in the workload
#       - creates the workload's Cloud Build P4SA
#       - grants the Cloud Build P4SA permission to impersonate the central SA
#       - grants the central SA the IAM roles it needs INSIDE this workload
#         (compute.networkAdmin, serviceusage.serviceUsageAdmin, logging.logWriter)
#
#   • --shared-host: the project just owns the Shared VPC peering target
#     (e.g. ks-crossinsurance-proj-test-sh). No Cloud Build runs here, so
#     we only grant the central SA the network role needed for the host
#     side of the peering.
#
# Idempotent. Re-run any time.
#
# Usage:
#   ./bootstrap-workload-project.sh <PROJECT_ID>
#   ./bootstrap-workload-project.sh <PROJECT_ID> --shared-host
#
# Override defaults:
#   TOOLING_PROJECT=my-tf-proj TF_SA_EMAIL=sa-other@my-tf-proj.iam.gserviceaccount.com \
#     ./bootstrap-workload-project.sh ks-crossinsurance-proj-test-01

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────
MODE="workload"
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shared-host) MODE="shared-host"; shift ;;
    -h|--help)
      sed -n '2,33p' "$0"; exit 0 ;;
    -*)
      echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -n "${PROJECT}" ]]; then
        echo "Unexpected extra arg: $1 (project already set to ${PROJECT})" >&2
        exit 2
      fi
      PROJECT="$1"; shift ;;
  esac
done

if [[ -z "${PROJECT}" ]]; then
  echo "Usage: $0 <PROJECT_ID> [--shared-host]" >&2
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Constants (override via env if the tooling layout differs)
# ─────────────────────────────────────────────────────────────────────────────
TOOLING_PROJECT="${TOOLING_PROJECT:-terraform-sandbox-kloudstax}"
TF_SA_NAME="${TF_SA_NAME:-sa-terraform-ci}"
TF_SA_EMAIL="${TF_SA_EMAIL:-${TF_SA_NAME}@${TOOLING_PROJECT}.iam.gserviceaccount.com}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
sub() { printf '   • %s\n' "$*"; }

command -v gcloud >/dev/null 2>&1 || { echo "Missing: gcloud" >&2; exit 1; }

log "Project        : ${PROJECT}"
log "Mode           : ${MODE}"
log "Tooling project: ${TOOLING_PROJECT}"
log "Central CI SA  : ${TF_SA_EMAIL}"

# Sanity: the central SA must already exist in the tooling project.
if ! gcloud iam service-accounts describe "${TF_SA_EMAIL}" \
      --project="${TOOLING_PROJECT}" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: Central CI SA not found.
   ${TF_SA_EMAIL}
Run ./bootstrap-terraform-project.sh first (in ${TOOLING_PROJECT}).
EOF
  exit 1
fi

# Sanity: we must be able to see the target project.
if ! gcloud projects describe "${PROJECT}" >/dev/null 2>&1; then
  echo "ERROR: project ${PROJECT} not found or you have no access to it." >&2
  exit 1
fi

# Pre-flight: in workload mode we must be able to set IAM policy on the
# central SA (to grant the workload's CB P4SA impersonation). Detect this
# now and print the exact fix instead of failing halfway through.
if [[ "${MODE}" == "workload" ]]; then
  ACTIVE_USER="$(gcloud config get-value account 2>/dev/null || true)"
  REQUIRED_PERM="iam.serviceAccounts.setIamPolicy"
  HAVE="$(gcloud iam service-accounts test-iam-permissions "${TF_SA_EMAIL}" \
            --project="${TOOLING_PROJECT}" \
            --permissions="${REQUIRED_PERM}" \
            --format="value(permissions)" 2>/dev/null || true)"
  if [[ -z "${HAVE}" ]]; then
    cat >&2 <<EOF
ERROR: ${ACTIVE_USER:-current user} is missing '${REQUIRED_PERM}' on
   ${TF_SA_EMAIL}
without it the script cannot grant the workload's Cloud Build P4SA the
right to impersonate the central SA.

Fix (run as an owner of ${TOOLING_PROJECT}):

  # Option A — project-wide (recommended for the human running these scripts)
  gcloud projects add-iam-policy-binding ${TOOLING_PROJECT} \\
    --member="user:${ACTIVE_USER}" \\
    --role="roles/iam.serviceAccountAdmin"

  # Option B — scoped to just this SA
  gcloud iam service-accounts add-iam-policy-binding \\
    ${TF_SA_EMAIL} \\
    --project=${TOOLING_PROJECT} \\
    --member="user:${ACTIVE_USER}" \\
    --role="roles/iam.serviceAccountAdmin"

Then re-run this script (it is idempotent).
EOF
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Shared-host mode: only the host-side peering role is needed.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${MODE}" == "shared-host" ]]; then
  log "[shared-host] Granting compute.networkAdmin to ${TF_SA_EMAIL} on ${PROJECT}"
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${TF_SA_EMAIL}" \
    --role="roles/compute.networkAdmin" >/dev/null
  sub "Done. The central SA can now create the host-side peering on this project."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Workload mode
# ─────────────────────────────────────────────────────────────────────────────

# 1) APIs
log "[1/4] Enabling APIs in ${PROJECT}"
gcloud services enable \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  compute.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT}"

# 2) Cloud Build P4SA + cross-project impersonation grants
log "[2/4] Creating Cloud Build P4SA in ${PROJECT}"
gcloud beta services identity create \
  --service=cloudbuild.googleapis.com \
  --project="${PROJECT}" >/dev/null

PROJ_NUM="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"
CB_P4SA="service-${PROJ_NUM}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
sub "Cloud Build P4SA: ${CB_P4SA}"

log "[3/4] Allowing ${CB_P4SA} to impersonate ${TF_SA_EMAIL}"
gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
  --project="${TOOLING_PROJECT}" \
  --member="serviceAccount:${CB_P4SA}" \
  --role="roles/iam.serviceAccountUser" >/dev/null

gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
  --project="${TOOLING_PROJECT}" \
  --member="serviceAccount:${CB_P4SA}" \
  --role="roles/iam.serviceAccountTokenCreator" >/dev/null

# 3) Roles for the central SA INSIDE this workload
log "[4/4] Granting roles to ${TF_SA_EMAIL} on ${PROJECT}"

WORKLOAD_ROLES=(
  "roles/compute.networkAdmin"          # create VPC, subnets, peering side
  "roles/serviceusage.serviceUsageAdmin" # enable APIs from terraform
  "roles/logging.logWriter"             # Cloud Build log delivery
)

for ROLE in "${WORKLOAD_ROLES[@]}"; do
  sub "${ROLE}"
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${TF_SA_EMAIL}" \
    --role="${ROLE}" >/dev/null
done

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
✅ Workload bootstrap done.

   Project:         ${PROJECT}
   Central SA:      ${TF_SA_EMAIL}
   CB P4SA (here):  ${CB_P4SA}

Reminder:
  • Connect the GitHub repo to ${PROJECT} via the Console once
    (Cloud Build → Triggers → Connect repository).
  • Then create the plan + apply triggers in this project, both pointing
    to --service-account=projects/${TOOLING_PROJECT}/serviceAccounts/${TF_SA_EMAIL}.
    See docs/cross-cloudbuild-setup.md §4 steps 8–9.
  • If creating a trigger fails with
        "The caller does not have permission" / cross-project SA usage,
    the org policy iam.disableCrossProjectServiceAccountUsage is enforced
    on this project. Reset it with an org admin or fall back to a local SA.
──────────────────────────────────────────────────────────────────────────────
EOF
