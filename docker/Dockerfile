# Build environment for LineageOS 15.1 (Android 8.1).
#
# ubuntu:18.04 rather than a current release because AOSP 8.1 builds its *host*
# tools with the system compiler: gcc-11/12 rejects a lot of 2017-era C++, and
# modern releases ship neither python2 nor openjdk-8. bionic has all three
# natively, so the tree builds unmodified.
#
# Unlike the CI path, this image is built once and reused, so dependency install
# does not cost anything on repeat builds.
#
#   docker build -t lineageos-15.1-builder docker/
FROM ubuntu:18.04

ARG USE_CN_MIRRORS=false
ARG APT_MIRROR_PRIMARY=
ARG APT_MIRROR_FALLBACK=

# The default is the official Ubuntu archive, which is reachable from GitHub's
# overseas runners.  Set --build-arg USE_CN_MIRRORS=true when building on a
# mainland-China host to try Huawei Cloud and then Aliyun instead.  HTTP is
# used for the bootstrap because the minimal image has no CA bundle yet.
RUN set -Eeuo pipefail; \
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
    write_sources() { \
      printf '%s\n' \
        "deb $${1%/} bionic main restricted universe multiverse" \
        "deb $${1%/} bionic-updates main restricted universe multiverse" \
        "deb $${1%/} bionic-security main restricted universe multiverse" \
        > /etc/apt/sources.list; \
    }; \
    write_sources "$${mirror_primary}"; \
    if ! apt-get update; then \
      echo "$${mirror_label} primary mirror failed; retrying fallback" >&2; \
      write_sources "$${mirror_fallback}"; \
      apt-get update; \
    fi; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        openjdk-8-jdk \
        bc bison build-essential ccache curl flex g++-multilib gcc-multilib \
        git gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev \
        lib32z1-dev liblz4-tool libncurses5 libncurses5-dev libsdl1.2-dev \
        libssl-dev libwxgtk3.0-dev libxml2 libxml2-utils lzop pngcrush rsync \
        schedtool squashfs-tools xsltproc zip zlib1g-dev unzip \
        python python-minimal \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"
ENV LC_ALL=C

# Jack talks to a background server over a local TLS socket whose certificates
# are generated on first use; in a container that fails with "SSL error when
# connecting to the Jack server" and kills the build at setup-jack-server. Jack
# was deprecated in Android 8.0 and 8.1 builds fine on the javac/d8 path.
ENV ANDROID_COMPILE_WITH_JACK=false

# The container runs as the invoking host user (--user "$(id -u):$(id -g)"), so
# there is no matching /etc/passwd entry and HOME must be supplied at run time.
WORKDIR /work
