#!/usr/bin/env bash
# Auto-configure and refresh Kismet cell datasource entries and GPS forwarding.
# Intended to be run via systemd (oneshot) to keep config up to date on boot.
set -euo pipefail

PREFIX="${PREFIX:-/usr}"
BASE_PORT="${BASE_PORT:-9875}"
GPS_PORT="${GPS_PORT:-8766}"
FORWARD_GPS="${FORWARD_GPS:-1}"
TRANSPORT_MODE="usb"
KEEP_EMPTY_SOURCES="${KEEP_EMPTY_SOURCES:-0}"
BIN_DIR="${PREFIX}/bin"
APPLY_PATH="${APPLY_PATH:-/etc/kismet/datasources.d/cell.conf}"
RUNTIME_SOURCE_FILE="${RUNTIME_SOURCE_FILE:-/var/lib/kismet/cell/sources.generated}"
ADB_BIN="$(command -v adb || true)"

log() { printf '[cell-autoconfig] %s\n' "$*"; }

detect_kismet_site_conf() {
  if [[ -n "${KISMET_SITE_CONF:-}" ]]; then
    printf '%s\n' "${KISMET_SITE_CONF}"
  elif [[ -f /etc/kismet.conf || -f /etc/kismet_site.conf ]]; then
    printf '%s\n' "/etc/kismet_site.conf"
  else
    printf '%s\n' "/etc/kismet/kismet_site.conf"
  fi
}

KISMET_SITE_CONF="$(detect_kismet_site_conf)"

port_listening() {
  local port="$1"
  ss -lnt 2>/dev/null | awk -v p=":${port}" 'NR>1 { if (index($4, p) > 0) { found=1 } } END { exit(found ? 0 : 1) }'
}

if [[ -z "${ADB_BIN}" ]]; then
  log "adb not found; skipping (no devices will be forwarded)"
  exit 0
fi

if ! command -v "${BIN_DIR}/multi_phone.sh" >/dev/null 2>&1; then
  log "multi_phone.sh not found at ${BIN_DIR}; aborting"
  exit 1
fi

TMP_CONF="$(mktemp)"
TMP_SITE="$(mktemp)"
trap 'rm -f "${TMP_CONF}" "${TMP_SITE}"' EXIT

log "Enumerating phones via adb and writing ${APPLY_PATH}"
before_hash=""
if [[ -f "${RUNTIME_SOURCE_FILE}" ]]; then
  before_hash="$(sha256sum "${RUNTIME_SOURCE_FILE}" | awk '{print $1}')"
fi

if ! "${BIN_DIR}/multi_phone.sh" \
  --base-port "${BASE_PORT}" \
  --prefix "${PREFIX}" \
  --gps-port "${GPS_PORT}" \
  --transport "${TRANSPORT_MODE}" \
  $( [[ "${KEEP_EMPTY_SOURCES}" == "1" ]] && echo --keep-empty ) \
  $( [[ "${FORWARD_GPS}" == "0" ]] && echo --no-gps ) \
  --out "${TMP_CONF}"; then
  log "multi_phone.sh did not complete; leaving existing config untouched"
  exit 0
fi

source_count=0
if [[ -f "${TMP_CONF}" ]]; then
  source_count="$(grep -c '^source=' "${TMP_CONF}" 2>/dev/null || true)"
  source_count="${source_count:-0}"
fi

if [[ ! -f "${KISMET_SITE_CONF}" ]]; then
  log "Creating ${KISMET_SITE_CONF}"
  install -d "$(dirname "${KISMET_SITE_CONF}")"
  touch "${KISMET_SITE_CONF}"
fi

before_site_hash="$(sha256sum "${KISMET_SITE_CONF}" 2>/dev/null | awk '{print $1}')"

# Keep startup datasource drop-in file as a marker only; source lines are
# injected into running Kismet via API after plugin registration.
install -d "$(dirname "${APPLY_PATH}")"
cat > "${APPLY_PATH}" <<'EOF'
# Managed by cell_autoconfig.sh
# Runtime cell streams are bridged by kismet-cell-bridge.service from
# /var/lib/kismet/cell/sources.generated.
# This include intentionally stays marker-only.
EOF
chown root:kismet "${APPLY_PATH}" 2>/dev/null || true
chmod 644 "${APPLY_PATH}" 2>/dev/null || true

install -d "$(dirname "${RUNTIME_SOURCE_FILE}")"
cp "${TMP_CONF}" "${RUNTIME_SOURCE_FILE}"
chown root:kismet "${RUNTIME_SOURCE_FILE}" 2>/dev/null || true
chmod 640 "${RUNTIME_SOURCE_FILE}" 2>/dev/null || true

# Newer Kismet builds treat gps=enabled/gps=false as invalid gps types.
gps_live=0
if [[ "${FORWARD_GPS}" == "1" && "${source_count}" -gt 0 ]] && port_listening "${GPS_PORT}"; then
  gps_live=1
fi

# Rewrite the site config through a text-only temp file. Some older failed
# install attempts left NUL bytes in this file, which prevents anchored sed
# matches from removing stale gps= lines and can leave Kismet without a live
# server GPS source after boot.
LC_ALL=C tr -d '\000' < "${KISMET_SITE_CONF}" |
  sed \
    -e '/^source=cell:/d' \
    -e '/^source=cellstream:/d' \
    -e '/^source=.*type=cell/d' \
    -e '\|^plugin=/usr/lib/kismet/cell/manifest\.conf$|d' \
    -e '\|^opt_include=/etc/kismet/datasources.d/\*\.conf$|d' \
    -e '/^gps=enabled$/d' \
    -e '/^gps=false$/d' \
    -e '/^gps=tcp:/d' \
  > "${TMP_SITE}"

printf 'opt_include=/etc/kismet/datasources.d/*.conf\n' >> "${TMP_SITE}"
if [[ "${gps_live}" == "1" ]]; then
  printf 'gps=tcp:host=127.0.0.1,port=%s\n' "${GPS_PORT}" >> "${TMP_SITE}"
elif [[ "${FORWARD_GPS}" == "1" ]]; then
  log "GPS forward not live (no active phone/GPS socket); leaving GPS disabled until phone stream is present"
fi

cat "${TMP_SITE}" > "${KISMET_SITE_CONF}"
chown root:kismet "${KISMET_SITE_CONF}" 2>/dev/null || true
chmod 640 "${KISMET_SITE_CONF}" 2>/dev/null || true
after_site_hash="$(sha256sum "${KISMET_SITE_CONF}" 2>/dev/null | awk '{print $1}')"

after_hash=""
if [[ -f "${RUNTIME_SOURCE_FILE}" ]]; then
  after_hash="$(sha256sum "${RUNTIME_SOURCE_FILE}" | awk '{print $1}')"
fi

if command -v systemctl >/dev/null 2>&1; then
  # Ensure bridge supervisor is running; it will reconcile helper processes
  # against ${RUNTIME_SOURCE_FILE} and keep cell streams connected.
  systemctl --no-block start kismet-cell-bridge.service || true
  if [[ "${before_site_hash}" != "${after_site_hash}" ]]; then
    log "Kismet site config changed; restarting kismet so GPS settings are loaded"
    systemctl --no-block try-restart kismet.service || true
  fi
elif command -v "${BIN_DIR}/cell_remote_bridge.py" >/dev/null 2>&1; then
  nohup "${BIN_DIR}/cell_remote_bridge.py" >/dev/null 2>&1 < /dev/null &
fi

if [[ "${before_hash}" != "${after_hash}" ]]; then
  log "Runtime datasource set changed (${source_count} source(s)); no Kismet restart required"
else
  log "Runtime datasource set unchanged (${source_count} source(s))"
fi

log "Done"
