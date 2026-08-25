#!/usr/bin/env bash
# Build and publish docker/cci-builder.Dockerfile through a short-lived CCI2
# Kaniko Pod. The only credential passed to that Pod is the short-lived SWR
# authorization token returned by CreateAuthorizationToken.

set -Eeuo pipefail

CCI_REGION="${CCI_REGION:-cn-southwest-2}"
CCI_NAMESPACE="${CCI_NAMESPACE:-cam-tl00-ci2}"
CCI_INSTANCE_TYPE="${CCI_INSTANCE_TYPE:-general-computing}"
CCI_POD_SIZE="${CCI_POD_SIZE:-4.00_8.0}"
CCI_EXTRA_STORAGE_GIB="${CCI_EXTRA_STORAGE_GIB:-20}"
CCI_DEADLINE_SECONDS="${CCI_DEADLINE_SECONDS:-3600}"
# The default CCI network already has outbound access to GitHub and private
# SWR/OBS endpoints.  EIP allocation is optional and currently exhausts the
# Guiyang pool, so opt in only when a dedicated EIP is required.
CCI_WITH_EIP="${CCI_WITH_EIP:-0}"
# Keep the overseas-safe official Ubuntu archive as the default.  Set this to
# 1 only when the CCI network is known to reach the mainland mirrors.
USE_CN_MIRRORS="${USE_CN_MIRRORS:-0}"
GITHUB_REPO="${GITHUB_REPO:-baiyunquan/Action-LineageOS-Builder}"
GITHUB_REF="${GITHUB_REF:-main}"
SWR_REGISTRY="${SWR_REGISTRY:-swr.cn-southwest-2.myhuaweicloud.com}"
SWR_NAMESPACE="${SWR_NAMESPACE:-cam-tl00-ci}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-lineageos-15.1-builder}"
KANIKO_IMAGE="${KANIKO_IMAGE:-${SWR_REGISTRY}/${SWR_NAMESPACE}/kaniko-executor@sha256:8a4f9af8ef55ef8bfaf4cfd7b15dc956609e14a4402efefd5fb2e49a0c06e2c8}"
RUN_ID="${RUN_ID:-cci-builder-$(date -u +%Y%m%d-%H%M%S)}"
POD_NAME="${POD_NAME:-cam-tl00-builder-${RUN_ID#cci-builder-}}"
POD_NAME="${POD_NAME,,}"
SECRET_NAME="${SECRET_NAME:-cam-tl00-kaniko-auth-${RUN_ID#cci-builder-}}"
CANDIDATE_TAG="${CANDIDATE_TAG:-preinstalled-${RUN_ID#cci-builder-}}"
TARGET_IMAGE="${SWR_REGISTRY}/${SWR_NAMESPACE}/${IMAGE_REPOSITORY}:${CANDIDATE_TAG}"

command -v hcloud >/dev/null || { echo "!! hcloud/KooCLI is required" >&2; exit 1; }
command -v crane >/dev/null || { echo "!! crane is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "!! python3 is required" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
cleanup() {
    local rc=$?
    if [ "${POD_CREATED:-0}" = 1 ]; then
        hcloud CCI deleteNamespacedPod --cli-region="${CCI_REGION}" \
            --namespace="${CCI_NAMESPACE}" --name="${POD_NAME}" >/dev/null 2>&1 || true
    fi
    if [ "${SECRET_CREATED:-0}" = 1 ]; then
        hcloud CCI deleteNamespacedSecret --cli-region="${CCI_REGION}" \
            --namespace="${CCI_NAMESPACE}" --name="${SECRET_NAME}" >/dev/null 2>&1 || true
    fi
    python3 - "${tmp_dir}" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
    exit "${rc}"
}
trap cleanup EXIT

export DOCKER_CONFIG="${tmp_dir}/docker"
mkdir -p "${DOCKER_CONFIG}"
SWR_AUTH="$(hcloud SWR CreateAuthorizationToken --cli-region="${CCI_REGION}" 2>/dev/null | \
    python3 -c 'import json,sys; raw=sys.stdin.read(); obj=json.loads(raw[raw.find("{"):]); print(next(iter(obj["auths"].values()))["auth"])')"
crane auth login "${SWR_REGISTRY}" --username token --password "${SWR_AUTH}" >/dev/null

manifest="${tmp_dir}/pod.json"
export CCI_REGION CCI_NAMESPACE CCI_INSTANCE_TYPE CCI_POD_SIZE CCI_EXTRA_STORAGE_GIB \
    CCI_DEADLINE_SECONDS CCI_WITH_EIP GITHUB_REPO GITHUB_REF SWR_REGISTRY SWR_NAMESPACE \
    IMAGE_REPOSITORY KANIKO_IMAGE RUN_ID POD_NAME SECRET_NAME TARGET_IMAGE SWR_AUTH \
    USE_CN_MIRRORS
secret_manifest="${tmp_dir}/secret.json"
python3 - "${secret_manifest}" <<'PY'
import json, os, sys
registry = os.environ["SWR_REGISTRY"]
docker_config = json.dumps({"auths": {registry: {"auth": os.environ["SWR_AUTH"]}}}, separators=(",", ":"))
body = {
    "apiVersion": "cci/v2",
    "kind": "Secret",
    "metadata": {"name": os.environ["SECRET_NAME"], "namespace": os.environ["CCI_NAMESPACE"]},
    "type": "kubernetes.io/dockerconfigjson",
    "stringData": {".dockerconfigjson": docker_config},
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"path": {"namespace": os.environ["CCI_NAMESPACE"]}, "query": {}, "body": body}, stream)
PY
echo "==> Creating temporary Kaniko registry Secret"
hcloud CCI createNamespacedSecret --cli-region="${CCI_REGION}" \
    --namespace="${CCI_NAMESPACE}" --cli-jsonInput="${secret_manifest}" >/dev/null
SECRET_CREATED=1

python3 - "${manifest}" <<'PY'
import json, os, sys

repo = os.environ["GITHUB_REPO"]
ref = os.environ["GITHUB_REF"]
top = repo.rsplit("/", 1)[-1] + "-" + ref
destination = os.environ["TARGET_IMAGE"]
registry = os.environ["SWR_REGISTRY"]
command = [
    "/kaniko/executor",
    "--context=https://github.com/" + repo + "/archive/refs/heads/" + ref + ".tar.gz",
    "--dockerfile=" + top + "/docker/cci-builder.Dockerfile",
    "--destination=" + destination,
    "--build-arg=USE_CN_MIRRORS=" + os.environ["USE_CN_MIRRORS"],
    "--custom-platform=linux/amd64", "--cache=false", "--verbosity=info",
]
body = {
    "apiVersion": "cci/v2",
    "kind": "Pod",
    "metadata": {
        "name": os.environ["POD_NAME"],
        "namespace": os.environ["CCI_NAMESPACE"],
        "labels": {"app": "cam-tl00-cci-builder", "run": os.environ["RUN_ID"]},
        "annotations": {
            "resource.cci.io/instance-type": os.environ["CCI_INSTANCE_TYPE"],
            "resource.cci.io/pod-size-specs": os.environ["CCI_POD_SIZE"],
        },
    },
    "spec": {
        "activeDeadlineSeconds": int(os.environ["CCI_DEADLINE_SECONDS"]),
        "extraEphemeralStorage": {"sizeInGiB": int(os.environ["CCI_EXTRA_STORAGE_GIB"])},
        "restartPolicy": "Never",
        "containers": [{
            "name": "kaniko",
            "image": os.environ["KANIKO_IMAGE"],
            "command": command,
            "volumeMounts": [{"name": "docker-config", "mountPath": "/kaniko/.docker"}],
            "terminationMessagePath": "/dev/termination-log",
        }],
        "volumes": [{"name": "docker-config", "secret": {"secretName": os.environ["SECRET_NAME"]}}],
    },
}
if os.environ["CCI_WITH_EIP"] == "1":
    body["metadata"]["annotations"].update({
        "yangtse.io/pod-with-eip": "true",
        "yangtse.io/eip-bandwidth-size": "5",
        "yangtse.io/eip-network-type": "5_bgp",
        "yangtse.io/eip-charge-mode": "traffic",
    })
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"path": {"namespace": os.environ["CCI_NAMESPACE"]},
               "query": {}, "body": body}, stream)
PY

echo "==> Creating Kaniko CCI2 Pod ${POD_NAME}"
create_output="${tmp_dir}/create.out"
hcloud CCI createNamespacedPod --cli-region="${CCI_REGION}" \
    --namespace="${CCI_NAMESPACE}" --cli-jsonInput="${manifest}" >"${create_output}" 2>&1
python3 - "${create_output}" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
obj = json.loads(raw[raw.find("{"):])
if obj.get("status") == "Failure":
    raise SystemExit(obj.get("message", "CCI create failed"))
print("pod uid:", obj.get("metadata", {}).get("uid", "unknown"))
PY
POD_CREATED=1

while :; do
    status_file="${tmp_dir}/status.json"
    hcloud CCI readNamespacedPod --cli-region="${CCI_REGION}" \
        --namespace="${CCI_NAMESPACE}" --name="${POD_NAME}" >"${status_file}"
    phase="$(python3 - "${status_file}" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
obj = json.loads(raw[raw.find("{"):])
print(obj.get("status", {}).get("phase", "Unknown"))
PY
    )"
    echo "   ${POD_NAME}: ${phase}"
    case "${phase}" in
        Succeeded) break ;;
        Failed)
            python3 - "${status_file}" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
obj = json.loads(raw[raw.find("{"):])
status = obj.get("status", {})
print(json.dumps({"phase": status.get("phase"), "conditions": status.get("conditions", []),
                  "containerStatuses": status.get("containerStatuses", [])}, ensure_ascii=False))
PY
            exit 1 ;;
        *) sleep "${CCI_POLL_SECONDS:-15}" ;;
    esac
done

digest="$(crane digest "${TARGET_IMAGE}")"
printf 'BUILDER_IMAGE=%s@%s\n' "${TARGET_IMAGE%:*}" "${digest}"
