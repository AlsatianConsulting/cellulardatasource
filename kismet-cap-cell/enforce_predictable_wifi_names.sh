#!/usr/bin/env bash
# Enforce persistent wlx<mac> interface names and rewrite Kismet wifi sources.
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "Run as root"; exit 1; }

RULES_FILE="${RULES_FILE:-/etc/udev/rules.d/76-persistent-wlan-wlx.rules}"
KISMET_DS_DIR="${KISMET_DS_DIR:-/etc/kismet/datasources.d}"
KISMET_SITE_CONF="${KISMET_SITE_CONF:-/etc/kismet/kismet_site.conf}"

log() { printf '[wifi-name-fix] %s\n' "$*"; }

tmp_rules="$(mktemp)"
tmp_map="$(mktemp)"

{
  echo "# Managed by enforce_predictable_wifi_names.sh"
  echo "# Generated $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
} > "${tmp_rules}"

for iface_path in /sys/class/net/*; do
  iface="$(basename "${iface_path}")"
  [[ -d "${iface_path}/wireless" ]] || continue
  [[ "${iface}" =~ ^(wlan|wlx)[a-zA-Z0-9._-]*$ ]] || continue
  [[ "${iface}" =~ mon$ ]] && continue
  [[ "${iface}" =~ ^kismon ]] && continue
  # Skip monitor/radiotap virtual interfaces; keep only normal netdev type 1.
  [[ -r "${iface_path}/type" ]] || continue
  [[ "$(cat "${iface_path}/type" 2>/dev/null || true)" == "1" ]] || continue
  [[ -r "${iface_path}/address" ]] || continue

  mac="$(tr '[:upper:]' '[:lower:]' < "${iface_path}/address")"
  mac_nocolon="${mac//:/}"
  new_name="wlx${mac_nocolon}"
  # Keep one canonical mapping per MAC.
  if grep -qE "^[^[:space:]]+[[:space:]]+${new_name}$" "${tmp_map}" 2>/dev/null; then
    continue
  fi
  printf '%s %s\n' "${iface}" "${new_name}" >> "${tmp_map}"
  echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${new_name}\"" >> "${tmp_rules}"
done

install -d "$(dirname "${RULES_FILE}")"
install -m 644 "${tmp_rules}" "${RULES_FILE}"
rm -f "${tmp_rules}"

log "Installed udev rules at ${RULES_FILE}"

rewrite_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local changed=0
  while read -r old new; do
    [[ -n "${old}" && -n "${new}" ]] || continue
    [[ "${old}" == "${new}" ]] && continue
    if grep -qE "source=${old}:" "${file}"; then
      sed -i -E "s#source=${old}:#source=${new}:#g" "${file}"
      changed=1
    fi
  done < "${tmp_map}"
  if [[ "${changed}" -eq 1 ]]; then
    log "Rewrote wifi source interfaces in ${file}"
  fi
}

rewrite_file "${KISMET_SITE_CONF}"
if [[ -d "${KISMET_DS_DIR}" ]]; then
  for f in "${KISMET_DS_DIR}"/*.conf; do
    [[ -e "${f}" ]] || continue
    rewrite_file "${f}"
  done
fi

log "Interface mapping:"
cat "${tmp_map}" || true
rm -f "${tmp_map}"

log "Done. Reboot is recommended to apply renamed interfaces consistently."
