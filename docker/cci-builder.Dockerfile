# Preinstalled CCI2 builder for LineageOS 15.1 (Android 8.1).
#
# The base is the amd64 ubuntu:18.04 mirror already present in SWR.  Keeping
# the base in SWR means CCI never has to pull a third-party runtime image.
FROM swr.cn-southwest-2.myhuaweicloud.com/cam-tl00-ci/ubuntu18-build-base@sha256:dca176c9663a7ba4c1f0e710986f5a25e672842963d95b960191e2d9f7185ebe

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG OBSUTIL_URL=https://obs-community-intl.obs.ap-southeast-1.myhuaweicloud.com/obsutil/current/obsutil_linux_amd64.tar.gz
ARG GIT_LFS_VERSION=3.5.1
ARG USE_CN_MIRRORS=false
ARG APT_MIRROR_PRIMARY=
ARG APT_MIRROR_FALLBACK=

# The default uses the official Ubuntu archive.  Set USE_CN_MIRRORS=true for a
# mainland-China CCI network to try Huawei Cloud and then Aliyun.  HTTP is used
# only for the first apt transaction because the base image has no CA bundle;
# ca-certificates is installed in that transaction before HTTPS downloads.
# Disable the expiry check so a cached CCI base cannot make apt fail with an
# opaque 100.
# Every apt operation is logged before its error is re-raised; Kaniko therefore
# leaves useful diagnostics in the build log and in /var/log/cci-builder-apt.log.
RUN set -Eeuo pipefail; \
    test "$(dpkg --print-architecture)" = amd64; \
    mkdir -p /var/log; \
    write_sources() { \
      printf '%s\n' \
        "deb $${1%/} bionic main restricted universe multiverse" \
        "deb $${1%/} bionic-updates main restricted universe multiverse" \
        "deb $${1%/} bionic-security main restricted universe multiverse" \
        > /etc/apt/sources.list; \
    }; \
    printf '%s\n' \
      'Acquire::Check-Valid-Until "false";' \
      'Acquire::Retries "3";' \
      > /etc/apt/apt.conf.d/99cci-builder; \
    use_cn_mirrors="$${USE_CN_MIRRORS}"; \
    case "$${use_cn_mirrors,,}" in \
      1|true|yes|on) \
        mirror_primary="$${APT_MIRROR_PRIMARY:-http://repo.huaweicloud.com/ubuntu}"; \
        mirror_fallback="$${APT_MIRROR_FALLBACK:-http://mirrors.aliyun.com/ubuntu}"; \
        mirror_label='Huawei Cloud/Aliyun' ;; \
      *) \
        mirror_primary="$${APT_MIRROR_PRIMARY:-http://archive.ubuntu.com/ubuntu}"; \
        mirror_fallback="$${APT_MIRROR_FALLBACK:-http://security.ubuntu.com/ubuntu}"; \
        mirror_label='official Ubuntu' ;; \
    esac; \
    echo "apt mirror mode: $${mirror_label} (USE_CN_MIRRORS=$${use_cn_mirrors})"; \
    apt_run() { \
      echo "### apt $*" >> /var/log/cci-builder-apt.log; \
      "$@" >> /var/log/cci-builder-apt.log 2>&1 || { \
        rc=$$?; echo "### apt failed ($$rc)" >&2; tail -200 /var/log/cci-builder-apt.log >&2; return "$$rc"; \
      }; \
    }; \
    : > /var/log/cci-builder-apt.log; \
    write_sources "$${mirror_primary}"; \
    if ! apt_run apt-get update; then \
      echo "### $${mirror_label} primary mirror failed; retrying fallback" >&2; \
      write_sources "$${mirror_fallback}"; \
      apt_run apt-get update; \
    fi; \
    apt_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 tar gzip rsync \
      openjdk-8-jdk \
      bc bison build-essential ccache flex g++-multilib gcc-multilib \
      gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev \
      liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
      libwxgtk3.0-dev libxml2 libxml2-utils lzop pngcrush schedtool \
      squashfs-tools xsltproc zip zlib1g-dev unzip python python-minimal; \
    if ! command -v git-lfs >/dev/null 2>&1; then \
      echo '### apt git-lfs' >> /var/log/cci-builder-apt.log; \
      if ! env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git-lfs >> /var/log/cci-builder-apt.log 2>&1; then \
        curl -fL --retry 3 "https://github.com/git-lfs/git-lfs/releases/download/v$${GIT_LFS_VERSION}/git-lfs-linux-amd64-v$${GIT_LFS_VERSION}.tar.gz" -o /tmp/git-lfs.tar.gz >> /var/log/cci-builder-apt.log 2>&1; \
        tar -xzf /tmp/git-lfs.tar.gz -C /tmp; \
        install -m 0755 "/tmp/git-lfs-$${GIT_LFS_VERSION}/git-lfs" /usr/local/bin/git-lfs; \
      fi; \
    fi; \
    rm -rf /var/lib/apt/lists/* /tmp/git-lfs.tar.gz /tmp/git-lfs-*;

# repo is intentionally installed in the image: the CCI entrypoint must not
# download tooling or mutate apt state on every large build.
RUN set -Eeuo pipefail; \
    curl -fL --retry 3 https://storage.googleapis.com/git-repo-downloads/repo \
      -o /usr/local/bin/repo; \
    chmod 0755 /usr/local/bin/repo; \
    repo --version >/dev/null

# obsutil's amd64 archive contains a versioned directory.  Install only the
# binary and keep the archive out of the final layer.
RUN set -Eeuo pipefail; \
    curl -fL --retry 3 "${OBSUTIL_URL}" -o /tmp/obsutil.tar.gz; \
    obsutil_binary="$$(tar -tzf /tmp/obsutil.tar.gz | awk '/(^|\/)obsutil$$/ {print; exit}')"; \
    test -n "$${obsutil_binary}"; \
    tar -xzf /tmp/obsutil.tar.gz -C /tmp; \
    install -m 0755 "/tmp/$${obsutil_binary}" /usr/local/bin/obsutil; \
    /usr/local/bin/obsutil version >/dev/null 2>&1 || true; \
    rm -rf /tmp/obsutil.tar.gz /tmp/obsutil_linux_amd64*

RUN set -Eeuo pipefail; \
    git lfs install --system; \
    command -v java python python3 git git-lfs repo obsutil ccache curl rsync >/dev/null; \
    java -version 2>&1 | grep -q '1.8'; \
    python --version 2>&1 | grep -q 'Python 2'; \
    git-lfs version; \
    repo --version

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 \
    PATH=/usr/lib/jvm/java-8-openjdk-amd64/bin:/usr/local/bin:${PATH} \
    USE_CCACHE=1 \
    ANDROID_COMPILE_WITH_JACK=false \
    SKIP_APT_INSTALL=1 \
    LC_ALL=C

WORKDIR /workspace
CMD ["/bin/bash"]
