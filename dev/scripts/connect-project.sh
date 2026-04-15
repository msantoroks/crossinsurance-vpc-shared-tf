#!/usr/bin/env bash
# Optional gcloud project (Terraform uses GOOGLE_APPLICATION_CREDENTIALS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
YAML_FILE="${STACK_ROOT}/config/environments.yaml"

resolve_project_from_yaml() {
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0])
    shared = data.fetch("environments", []).find { |e| e["name"] == "shared" }
    abort "shared environment missing in #{ARGV[0]}" unless shared
    puts shared.fetch("project_id")
  ' "${YAML_FILE}"
}

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
  if command -v jq >/dev/null 2>&1; then
    PROJECT_ID="$(jq -r '.project_id' "${GOOGLE_APPLICATION_CREDENTIALS}")"
  else
    PROJECT_ID="$(grep -oE '"project_id"[[:space:]]*:[[:space:]]*"[^"]+"' "${GOOGLE_APPLICATION_CREDENTIALS}" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
  fi
else
  PROJECT_ID="$(resolve_project_from_yaml)"
fi

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Could not resolve GCP project ID (set GOOGLE_APPLICATION_CREDENTIALS or fix ${YAML_FILE})." >&2
  exit 1
fi

if [[ "${SKIP_GCLOUD:-0}" == "1" ]]; then
  echo "SKIP_GCLOUD=1: skipping gcloud (Terraform uses credentials only). Reference project: ${PROJECT_ID}"
  exit 0
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found; continuing without gcloud config. Reference project: ${PROJECT_ID}"
  exit 0
fi

gcloud config set project "${PROJECT_ID}"
echo "gcloud project: ${PROJECT_ID}"
