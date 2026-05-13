#!/usr/bin/env bash
#
# Provisions Cloud Build (plan + apply triggers) for ONE workload project,
# or for ALL four workload projects when called with --all.
#
# Each invocation produces 1 plan trigger + 1 apply trigger inside the given
# workload project. Both triggers run as the shared SA
# (sa-terraform-ci@ks-crossinsurance-proj-test-sh) via cross-project
# impersonation.
#
# Convention (derives STACK from PROJECT_ID automatically):
#   ks-crossinsurance-proj-test-01 → STACK=test-01
#   ks-crossinsurance-proj-test-02 → STACK=test-02
#   ks-crossinsurance-proj-test-03 → STACK=test-03
#   ks-crossinsurance-proj-test-04 → STACK=test-04
#
# Usage:
#   ./scripts/setup-cloudbuild-per-project.sh <PROJECT_ID>
#   ./scripts/setup-cloudbuild-per-project.sh ks-crossinsurance-proj-test-01
#   ./scripts/setup-cloudbuild-per-project.sh --all          # iterate over all 4
#
# Prerequisites:
#   - gcloud authenticated as a user with rights on BOTH projects:
#       * the workload project (Cloud Build / IAM admin)
#       * the shared project (rights to grant IAM on sa-terraform-ci)
#   - GitHub repo already connected to the workload project's Cloud Build
#     (one-time UI step: see docs/cross-cloudbuild-setup.md §3 step 6).
#
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
SHARED_PROJECT="ks-crossinsurance-proj-test-sh"
TF_SA_EMAIL="sa-terraform-ci@${SHARED_PROJECT}.iam.gserviceaccount.com"
TF_SA_FQN="projects/${SHARED_PROJECT}/serviceAccounts/${TF_SA_EMAIL}"
STATE_BUCKET="ks-crossinsurance-proj-test-terraform-state"
CIDR_BUCKET="ks-crossinsurance-proj-test-sh-vpc-cidr-validator"
REPO_OWNER="msantoroks"
REPO_NAME="crossinsurance-vpc-shared-tf"
REGION="global"

ALL_PROJECTS=(
  "ks-crossinsurance-proj-test-01"
  "ks-crossinsurance-proj-test-02"
  "ks-crossinsurance-proj-test-03"
  "ks-crossinsurance-proj-test-04"
)

# ── Args ───────────────────────────────────────────────────────────────────
ARG="${1:-}"
if [[ -z "${ARG}" ]]; then
  echo "Usage: $0 <PROJECT_ID|--all>" >&2
  echo "  PROJECT_ID example: ks-crossinsurance-proj-test-01" >&2
  exit 1
fi

# ── Per-project setup function ─────────────────────────────────────────────
setup_one() {
  local WORKLOAD_PROJECT="$1"

  # Derive STACK from project ID suffix
  if [[ ! "${WORKLOAD_PROJECT}" =~ -test-(0[1-4])$ ]]; then
    echo "ERROR: cannot derive stack from '${WORKLOAD_PROJECT}'." >&2
    echo "       Expected suffix '-test-01' .. '-test-04'." >&2
    return 1
  fi
  local STACK="test-${BASH_REMATCH[1]}"

  echo
  echo "================================================================"
  echo "  Setup Cloud Build for ${STACK} (project=${WORKLOAD_PROJECT})"
  echo "================================================================"

  # 1. Self-grant: the user running this script must be able to impersonate
  # ${TF_SA_EMAIL} to create triggers that use it (Cloud Build checks this
  # at trigger creation time).
  local CURRENT_ACCOUNT
  CURRENT_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ -n "${CURRENT_ACCOUNT}" ]]; then
    echo "---> [1/8] Granting iam.serviceAccountUser to ${CURRENT_ACCOUNT} on ${TF_SA_EMAIL}"
    gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
      --project="${SHARED_PROJECT}" \
      --member="user:${CURRENT_ACCOUNT}" \
      --role="roles/iam.serviceAccountUser" \
      --condition=None >/dev/null
  else
    echo "---> [1/8] WARNING: could not detect active gcloud account; skipping self-grant" >&2
  fi

  # 2. APIs
  echo "---> [2/8] Enabling APIs (cloudbuild, iam)"
  gcloud services enable cloudbuild.googleapis.com iam.googleapis.com \
    --project="${WORKLOAD_PROJECT}"

  # 3. Cloud Build P4SA
  echo "---> [3/8] Ensuring Cloud Build P4SA exists"
  gcloud beta services identity create \
    --service=cloudbuild.googleapis.com \
    --project="${WORKLOAD_PROJECT}" >/dev/null

  local WORKLOAD_PROJ_NUM
  WORKLOAD_PROJ_NUM="$(gcloud projects describe "${WORKLOAD_PROJECT}" \
    --format='value(projectNumber)')"
  local CB_P4SA="service-${WORKLOAD_PROJ_NUM}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
  echo "     Cloud Build P4SA: ${CB_P4SA}"

  # 4. Cross-project SA impersonation (workload CB → shared SA)
  echo "---> [4/8] Granting cross-project IAM on ${TF_SA_EMAIL}"
  gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
    --project="${SHARED_PROJECT}" \
    --member="serviceAccount:${CB_P4SA}" \
    --role="roles/iam.serviceAccountUser" \
    --condition=None >/dev/null

  gcloud iam service-accounts add-iam-policy-binding "${TF_SA_EMAIL}" \
    --project="${SHARED_PROJECT}" \
    --member="serviceAccount:${CB_P4SA}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --condition=None >/dev/null

  # 5. Logs writer for the runtime SA in this workload project
  echo "---> [5/8] Granting logging.logWriter to ${TF_SA_EMAIL} on ${WORKLOAD_PROJECT}"
  gcloud projects add-iam-policy-binding "${WORKLOAD_PROJECT}" \
    --member="serviceAccount:${TF_SA_EMAIL}" \
    --role="roles/logging.logWriter" \
    --condition=None >/dev/null

  # 6. Bucket access for state + CIDR registry (idempotent)
  echo "---> [6/8] Granting storage.objectAdmin on shared buckets"
  gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
    --member="serviceAccount:${TF_SA_EMAIL}" \
    --role="roles/storage.objectAdmin" >/dev/null

  gcloud storage buckets add-iam-policy-binding "gs://${CIDR_BUCKET}" \
    --member="serviceAccount:${TF_SA_EMAIL}" \
    --role="roles/storage.objectAdmin" >/dev/null

  # 7. Plan trigger (auto on push to main)
  echo "---> [7/8] Creating PLAN trigger (auto on push to main)"
  if gcloud builds triggers describe "cross-infra-${STACK}-plan-main" \
      --project="${WORKLOAD_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
    echo "     plan trigger already exists, skipping create"
  else
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
  fi

  # 8. Apply trigger (manual + require approval)
  echo "---> [8/8] Creating APPLY trigger (manual + require approval)"
  if gcloud builds triggers describe "cross-infra-${STACK}-apply-main" \
      --project="${WORKLOAD_PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
    echo "     apply trigger already exists, skipping create"
  else
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
  fi

  echo
  echo "===> DONE: ${STACK} (${WORKLOAD_PROJECT})"
  echo "     • Push to main triggers plan automatically."
  echo "     • Run apply manually with:"
  echo "         gcloud builds triggers run cross-infra-${STACK}-apply-main \\"
  echo "           --branch=main --project=${WORKLOAD_PROJECT} --region=${REGION}"
}

# ── Dispatch ───────────────────────────────────────────────────────────────
if [[ "${ARG}" == "--all" ]]; then
  for proj in "${ALL_PROJECTS[@]}"; do
    setup_one "${proj}"
  done
  echo
  echo "ALL FOUR WORKLOAD PROJECTS PROVISIONED."
else
  setup_one "${ARG}"
fi
