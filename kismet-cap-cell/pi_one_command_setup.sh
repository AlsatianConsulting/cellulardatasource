#!/usr/bin/env bash
# One-command setup for Raspberry Pi Kismet capture with optional cellular datasource.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

WIFI_IF="${WIFI_IF:-wlx00c0cab5bd7a}"
ENABLE_CELL_STACK="${ENABLE_CELL_STACK:-1}"
CELL_FORWARD_GPS="${CELL_FORWARD_GPS:-1}"
CELL_TRANSPORT_MODE="${CELL_TRANSPORT_MODE:-usb}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[pi-setup] %s\n' "$*"; }

append_line_if_missing() {
  local file="$1"
  local line="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
  fi
}

replace_or_append_source() {
  local file="$1"
  local name="$2"
  local line="$3"
  touch "${file}"
  sed -i -E "/^source=.*name=${name}(,|$)/d" "${file}"
  append_line_if_missing "${file}" "${line}"
}

remove_source_by_name() {
  local file="$1"
  local name="$2"
  touch "${file}"
  sed -i -E "/^source=.*name=${name}(,|$)/d" "${file}"
}

interface_exists() { ip link show "$1" >/dev/null 2>&1; }

interface_monitor_capable() {
  local iface="$1"
  local phy
  phy="$(/usr/sbin/iw dev "${iface}" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "${phy}" ]] || return 1
  /usr/sbin/iw phy "${phy}" info 2>/dev/null | grep -qE '^[[:space:]]*\* monitor$'
}

detect_monitor_interface() {
  local iface
  while read -r iface; do
    [[ -n "${iface}" ]] || continue
    if interface_monitor_capable "${iface}"; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done < <(/usr/sbin/iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
  return 1
}

log "Installing Kismet and Wi-Fi helpers"
apt-get update -y
apt-get install -y ca-certificates curl gpg lsb-release iw adb bluez jq netcat-openbsd usbutils

CODENAME="$(lsb_release -cs)"
if [[ "${CODENAME}" == "trixie" ]]; then
  cat >/etc/apt/sources.list.d/kismet.list <<SRC
deb [trusted=yes] https://www.kismetwireless.net/repos/apt/release/${CODENAME} ${CODENAME} main
SRC
else
  install -d /usr/share/keyrings
  curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/kismet-archive-keyring.gpg
  cat >/etc/apt/sources.list.d/kismet.list <<SRC
deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/${CODENAME} ${CODENAME} main
SRC
fi

apt-get update -y
apt-get install -y kismet kismet-core kismet-logtools kismet-capture-linux-wifi

touch /etc/kismet/kismet_site.conf
sed -i -E '/^source=cell:/d;/^source=cellstream:/d' /etc/kismet/kismet_site.conf || true

WIFI_SOURCE_IF=""
if interface_exists "${WIFI_IF}" && interface_monitor_capable "${WIFI_IF}"; then
  WIFI_SOURCE_IF="${WIFI_IF}"
else
  WIFI_SOURCE_IF="$(detect_monitor_interface || true)"
fi

if [[ -n "${WIFI_SOURCE_IF}" ]]; then
  replace_or_append_source /etc/kismet/kismet_site.conf "wifi-usb" "source=${WIFI_SOURCE_IF}:name=wifi-usb"
else
  remove_source_by_name /etc/kismet/kismet_site.conf "wifi-usb"
fi
append_line_if_missing /etc/kismet/kismet_site.conf "opt_include=/etc/kismet/datasources.d/*.conf"
chown root:kismet /etc/kismet/kismet_site.conf
chmod 640 /etc/kismet/kismet_site.conf

if [[ "${ENABLE_CELL_STACK}" == "1" ]]; then
  log "Installing cellular datasource stack"
  INSTALL_KISMET=0 INSTALL_SERVICES=1 "${SCRIPT_DIR}/install.sh"
  "${SCRIPT_DIR}/one_shot_install.sh" \
    --install-kismet 0 \
    --install-services 1 \
    --enable-cell-datasource 1 \
    --transport "${CELL_TRANSPORT_MODE}" \
    --forward-gps "${CELL_FORWARD_GPS}" \
    --restart-kismet 1
else
  systemctl disable --now kismet-cell-autosetup.timer kismet-cell-autosetup.service kismet-cell-bridge.service 2>/dev/null || true
fi

systemctl reset-failed kismet || true
systemctl enable --now kismet
sleep 2

log "Datasource launch summary"
journalctl -u kismet -n 200 --no-pager | egrep -i "Probing interface|launched successfully|Unable to find driver|No data sources defined|FATAL|SEGV|error" || true

log "Done"
