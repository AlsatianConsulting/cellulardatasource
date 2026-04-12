#!/usr/bin/env bash
# Uninstall cellular datasource components.
set -euo pipefail

PREFIX="${PREFIX:-/usr}"
KEEP_CONFIG=0
REMOVE_KISMET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-config) KEEP_CONFIG=1 ;;
    --remove-kismet) REMOVE_KISMET=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

BIN_DIR="${PREFIX}/bin"
PLUGIN_DIR="${PREFIX}/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"
CONFIG_DS_DIR="/etc/kismet/datasources.d"

log() { printf '[uninstall] %s\n' "$*"; }

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now \
    kismet-cell-autosetup.timer \
    kismet-cell-autosetup.service \
    kismet-cell-bridge.service \
    kismet-cell-injector.service \
    kismet 2>/dev/null || true
fi

rm -f \
  /etc/systemd/system/kismet-cell-autosetup.service \
  /etc/systemd/system/kismet-cell-autosetup.timer \
  /etc/systemd/system/kismet-cell-bridge.service \
  /etc/systemd/system/kismet-cell-injector.service \
  /etc/systemd/system/kismet.service.d/cell-override.conf \
  /etc/systemd/system/kismet.service.d/cell-autosetup-order.conf \
  /etc/systemd/system/kismet.service.d/cell-killmode.conf \
  /etc/systemd/system/kismet.service.d/cell-rfkill-unblock.conf

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

for f in \
  "${BIN_DIR}/kismet_cap_cell_capture" \
  "${BIN_DIR}/kismet_cap_cell" \
  "${BIN_DIR}/kismet_cap_cellstream" \
  "${BIN_DIR}/multi_phone.sh" \
  "${BIN_DIR}/cell_autoconfig.sh" \
  "${BIN_DIR}/kismet_cell_injector.sh" \
  "${BIN_DIR}/cell_remote_bridge.py" \
  "${BIN_DIR}/cell_transport_toggle.sh" \
  "${BIN_DIR}/cell-transport-mode" \
  "${BIN_DIR}/collector.py" \
  "${BIN_DIR}/uds_forwarder.py"; do
  [[ -f "${f}" ]] && rm -f "${f}"
done

rm -f "${PLUGIN_DIR}/cell.so" "${PLUGIN_DIR}/manifest.conf" "${JS_DIR}/kismet.ui.cell.js"
rmdir "${JS_DIR}" 2>/dev/null || true
rmdir "${PLUGIN_DIR}/httpd/js" 2>/dev/null || true
rmdir "${PLUGIN_DIR}/httpd" 2>/dev/null || true
rmdir "${PLUGIN_DIR}" 2>/dev/null || true

if [[ ${KEEP_CONFIG} -eq 0 ]]; then
  rm -f "${CONFIG_DS_DIR}/cell.conf"
  rm -f /var/lib/kismet/cell/sources.generated /var/lib/kismet/cell/portmap.tsv
  rm -rf /var/log/kismet/cell-bridge
fi

if [[ ${REMOVE_KISMET} -eq 1 && $(command -v apt-get >/dev/null 2>&1; echo $?) -eq 0 ]]; then
  apt-get remove -y kismet kismet-core kismet-logtools || true
  apt-get autoremove -y || true
fi

log "Uninstall complete."
