#!/usr/bin/env bash
#
# Isolated stack: config + tfvars in this directory.
#   ./deploy.sh plan | apply | init | validate | destroy | output <name> | unlock <lock_id>
#
# CIDR registry: authoritative copy is in GCS; the env module merges only this peer_env on apply (see modules/env).
#
set -euo pipefail

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="$(basename "${STACK_ROOT}")"
SCRIPTS_DIR="${STACK_ROOT}/scripts"
VAR_FILE="${STACK_ROOT}/terraform.tfvars"
CONFIG_DIR="${STACK_ROOT}/config"

export TF_STATE_BUCKET="${TF_STATE_BUCKET:-ks-crossinsurance-proj-test-terraform-state}"
export SKIP_GCLOUD="${SKIP_GCLOUD:-1}"

if [[ "${STACK_NAME}" == "prod" ]] && [[ "${LEGACY_PRD_STATE:-0}" == "1" ]]; then
  BACKEND_PREFIX="${BACKEND_PREFIX:-terraform-state/workloads/prd}"
else
  BACKEND_PREFIX="${BACKEND_PREFIX:-terraform-state/workloads/${STACK_NAME}}"
fi

resolve_credentials() {
  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    return 0
  fi
  local f="${STACK_ROOT}/credentials/${DEPLOY_CREDENTIALS:-local}.json"
  if [[ ! -f "${f}" ]]; then
    echo "Set GOOGLE_APPLICATION_CREDENTIALS or create ${f}" >&2
    exit 1
  fi
  export GOOGLE_APPLICATION_CREDENTIALS="${f}"
}

terraform_tf() {
  terraform -chdir="${STACK_ROOT}" "$@"
}

ACTION="${1:-}"
EXTRA="${2:-}"

if [[ "${DEBUG:-0}" == "1" ]]; then
  echo "STACK_ROOT=${STACK_ROOT} STACK_NAME=${STACK_NAME} ACTION=${ACTION} EXTRA=${EXTRA:-}"
fi

if [[ -z "${ACTION}" ]]; then
  echo "Usage: $0 <init|validate|plan|apply|destroy|output|unlock> [arg]" >&2
  exit 1
fi

if [[ "${ACTION}" == "unlock" ]]; then
  if [[ -z "${EXTRA}" ]]; then
    echo "Usage: $0 unlock <lock_id>" >&2
    exit 1
  fi
  resolve_credentials
  echo "force-unlock (stack=${STACK_NAME}, prefix=${BACKEND_PREFIX}, lock=${EXTRA})..."
  "${SCRIPTS_DIR}/connect-project.sh"
  terraform_tf init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${BACKEND_PREFIX}"
  terraform_tf force-unlock -force "${EXTRA}"
  echo "Unlock completed."
  exit 0
fi

resolve_credentials
"${SCRIPTS_DIR}/connect-project.sh"

require_tfvars() {
  if [[ ! -f "${VAR_FILE}" ]]; then
    echo "Missing ${VAR_FILE} (copy from terraform.tfvars.example)." >&2
    exit 1
  fi
  if [[ ! -f "${CONFIG_DIR}/environments.yaml" ]]; then
    echo "Missing ${CONFIG_DIR}/environments.yaml" >&2
    exit 1
  fi
}

init_tf() {
  if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
    echo "TF_STATE_BUCKET is not set." >&2
    exit 1
  fi
  if [[ "${CLEAN_TF:-0}" == "1" ]]; then
    echo "CLEAN_TF=1: removing .terraform and .terraform.lock.hcl in ${STACK_NAME}/"
    rm -rf "${STACK_ROOT}/.terraform"
    rm -f "${STACK_ROOT}/.terraform.lock.hcl"
  fi
  if [[ "${RUN_ENSURE_BUCKET:-0}" == "1" ]]; then
    export TF_STATE_BUCKET
    "${SCRIPTS_DIR}/ensure_state_bucket.sh"
  fi
  terraform_tf init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${BACKEND_PREFIX}"
}

TF_VARS=( -var-file="${VAR_FILE}" )

case "${ACTION}" in
  init)
    require_tfvars
    init_tf
    ;;
  validate)
    require_tfvars
    init_tf
    terraform_tf validate
    ;;
  plan)
    require_tfvars
    init_tf
    terraform_tf plan "${TF_VARS[@]}"
    ;;
  apply)
    require_tfvars
    init_tf
    terraform_tf apply "${TF_VARS[@]}"
    ;;
  destroy)
    require_tfvars
    init_tf
    terraform_tf destroy "${TF_VARS[@]}"
    ;;
  output)
    if [[ -z "${EXTRA}" ]]; then
      echo "Usage: $0 output <name>" >&2
      exit 1
    fi
    require_tfvars
    init_tf
    terraform_tf output "${EXTRA}"
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    exit 1
    ;;
esac
