#!/usr/bin/env bash
# Standalone installer for a single device.
# Provides optional cellular datasource enablement.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 ..." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-/usr}"
MAKE_JOBS="${MAKE_JOBS:-1}"
WITH_COLLECTOR="${WITH_COLLECTOR:-0}"
INSTALL_KISMET="${INSTALL_KISMET:-ask}"         # ask|0|1
INSTALL_SERVICES="${INSTALL_SERVICES:-ask}"     # ask|0|1
ENABLE_CELL_DATASOURCE="${ENABLE_CELL_DATASOURCE:-ask}" # ask|0|1
OVERWRITE_CONFIG="${OVERWRITE_CONFIG:-ask}"     # ask|0|1
BASE_PORT="${BASE_PORT:-9875}"
GPS_PORT="${GPS_PORT:-8766}"
FORWARD_GPS="${FORWARD_GPS:-1}"
TRANSPORT_MODE="${TRANSPORT_MODE:-usb}"
RESTART_KISMET="${RESTART_KISMET:-1}"

log() { printf '[one-shot] %s\n' "$*"; }
die() { printf '[one-shot] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo ./one_shot_install.sh [options]

Options:
  --install-kismet 0|1
  --install-services 0|1
  --enable-cell-datasource 0|1
  --overwrite-config 0|1
  --prefix PATH
  --make-jobs N
  --with-collector 0|1
  --base-port PORT
  --gps-port PORT
  --forward-gps 0|1
  --transport usb
  --restart-kismet 0|1
  --help
USAGE
}

ask_toggle() {
  local var_name="$1"
  local question="$2"
  local value="${!var_name}"
  case "${value}" in
    0|1) return 0 ;;
    ask)
      if [[ -t 0 ]]; then
        local ans=""
        read -r -p "${question} [y/N]: " ans
        case "${ans}" in
          y|Y|yes|YES) printf -v "${var_name}" '%s' "1" ;;
          *) printf -v "${var_name}" '%s' "0" ;;
        esac
      else
        printf -v "${var_name}" '%s' "0"
      fi
      ;;
    *) die "${var_name} must be ask, 0, or 1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-kismet) INSTALL_KISMET="$2"; shift 2 ;;
    --install-services) INSTALL_SERVICES="$2"; shift 2 ;;
    --enable-cell-datasource) ENABLE_CELL_DATASOURCE="$2"; shift 2 ;;
    --overwrite-config) OVERWRITE_CONFIG="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --make-jobs) MAKE_JOBS="$2"; shift 2 ;;
    --with-collector) WITH_COLLECTOR="$2"; shift 2 ;;
    --base-port) BASE_PORT="$2"; shift 2 ;;
    --gps-port) GPS_PORT="$2"; shift 2 ;;
    --forward-gps) FORWARD_GPS="$2"; shift 2 ;;
    --transport) TRANSPORT_MODE="$2"; shift 2 ;;
    --restart-kismet) RESTART_KISMET="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "${TRANSPORT_MODE}" == "usb" ]] || die "Only usb transport is supported"
[[ "${FORWARD_GPS}" =~ ^[01]$ ]] || die "--forward-gps must be 0 or 1"
[[ "${RESTART_KISMET}" =~ ^[01]$ ]] || die "--restart-kismet must be 0 or 1"

ask_toggle INSTALL_KISMET "Install Kismet"
ask_toggle INSTALL_SERVICES "Install and enable services"
ask_toggle ENABLE_CELL_DATASOURCE "Add cellular datasource"
ask_toggle OVERWRITE_CONFIG "Overwrite Kismet datasource config files"

log "Running base install"
PREFIX="${PREFIX}" \
MAKE_JOBS="${MAKE_JOBS}" \
WITH_COLLECTOR="${WITH_COLLECTOR}" \
INSTALL_KISMET="${INSTALL_KISMET}" \
INSTALL_SERVICES="${INSTALL_SERVICES}" \
"${SCRIPT_DIR}/install.sh"

SITE_CONF="/etc/kismet/kismet_site.conf"
CELL_CONF="/etc/kismet/datasources.d/cell.conf"
if [[ "${OVERWRITE_CONFIG}" == "1" ]]; then
  log "Writing fresh config fragments"
  install -d /etc/kismet /etc/kismet/datasources.d
  cat > "${SITE_CONF}" <<'CFG'
plugin=/usr/lib/kismet/cell/manifest.conf
opt_include=/etc/kismet/datasources.d/*.conf
CFG
  cat > "${CELL_CONF}" <<'CFG'
# Managed by cell_autoconfig.sh
# Runtime cell sources are bridged by kismet-cell-bridge.service.
CFG
  chown root:kismet "${SITE_CONF}" "${CELL_CONF}" 2>/dev/null || true
  chmod 640 "${SITE_CONF}" 2>/dev/null || true
  chmod 644 "${CELL_CONF}" 2>/dev/null || true
fi

if [[ "${ENABLE_CELL_DATASOURCE}" == "1" ]]; then
  log "Enabling cellular datasource"
  install -d /etc/systemd/system/kismet-cell-autosetup.service.d
  cat > /etc/systemd/system/kismet-cell-autosetup.service.d/override.conf <<EOF2
[Service]
Environment=PREFIX=${PREFIX}
Environment=BASE_PORT=${BASE_PORT}
Environment=GPS_PORT=${GPS_PORT}
Environment=FORWARD_GPS=${FORWARD_GPS}
Environment=TRANSPORT_MODE=${TRANSPORT_MODE}
Type=oneshot
ExitType=main
RemainAfterExit=no
KillMode=process
EOF2

  systemctl daemon-reload
  if [[ "${INSTALL_SERVICES}" == "1" ]]; then
    systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer kismet-cell-bridge.service
  fi

  /usr/bin/cell_autoconfig.sh || true
else
  log "Cellular datasource not enabled by user selection"
  systemctl disable --now kismet-cell-autosetup.timer kismet-cell-autosetup.service kismet-cell-bridge.service 2>/dev/null || true
fi

if [[ "${RESTART_KISMET}" == "1" && "${INSTALL_KISMET}" == "1" ]]; then
  log "Restarting kismet"
  systemctl restart kismet || true
fi

if [[ "${ENABLE_CELL_DATASOURCE}" != "1" ]]; then
  cat <<'NOTE'

Manual enable later:
  sudo systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer kismet-cell-bridge.service
  sudo /usr/bin/cell_autoconfig.sh
  sudo systemctl restart kismet

NOTE
fi

log "Complete"
