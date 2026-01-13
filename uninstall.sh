#!/usr/bin/env bash
# Uninstall the cell datasource helper, plugin, autoconfig services, and Kismet install.
# Usage: ./uninstall.sh [--keep-config]
# Removes everything installed by install.sh (binaries, plugins, configs, services, Kismet build).

set -euo pipefail

KEEP_CONFIG=0
if [[ $# -gt 0 && "$1" == "--keep-config" ]]; then
  KEEP_CONFIG=1
fi

BIN_DIR="/usr/bin"
PLUGIN_DIR="/usr/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"
CONFIG_DIR="/etc/kismet"
CONFIG_DS_DIR="${CONFIG_DIR}/datasources.d"
SERVICE_PATH="/etc/systemd/system/kismet-cell-autosetup.service"
TIMER_PATH="/etc/systemd/system/kismet-cell-autosetup.timer"
KISMET_SERVICE="/etc/systemd/system/kismet.service"
KISMET_BIN="/usr/bin/kismet"
KISMET_DIR="/usr/lib/kismet"
KISMET_SHARE_DIR="/usr/share/kismet"
KISMET_SRC_ROOT="/usr/local/src"

log() { printf '[uninstall] %s\n' "$*"; }

log "Uninstalling cell datasource and Kismet"

# Stop/disable services
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files | grep -q '^kismet-cell-autosetup.timer'; then
    log "Stopping/disabling kismet-cell-autosetup.timer"
    systemctl stop kismet-cell-autosetup.timer || true
    systemctl disable kismet-cell-autosetup.timer || true
  fi
  if systemctl list-unit-files | grep -q '^kismet-cell-autosetup.service'; then
    log "Stopping/disabling kismet-cell-autosetup.service"
    systemctl stop kismet-cell-autosetup.service || true
    systemctl disable kismet-cell-autosetup.service || true
  fi
  if systemctl list-unit-files | grep -q '^kismet.service'; then
    log "Stopping/disabling kismet.service"
    systemctl stop kismet || true
    systemctl disable kismet || true
  fi
  if systemctl list-unit-files | grep -q '^kismet.service'; then
    log "Unmasking kismet.service"
    systemctl unmask kismet || true
  fi
fi

# Remove service files
for unit in "${SERVICE_PATH}" "${TIMER_PATH}"; do
  if [[ -f "${unit}" ]]; then
    log "Removing ${unit}"
    rm -f "${unit}"
  fi
done
if [[ -f "${KISMET_SERVICE}" ]]; then
  log "Removing ${KISMET_SERVICE}"
  rm -f "${KISMET_SERVICE}"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

# Remove binaries/scripts
for f in "${BIN_DIR}/kismet_cap_cell_capture" \
         "${BIN_DIR}/multi_phone.sh" \
         "${BIN_DIR}/cell_autoconfig.sh"; do
  if [[ -f "${f}" ]]; then
    log "Removing ${f}"
    rm -f "${f}"
  fi
done

# Remove plugin files
if [[ -d "${PLUGIN_DIR}" ]]; then
  for f in "${PLUGIN_DIR}/cell.so" "${PLUGIN_DIR}/manifest.conf"; do
    [[ -f "${f}" ]] && { log "Removing ${f}"; rm -f "${f}"; }
  done
  if [[ -d "${JS_DIR}" ]]; then
    for js in "${JS_DIR}/kismet.ui.cell.js"; do
      [[ -f "${js}" ]] && { log "Removing ${js}"; rm -f "${js}"; }
    done
  fi
  rmdir "${JS_DIR}" 2>/dev/null || true
  rmdir "${PLUGIN_DIR}" 2>/dev/null || true
fi

# Remove Kismet binaries and data (best effort, source install)
for f in "${KISMET_BIN}" "/usr/bin/kismet_cap_pcaplog" "/usr/bin/kismet_cap_interface" "/usr/bin/kismet_cap_nrf_mousejack"; do
  [[ -f "${f}" ]] && { log "Removing ${f}"; rm -f "${f}"; }
done
for d in "${KISMET_DIR}" "${KISMET_SHARE_DIR}" "${CONFIG_DIR}"; do
  if [[ -d "${d}" ]]; then
    log "Removing ${d}"
    rm -rf "${d}"
  fi
done
# Remove source trees
if [[ -d "${KISMET_SRC_ROOT}" ]]; then
  find "${KISMET_SRC_ROOT}" -maxdepth 1 -type d -name "kismet*" -print0 | while IFS= read -r -d '' d; do
    log "Removing source tree ${d}"
    rm -rf "${d}"
  done
fi

# Remove datasource config
if [[ ${KEEP_CONFIG} -eq 0 ]]; then
  CELL_CONF="${CONFIG_DS_DIR}/cell.conf"
  if [[ -f "${CELL_CONF}" ]]; then
    log "Removing ${CELL_CONF}"
    rm -f "${CELL_CONF}"
  fi
fi

# Remove kismet user/group (best effort)
if getent passwd kismet >/dev/null 2>&1; then
  log "Removing kismet user"
  userdel -r kismet || true
fi
if getent group kismet >/dev/null 2>&1; then
  log "Removing kismet group"
  groupdel kismet || true
fi

log "Uninstall complete."
