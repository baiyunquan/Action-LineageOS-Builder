# Huawei Cloud CCI2 build runner

This repository keeps GitHub as the source of truth and uses a short-lived
Huawei Cloud Container Instance (CCI2) Pod as the x86 build worker. It does
not migrate the repository to CodeArts Repo.

## Verified Guiyang resources

| Resource | Value |
|---|---|
| Region | `cn-southwest-2` (西南-贵阳一) |
| CCI2 namespace | `cam-tl00-ci2` |
| CCI2 network | `cam-tl00-ci2-net` (Ready, default network) |
| VPC / subnet | default VPC `c9dad356-d149-4ffb-aa87-592e3ea77ba2` / default subnet `bc2df77a-3fb4-49c0-8d16-3bcae80a9b75` |
| SWR image | `swr.cn-southwest-2.myhuaweicloud.com/cam-tl00-ci/ubuntu18-build-base:18.04` |
| Image digest tested | `sha256:dca176c9663a7ba4c1f0e710986f5a25e672842963d95b960191e2d9f7185ebe` |
| OBS bucket | `cam-tl00-ci-019e42eb6d98` (private) |

The CCI2 API accepts the `general-computing` sale policy in this account. The
`general-computing-lite` value advertised by the feature-gate response was
rejected by the API, so production Pods must use the standard type. The tested
working allocation is `16.00_32.0` (16 vCPU / 32 GiB) with 470 GiB of extra
ephemeral storage, which gives 500 GiB total including CCI's 30 GiB default.

Two VPCEP endpoints are required for private SWR pulls in this VPC:

- `com.myhuaweicloud.cn-southwest-2.swr` — endpoint `ea22b5fc-13db-438a-bb44-d50afd71b3e0`
- `com.myhuaweicloud.cn-southwest-2.swr-api` — endpoint `a4d458e1-2c77-4620-b1d2-fd25a6d75a03`

Both are active. The smoke Pod pulled the exact image digest, reached
`github.com:443`, and exited with code 0. It was deleted afterwards; no Pod is
left running.

## CCI2 execution model

CCI2's supported object is a standalone `apiVersion: cci/v2`, `kind: Pod`.
The old CCI1 `Job` endpoint rejects this account's sale policy and is not used.
The local KooCLI runner will:

1. create one Pod with `activeDeadlineSeconds` and `restartPolicy: Never`;
2. let the Pod clone the public GitHub repository, run `sync-source.sh`, hydrate
   Git LFS, and run `build-in-container.sh`;
3. upload logs, ccache, and verified ROM artifacts to the private OBS bucket;
4. poll `readNamespacedPod` until `Succeeded`/`Failed`; and
5. delete the Pod in a `finally` path so compute and EIP billing stop.

CCI2 has no supported v2 log-read operation in KooCLI, so the Pod must upload
its log before exiting. OBS temporary AK/SK/security-token credentials are
passed only for the lifetime of the Pod and are never committed to this
repository.

## Before the first paid build

- Confirm the account's CCI and EIP quotas in the Guiyang region.
- Confirm the OBS bucket has at least 500 GiB of usable capacity (the source
  tree and `out/` can be large; lifecycle rules currently expire `runs/` and
  `cache/` after 30 days and `tmp/` after 2 days).
- Generate a fresh temporary OBS credential immediately before starting a run;
  do not reuse or paste `credentials.csv` into a Pod manifest.
- Start with the default 6-hour deadline and 16 vCPU / 32 GiB. A second run
  reuses ccache from OBS; lower concurrency only if the memory monitor shows
  pressure.
