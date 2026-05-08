#!/usr/bin/env bash
# Enforce USB transport mode.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

RESTART_KISMET="${RESTART_KISMET:-1}"
AUTOSVC_DROPIN="/etc/systemd/system/kismet-cell-autosetup.service.d"
AUTOSVC_OVERRIDE="${AUTOSVC_DROPIN}/override.conf"

log() { printf '[cell-transport] %s\n' "$*"; }

set_service_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  if [[ ! -f "${file}" ]]; then
    printf '[Service]\n' > "${file}"
  fi

  awk -v key="${key}" -v value="${value}" '
    BEGIN { updated=0; in_service=0; service_seen=0; inserted=0; }
    /^\[Service\]$/ {
      if (in_service && !updated) {
        printf "Environment=%s=%s\n", key, value;
        updated=1;
      }
      in_service=1; service_seen=1;
      print;
      next;
    }
    /^\[/ {
      if (in_service && !updated) {
        printf "Environment=%s=%s\n", key, value;
        updated=1;
      }
      in_service=0;
      print;
      next;
    }
    {
      if (in_service && $0 ~ "^Environment=" key "=") {
        if (!inserted) {
          printf "Environment=%s=%s\n", key, value;
          inserted=1;
        }
        updated=1;
        next;
      }
      print;
    }
    END {
      if (!service_seen) {
        print "[Service]";
      }
      if (!updated) {
        printf "Environment=%s=%s\n", key, value;
      }
    }
  ' "${file}" > "${tmp}"

  mv "${tmp}" "${file}"
}

install -d "${AUTOSVC_DROPIN}"
set_service_env "${AUTOSVC_OVERRIDE}" "TRANSPORT_MODE" "usb"
log "Set TRANSPORT_MODE=usb in ${AUTOSVC_OVERRIDE}"

systemctl daemon-reload
systemctl restart kismet-cell-autosetup.service

if [[ "${RESTART_KISMET}" == "1" ]]; then
  systemctl restart kismet || true
fi

echo "----- active mode -----"
systemctl show -p Environment kismet-cell-autosetup.service | sed 's/^Environment=//'
echo "----- datasource -----"
cat /etc/kismet/datasources.d/cell.conf || true
echo "-----------------------"
