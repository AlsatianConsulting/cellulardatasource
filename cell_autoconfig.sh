#!/usr/bin/env bash
# Auto-configure and refresh Kismet cell datasource entries and GPS forwarding.
# Intended to be run via systemd (oneshot) to keep config up to date on boot.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BASE_PORT="${BASE_PORT:-9875}"
GPS_PORT="${GPS_PORT:-8766}"
FORWARD_GPS="${FORWARD_GPS:-1}"
BIN_DIR="${PREFIX}/bin"
APPLY_PATH="${APPLY_PATH:-/etc/kismet/datasources.d/cell.conf}"
KISMET_SITE_CONF="${KISMET_SITE_CONF:-/etc/kismet/kismet_site.conf}"
ADB_BIN="$(command -v adb || true)"

log() { printf '[cell-autoconfig] %s\n' "$*"; }

if [[ -z "${ADB_BIN}" ]]; then
  log "adb not found; skipping (no devices will be forwarded)"
  exit 0
fi

if ! command -v "${BIN_DIR}/multi_phone.sh" >/dev/null 2>&1; then
  log "multi_phone.sh not found at ${BIN_DIR}; aborting"
  exit 1
fi

TMP_CONF="$(mktemp)"
trap 'rm -f "${TMP_CONF}"' EXIT

log "Enumerating phones via adb and writing ${APPLY_PATH}"
if ! "${BIN_DIR}/multi_phone.sh" --base-port "${BASE_PORT}" --prefix "${PREFIX}" --gps-port "${GPS_PORT}" $( [[ "${FORWARD_GPS}" == "0" ]] && echo --no-gps ) --out "${TMP_CONF}" --apply-path "${APPLY_PATH}"; then
  log "multi_phone.sh did not complete; leaving existing config untouched"
  exit 1
fi

if [[ ! -f "${KISMET_SITE_CONF}" ]]; then
  log "Creating ${KISMET_SITE_CONF}"
  install -d "$(dirname "${KISMET_SITE_CONF}")"
  touch "${KISMET_SITE_CONF}"
fi
if ! grep -q '^gps=enabled' "${KISMET_SITE_CONF}"; then
  echo "gps=enabled" >> "${KISMET_SITE_CONF}"
fi
if ! grep -q "^gps=tcp:127.0.0.1:${GPS_PORT}$" "${KISMET_SITE_CONF}"; then
  # remove any existing gps=tcp line first
  sed -i '/^gps=tcp:127.0.0.1:/d' "${KISMET_SITE_CONF}"
  echo "gps=tcp:127.0.0.1:${GPS_PORT}" >> "${KISMET_SITE_CONF}"
fi

log "Restarting kismet to pick up datasource and GPS"
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart kismet || true
fi

log "Done"
