#!/usr/bin/env python3
"""
CIDR registry in GCS: per stack, only rows for this environment (peer_env) are written/removed.

- validate (stdin JSON from Terraform data.external): merge preview + overlap checks, no write.
- apply (env): download GCS, drop rows for peer_env, append current vpc + subnet rows, upload.
- destroy (env): download GCS, drop rows for peer_env, upload.

Format per line: cidr|project_id|environment|resource
GCS access: prefer `pip install google-cloud-storage`, or `gcloud` / `gsutil` on PATH (uses GOOGLE_APPLICATION_CREDENTIALS).
"""

from __future__ import annotations

import ipaddress
import json
import os
import shutil
import subprocess
import sys
import tempfile
def die(msg: str, code: int = 1) -> None:
    print(f"cidr_registry_gcs_sync: {msg}", file=sys.stderr)
    sys.exit(code)


def parse_registry(text: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|", 3)]
        if len(parts) != 4:
            die(f"bad registry line: {raw!r}")
        rows.append(
            {
                "cidr": parts[0],
                "project_id": parts[1],
                "environment": parts[2],
                "resource": parts[3],
            }
        )
    return rows


def format_row(r: dict[str, str]) -> str:
    return "|".join(
        [r["cidr"], r["project_id"], r["environment"], r["resource"]]
    )


def rows_for_stack(
    peer_env: str,
    project_id: str,
    vpc_cidr: str,
    subnets: list[dict],
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = [
        {
            "cidr": vpc_cidr,
            "project_id": project_id,
            "environment": peer_env,
            "resource": "vpc",
        }
    ]
    for s in subnets:
        rows.append(
            {
                "cidr": str(s["cidr"]),
                "project_id": project_id,
                "environment": peer_env,
                "resource": f"subnet:{s['name']}",
            }
        )
    return rows


def remove_env_rows(rows: list[dict[str, str]], peer_env: str) -> list[dict[str, str]]:
    return [r for r in rows if r["environment"] != peer_env]


def merge_registry(
    existing: list[dict[str, str]],
    peer_env: str,
    project_id: str,
    vpc_cidr: str,
    subnets: list[dict],
) -> list[dict[str, str]]:
    base = remove_env_rows(existing, peer_env)
    new_rows = rows_for_stack(peer_env, project_id, vpc_cidr, subnets)
    key = lambda r: (r["cidr"], r["project_id"], r["environment"], r["resource"])
    seen = {key(r) for r in base}
    for r in new_rows:
        k = key(r)
        if k in seen:
            die(f"duplicate row after merge: {format_row(r)}")
        seen.add(k)
    return base + new_rows


def validate_subnets_in_vpc(vpc_cidr: str, subnets: list[dict]) -> None:
    try:
        vpc_net = ipaddress.ip_network(vpc_cidr, strict=False)
    except ValueError as e:
        die(f"invalid vpc_cidr {vpc_cidr!r}: {e}")
    for s in subnets:
        c = s.get("cidr")
        if not c:
            die(f"subnet missing cidr: {s!r}")
        try:
            sn = ipaddress.ip_network(str(c), strict=False)
        except ValueError as err:
            die(f"invalid subnet cidr {c!r}: {err}")
        if sn.version != vpc_net.version:
            die(f"subnet {c} address family must match vpc_cidr")
        if not sn.subnet_of(vpc_net):
            die(f"subnet {c} is not inside vpc_cidr {vpc_cidr}")


def vpc_overlap(rows: list[dict[str, str]]) -> None:
    vpc_rows = [r for r in rows if r["resource"] == "vpc"]
    for i, a in enumerate(vpc_rows):
        try:
            na = ipaddress.ip_network(a["cidr"], strict=False)
        except ValueError as e:
            die(f"invalid VPC CIDR in merged registry {a['cidr']!r}: {e}")
        for b in vpc_rows[i + 1 :]:
            if a["environment"] == b["environment"]:
                continue
            try:
                nb = ipaddress.ip_network(b["cidr"], strict=False)
            except ValueError as e:
                die(f"invalid VPC CIDR in merged registry {b['cidr']!r}: {e}")
            if networks_overlap(na, nb):
                die(
                    f"VPC CIDR overlap: {a['cidr']} ({a['environment']}) vs "
                    f"{b['cidr']} ({b['environment']})"
                )


def networks_overlap(
    a: ipaddress.IPv4Network | ipaddress.IPv6Network,
    b: ipaddress.IPv4Network | ipaddress.IPv6Network,
) -> bool:
    af = (int(a.network_address), int(a.broadcast_address))
    bf = (int(b.network_address), int(b.broadcast_address))
    a_lo, a_hi = af
    b_lo, b_hi = bf
    return not (a_hi < b_lo or b_hi < a_lo)


def registry_text(rows: list[dict[str, str]]) -> str:
    lines = [format_row(r) for r in rows]
    return "\n".join(lines) + ("\n" if lines else "")


def _download_text_lib(bucket: str, object_name: str) -> str:
    from google.cloud import storage

    client = storage.Client()
    b = client.bucket(bucket)
    blob = b.blob(object_name)
    if not blob.exists():
        return ""
    return blob.download_as_text()


def _download_text_cli(bucket: str, object_name: str) -> str:
    uri = f"gs://{bucket}/{object_name}"
    fd, path = tempfile.mkstemp(suffix=".cidr-registry.txt")
    os.close(fd)
    try:
        if shutil.which("gcloud"):
            r = subprocess.run(
                ["gcloud", "storage", "cp", uri, path],
                capture_output=True,
                text=True,
            )
        elif shutil.which("gsutil"):
            r = subprocess.run(
                ["gsutil", "cp", uri, path],
                capture_output=True,
                text=True,
            )
        else:
            die(
                "GCS: install google-cloud-storage (pip install -r modules/blueprint/scripts/requirements-cidr.txt) "
                "or install Google Cloud SDK (gcloud / gsutil).",
            )
        if r.returncode != 0:
            err = (r.stderr or "") + (r.stdout or "")
            low = err.lower()
            # Missing object (first apply / new bucket): gcloud and gsutil use different error text.
            if (
                "404" in err
                or "not found" in low
                or "no urls matched" in low
                or "matched no objects" in low
            ):
                return ""
            die(f"download failed ({uri}): {err}")
        with open(path, encoding="utf-8") as f:
            return f.read()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def download_text(bucket: str, object_name: str) -> str:
    try:
        return _download_text_lib(bucket, object_name)
    except ImportError:
        return _download_text_cli(bucket, object_name)


def _upload_text_lib(bucket: str, object_name: str, body: str) -> None:
    from google.cloud import storage

    client = storage.Client()
    b = client.bucket(bucket)
    blob = b.blob(object_name)
    blob.upload_from_string(body, content_type="text/plain; charset=utf-8")


def _upload_text_cli(bucket: str, object_name: str, body: str) -> None:
    uri = f"gs://{bucket}/{object_name}"
    fd, path = tempfile.mkstemp(suffix=".cidr-registry.txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(body)
        if shutil.which("gcloud"):
            subprocess.run(
                ["gcloud", "storage", "cp", path, uri],
                check=True,
                capture_output=True,
                text=True,
            )
        elif shutil.which("gsutil"):
            subprocess.run(
                ["gsutil", "cp", path, uri],
                check=True,
                capture_output=True,
                text=True,
            )
        else:
            die(
                "GCS: install google-cloud-storage (pip) or Google Cloud SDK (gcloud / gsutil).",
            )
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def upload_text(bucket: str, object_name: str, body: str) -> None:
    try:
        _upload_text_lib(bucket, object_name, body)
    except ImportError:
        _upload_text_cli(bucket, object_name, body)


def run_validate_stdin() -> None:
    query = json.load(sys.stdin)
    peer_env = query.get("peer_env") or ""
    project_id = query.get("project_id") or ""
    vpc_cidr = query.get("vpc_cidr") or ""
    subnets_json = query.get("subnets_json") or "[]"
    bucket = (query.get("bucket") or "").strip()
    object_name = query.get("object") or "cidr-registry.txt"

    subnets = json.loads(subnets_json)
    if not isinstance(subnets, list):
        die("subnets_json must be a JSON array")

    validate_subnets_in_vpc(vpc_cidr, subnets)

    if not bucket:
        # No GCS: only local geometry checks.
        out = {"valid": "true", "allocations_checked": str(len(rows_for_stack(peer_env, project_id, vpc_cidr, subnets)))}
        print(json.dumps(out))
        return

    existing_text = download_text(bucket, object_name)
    existing = parse_registry(existing_text)
    merged = merge_registry(existing, peer_env, project_id, vpc_cidr, subnets)
    vpc_overlap(merged)
    n = len(rows_for_stack(peer_env, project_id, vpc_cidr, subnets))
    print(json.dumps({"valid": "true", "allocations_checked": str(n)}))


def load_subnets_from_env() -> list[dict]:
    raw = os.environ.get("SUBNETS_JSON", "[]")
    s = json.loads(raw)
    if not isinstance(s, list):
        die("SUBNETS_JSON must be a JSON array")
    return s


def cmd_apply() -> None:
    peer_env = os.environ["PEER_ENV"]
    project_id = os.environ["PROJECT_ID"]
    vpc_cidr = os.environ["VPC_CIDR"]
    bucket = os.environ["BUCKET"]
    object_name = os.environ["OBJECT"]
    subnets = load_subnets_from_env()

    validate_subnets_in_vpc(vpc_cidr, subnets)
    existing_text = download_text(bucket, object_name)
    existing = parse_registry(existing_text)
    merged = merge_registry(existing, peer_env, project_id, vpc_cidr, subnets)
    vpc_overlap(merged)
    upload_text(bucket, object_name, registry_text(merged))
    print(f"cidr_registry_gcs_sync: uploaded merged registry to gs://{bucket}/{object_name}", file=sys.stderr)


def cmd_destroy() -> None:
    peer_env = os.environ["PEER_ENV"]
    bucket = os.environ["BUCKET"]
    object_name = os.environ["OBJECT"]

    existing_text = download_text(bucket, object_name)
    existing = parse_registry(existing_text)
    merged = remove_env_rows(existing, peer_env)
    upload_text(bucket, object_name, registry_text(merged))
    print(
        f"cidr_registry_gcs_sync: removed rows for env={peer_env} in gs://{bucket}/{object_name}",
        file=sys.stderr,
    )


def main() -> None:
    if len(sys.argv) < 2:
        die("usage: cidr_registry_gcs_sync.py validate | apply | destroy")
    cmd = sys.argv[1]
    if cmd == "validate":
        run_validate_stdin()
    elif cmd == "apply":
        cmd_apply()
    elif cmd == "destroy":
        cmd_destroy()
    else:
        die(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
