#!/usr/bin/env bash
# Ensures the Terraform remote state GCS bucket exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML_FILE="${STACK_ROOT}/config/environments.yaml"

BUCKET_NAME="${TF_STATE_BUCKET:-${1:-}}"
if [[ -z "${BUCKET_NAME}" ]]; then
  echo "Usage: TF_STATE_BUCKET=<name> $0" >&2
  exit 1
fi

BUCKET_NAME="${BUCKET_NAME#gs://}"

resolve_project_from_yaml() {
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0])
    shared = data.fetch("environments", []).find { |e| e["name"] == "shared" }
    abort "shared environment missing in YAML" unless shared
    puts shared.fetch("project_id")
  ' "${YAML_FILE}"
}

if [[ -z "${GCP_PROJECT:-}" ]]; then
  if [[ ! -f "${YAML_FILE}" ]]; then
    echo "GCP_PROJECT is not set and ${YAML_FILE} was not found." >&2
    exit 1
  fi
  GCP_PROJECT="$(resolve_project_from_yaml)"
fi

LOCATION="${GCS_BUCKET_LOCATION:-us}"

if ! command -v gcloud >/dev/null 2>&1 && ! command -v gsutil >/dev/null 2>&1; then
  echo "Neither gcloud nor gsutil found. Install Google Cloud SDK." >&2
  exit 1
fi

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]] && command -v gcloud >/dev/null 2>&1; then
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
fi

GS_URI="gs://${BUCKET_NAME}"

bucket_exists() {
  if command -v gsutil >/dev/null 2>&1; then
    gsutil ls -b "${GS_URI}" >/dev/null 2>&1
  elif command -v gcloud >/dev/null 2>&1; then
    gcloud storage buckets describe "${GS_URI}" >/dev/null 2>&1
  else
    return 1
  fi
}

ensure_versioning() {
  echo "Ensuring object versioning is enabled on ${GS_URI} ..."
  if ! command -v gsutil >/dev/null 2>&1; then
    echo "Warning: gsutil not found; enable versioning manually." >&2
    return 0
  fi
  if gsutil versioning get "${GS_URI}" 2>/dev/null | grep -q 'Enabled'; then
    echo "Versioning already enabled."
  else
    gsutil versioning set on "${GS_URI}"
    echo "Versioning enabled."
  fi
}

if bucket_exists; then
  echo "State bucket ${GS_URI} already exists in project ${GCP_PROJECT}."
  ensure_versioning
  exit 0
fi

echo "State bucket ${GS_URI} not found. Creating in project ${GCP_PROJECT} (location=${LOCATION}) ..."

if command -v gcloud >/dev/null 2>&1; then
  gcloud storage buckets create "${GS_URI}" \
    --project="${GCP_PROJECT}" \
    --location="${LOCATION}" \
    --uniform-bucket-level-access
elif command -v gsutil >/dev/null 2>&1; then
  gsutil mb -p "${GCP_PROJECT}" -l "${LOCATION}" "${GS_URI}"
else
  echo "gcloud is required to create the bucket." >&2
  exit 1
fi

ensure_versioning
echo "State bucket is ready: ${GS_URI}"
