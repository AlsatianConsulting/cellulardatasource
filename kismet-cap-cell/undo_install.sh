#!/usr/bin/env bash
# Undo installer-managed changes for the cellular datasource setup.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 ..." >&2; exit 1; }

PREFIX="${PREFIX:-/usr}"
REMOVE_KISMET=0
PURGE_KISMET_REPO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-kismet) REMOVE_KISMET=1 ;;
    --purge-kismet-repo) PURGE_KISMET_REPO=1 ;;
    --help|-h)
      cat <<USAGE
Usage: sudo ./undo_install.sh [options]
  --remove-kismet
  --purge-kismet-repo
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

BIN_DIR="${PREFIX}/bin"
PLUGIN_DIR="${PREFIX}/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"

log() { printf '[undo] %s\n' "$*"; }

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now \
    kismet-cell-autosetup.timer \
    kismet-cell-autosetup.service \
    kismet-cell-bridge.service \
    kismet-cell-injector.service 2>/dev/null || true
fi

rm -f \
  /etc/systemd/system/kismet-cell-autosetup.service \
  /etc/systemd/system/kismet-cell-autosetup.timer \
  /etc/systemd/system/kismet-cell-bridge.service \
  /etc/systemd/system/kismet-cell-injector.service
rm -rf /etc/systemd/system/kismet-cell-autosetup.service.d
rm -f \
  /etc/systemd/system/kismet.service.d/cell-override.conf \
  /etc/systemd/system/kismet.service.d/cell-autosetup-order.conf \
  /etc/systemd/system/kismet.service.d/cell-killmode.conf \
  /etc/systemd/system/kismet.service.d/cell-rfkill-unblock.conf

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

rm -f \
  "${BIN_DIR}/kismet_cap_cell_capture" \
  "${BIN_DIR}/kismet_cap_cell" \
  "${BIN_DIR}/kismet_cap_cellstream" \
  "${BIN_DIR}/multi_phone.sh" \
  "${BIN_DIR}/cell_autoconfig.sh" \
  "${BIN_DIR}/kismet_cell_injector.sh" \
  "${BIN_DIR}/cell_remote_bridge.py" \
  "${BIN_DIR}/uds_forwarder.py" \
  "${BIN_DIR}/cell_transport_toggle.sh" \
  "${BIN_DIR}/cell-transport-mode" \
  "${BIN_DIR}/collector.py"

rm -f "${PLUGIN_DIR}/cell.so" "${PLUGIN_DIR}/manifest.conf" "${JS_DIR}/kismet.ui.cell.js"
rmdir "${JS_DIR}" 2>/dev/null || true
rmdir "${PLUGIN_DIR}/httpd/js" 2>/dev/null || true
rmdir "${PLUGIN_DIR}/httpd" 2>/dev/null || true
rmdir "${PLUGIN_DIR}" 2>/dev/null || true

rm -f /etc/kismet/datasources.d/cell.conf
rm -f /var/lib/kismet/cell/sources.generated /var/lib/kismet/cell/portmap.tsv
rm -rf /var/log/kismet/cell-bridge

if [[ "${REMOVE_KISMET}" == "1" ]]; then
  systemctl disable --now kismet 2>/dev/null || true
  if command -v apt-get >/dev/null 2>&1; then
    apt-get remove -y kismet kismet-core kismet-logtools || true
    apt-get autoremove -y || true
  fi
fi

if [[ "${PURGE_KISMET_REPO}" == "1" ]]; then
  KIS_REPO_FILE="/etc/apt/sources.list.d/kismet.list"
  if [[ -f "${KIS_REPO_FILE}" ]]; then
    tmp="$(mktemp)"
    awk '!/kismetwireless\.net\/repos\/apt\/release\//' "${KIS_REPO_FILE}" > "${tmp}"
    mv "${tmp}" "${KIS_REPO_FILE}"
    if ! grep -q '[^[:space:]]' "${KIS_REPO_FILE}"; then
      rm -f "${KIS_REPO_FILE}"
    fi
  fi
  command -v apt-get >/dev/null 2>&1 && apt-get update || true
fi

log "Undo complete."
