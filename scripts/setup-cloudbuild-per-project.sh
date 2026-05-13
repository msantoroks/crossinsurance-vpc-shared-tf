#!/usr/bin/env bash
#
# Provisions Cloud Build (plan + apply triggers) for ONE workload project,
# or for ALL four workload projects when called with --all.
#
# This script DOES NOT touch service accounts or IAM. The triggers it creates
# run as the project's default Cloud Build service account; rebind them to
# sa-terraform-ci@<shared-project> manually (UI or `gcloud builds triggers
# update`) AFTER the script finishes.
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
# Prerequisite (one-time per project, manual UI step):
#   - GitHub repo connected to the workload project's Cloud Build:
#     https://console.cloud.google.com/cloud-build/triggers;region=global/connect?project=<PROJECT_ID>
#
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
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

  # 1. APIs
  echo "---> [1/3] Enabling APIs (cloudbuild)"
  gcloud services enable cloudbuild.googleapis.com \
    --project="${WORKLOAD_PROJECT}"

  # 2. Plan trigger (auto on push to main)
  echo "---> [2/3] Creating PLAN trigger (auto on push to main)"
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
      --description="Terraform plan for ${STACK} (auto on push to main)"
  fi

  # 3. Apply trigger (manual + require approval)
  echo "---> [3/3] Creating APPLY trigger (manual + require approval)"
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
      --require-approval \
      --description="Terraform apply for ${STACK} (manual, requires approval)"
  fi

  echo
  echo "===> DONE: ${STACK} (${WORKLOAD_PROJECT})"
  echo "     Next (manual): bind sa-terraform-ci@<shared-project> as the"
  echo "     trigger service account (UI or 'gcloud builds triggers update')."
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
