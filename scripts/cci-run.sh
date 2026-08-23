#!/usr/bin/env bash
# Create and monitor one CCI2 build Pod through KooCLI.
# Credentials are read from the environment and only written to a short-lived
# manifest under /tmp. They are never printed or committed.

set -Eeuo pipefail

CCI_REGION="${CCI_REGION:-cn-southwest-2}"
CCI_NAMESPACE="${CCI_NAMESPACE:-cam-tl00-ci2}"
CCI_IMAGE="${CCI_IMAGE:-swr.cn-southwest-2.myhuaweicloud.com/cam-tl00-ci/ubuntu18-build-base@sha256:dca176c9663a7ba4c1f0e710986f5a25e672842963d95b960191e2d9f7185ebe}"
CCI_INSTANCE_TYPE="${CCI_INSTANCE_TYPE:-general-computing}"
CCI_POD_SIZE="${CCI_POD_SIZE:-16.00_32.0}"
CCI_EXTRA_STORAGE_GIB="${CCI_EXTRA_STORAGE_GIB:-470}"
CCI_DEADLINE_SECONDS="${CCI_DEADLINE_SECONDS:-21600}"
GITHUB_REPO="${GITHUB_REPO:-baiyunquan/Action-LineageOS-Builder}"
GITHUB_REF="${GITHUB_REF:-main}"
OBS_BUCKET="${OBS_BUCKET:-cam-tl00-ci-019e42eb6d98}"
OBS_ENDPOINT="${OBS_ENDPOINT:-https://obs.cn-southwest-2.myhuaweicloud.com}"
RUN_ID="${RUN_ID:-cci-$(date -u +%Y%m%d-%H%M%S)}"
POD_NAME="${POD_NAME:-cam-tl00-build-${RUN_ID#cci-}}"
POD_NAME="${POD_NAME,,}"

: "${OBS_ACCESS_KEY:?export OBS_ACCESS_KEY with a fresh temporary AK}"
: "${OBS_SECRET_KEY:?export OBS_SECRET_KEY with a fresh temporary SK}"
: "${OBS_SECURITY_TOKEN:?export OBS_SECURITY_TOKEN with a fresh security token}"
command -v hcloud >/dev/null || { echo "!! hcloud/KooCLI is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "!! python3 is required" >&2; exit 1; }

input_file="$(mktemp --suffix=.json)"
create_output="$(mktemp)"
trap 'rm -f "${input_file}" "${create_output}"' EXIT

export POD_NAME CCI_NAMESPACE CCI_INSTANCE_TYPE CCI_POD_SIZE CCI_EXTRA_STORAGE_GIB \
    CCI_DEADLINE_SECONDS CCI_IMAGE GITHUB_REPO GITHUB_REF OBS_BUCKET OBS_ENDPOINT RUN_ID \
    OBS_ACCESS_KEY OBS_SECRET_KEY OBS_SECURITY_TOKEN

python3 - "${input_file}" <<'PY'
import json
import os
import sys

name = os.environ["POD_NAME"]
namespace = os.environ["CCI_NAMESPACE"]
entrypoint = (
    "curl -fsSL https://raw.githubusercontent.com/"
    + os.environ["GITHUB_REPO"] + "/" + os.environ["GITHUB_REF"]
    + "/scripts/cci-pod-entrypoint.sh | bash"
)
env_names = (
    "GITHUB_REPO", "GITHUB_REF", "OBS_BUCKET", "OBS_ENDPOINT", "RUN_ID",
    "OBS_ACCESS_KEY", "OBS_SECRET_KEY", "OBS_SECURITY_TOKEN",
)
body = {
    "apiVersion": "cci/v2",
    "kind": "Pod",
    "metadata": {
        "name": name,
        "namespace": namespace,
        "labels": {"app": "cam-tl00-lineage-build", "run": os.environ["RUN_ID"]},
        "annotations": {
            "resource.cci.io/instance-type": os.environ["CCI_INSTANCE_TYPE"],
            "resource.cci.io/pod-size-specs": os.environ["CCI_POD_SIZE"],
            "yangtse.io/pod-with-eip": "true",
            "yangtse.io/eip-bandwidth-size": "5",
            "yangtse.io/eip-network-type": "5_bgp",
            "yangtse.io/eip-charge-mode": "traffic",
        },
    },
    "spec": {
        "activeDeadlineSeconds": int(os.environ["CCI_DEADLINE_SECONDS"]),
        "extraEphemeralStorage": {"sizeInGiB": int(os.environ["CCI_EXTRA_STORAGE_GIB"])},
        "restartPolicy": "Never",
        "containers": [{
            "name": "builder",
            "image": os.environ["CCI_IMAGE"],
            "command": ["bash", "-lc"],
            "args": [entrypoint],
            "env": [{"name": key, "value": os.environ[key]} for key in env_names],
        }],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"path": {"namespace": namespace}, "query": {}, "body": body}, stream)
PY

if [ "${CCI_DRY_RUN:-0}" = 1 ]; then
    python3 - "${input_file}" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
for item in obj["body"]["spec"]["containers"][0]["env"]:
    if item["name"] in {"OBS_ACCESS_KEY", "OBS_SECRET_KEY", "OBS_SECURITY_TOKEN"}:
        item["value"] = "<redacted>"
print(json.dumps(obj, indent=2, ensure_ascii=False))
PY
    exit 0
fi

echo "==> Creating CCI2 Pod ${POD_NAME} in ${CCI_REGION}/${CCI_NAMESPACE}"
hcloud CCI createNamespacedPod --cli-region="${CCI_REGION}" \
    --namespace="${CCI_NAMESPACE}" --cli-jsonInput="${input_file}" >"${create_output}" 2>&1
python3 - "${create_output}" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
start = raw.find("{")
if start < 0:
    print("KooCLI returned no JSON response:", raw[:2000], file=sys.stderr)
    raise SystemExit(1)
obj = json.loads(raw[start:])
if obj.get("status") == "Failure":
    print(obj.get("message", "CCI create failed"), file=sys.stderr)
    raise SystemExit(1)
print("pod uid:", obj.get("metadata", {}).get("uid", "unknown"))
PY

delete_pod() {
    if [ "${CCI_KEEP_POD:-0}" = 1 ]; then
        echo "==> CCI_KEEP_POD=1; leaving ${POD_NAME} for inspection"
        rm -f "${input_file}" "${create_output}"
        return
    fi
    hcloud CCI deleteNamespacedPod --cli-region="${CCI_REGION}" \
        --namespace="${CCI_NAMESPACE}" --name="${POD_NAME}" >/dev/null 2>&1 || true
    rm -f "${input_file}" "${create_output}"
}
trap delete_pod EXIT

while :; do
    status_file="$(mktemp)"
    if ! hcloud CCI readNamespacedPod --cli-region="${CCI_REGION}" \
        --namespace="${CCI_NAMESPACE}" --name="${POD_NAME}" >"${status_file}"; then
        rm -f "${status_file}"
        echo "!! failed to read CCI2 Pod status" >&2
        exit 1
    fi
    phase="$(python3 - "${status_file}" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
print(obj.get("status", {}).get("phase", "Unknown"))
PY
    )"
    rm -f "${status_file}"
    echo "   ${POD_NAME}: ${phase}"
    case "${phase}" in
        Succeeded) exit 0 ;;
        Failed) exit 1 ;;
        *) sleep "${CCI_POLL_SECONDS:-30}" ;;
    esac
done
