#!/usr/bin/env bash
# One-time root setup on the US VPS. Run on the VPS, not on the ECS.
# It publishes /home/liaic/lineage-upload through the existing Nginx site.

set -Eeuo pipefail

[[ "${EUID}" -eq 0 ]] || { echo 'run as root (sudo -i)' >&2; exit 1; }

STAGE_DIR="${STAGE_DIR:-/home/liaic/lineage-upload}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/srv/lineage-downloads}"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-/lineage-source}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-enabled/liaic.cyou}"
DOWNLOAD_DOMAIN="${DOWNLOAD_DOMAIN:-}"
SNIPPET="/etc/nginx/snippets/lineage-download.conf"

[[ -f "${NGINX_SITE}" ]] || { echo "missing ${NGINX_SITE}" >&2; exit 1; }
[[ "${DOWNLOAD_PREFIX}" == /* && "${DOWNLOAD_PREFIX}" != */ ]] || {
    echo 'DOWNLOAD_PREFIX must begin with / and not end with /' >&2; exit 1;
}

install -d -m 0755 -o root -g root "${DOWNLOAD_DIR}"
if compgen -G "${STAGE_DIR}/lineage15.1-source.tar.zst.part-*" >/dev/null; then
    mv "${STAGE_DIR}"/lineage15.1-source.tar.zst.part-* "${DOWNLOAD_DIR}/"
fi
for f in SHA256SUMS SOURCE-METADATA; do
    [[ ! -f "${STAGE_DIR}/${f}" ]] || mv "${STAGE_DIR}/${f}" "${DOWNLOAD_DIR}/${f}"
done
chown -R root:root "${DOWNLOAD_DIR}"
find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -exec chmod 0644 {} +

cat >"${SNIPPET}" <<EOF
# Managed by the LineageOS source handoff.
location ^~ ${DOWNLOAD_PREFIX}/ {
    alias ${DOWNLOAD_DIR}/;
    autoindex on;
    autoindex_exact_size off;
    default_type application/octet-stream;
    add_header Cache-Control "no-cache";
}
EOF

if ! grep -Fq "include ${SNIPPET};" "${NGINX_SITE}"; then
    cp -a "${NGINX_SITE}" "${NGINX_SITE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    python3 - "${NGINX_SITE}" "${SNIPPET}" <<'PY'
import pathlib
import sys

site = pathlib.Path(sys.argv[1])
snippet = sys.argv[2]
text = site.read_text()
needle = "    location / {"
if needle not in text:
    raise SystemExit("could not find the existing proxy location")
text = text.replace(needle, f"    include {snippet};\n{needle}", 1)
site.write_text(text)
PY
fi

/usr/sbin/nginx -t
systemctl reload nginx
if [[ -n "${DOWNLOAD_DOMAIN}" ]]; then
    echo "Published URL: https://${DOWNLOAD_DOMAIN}${DOWNLOAD_PREFIX}/"
else
    echo "Published path: ${DOWNLOAD_PREFIX}/ (use this server's HTTPS domain)"
fi
