#!/usr/bin/env bash
# Auto-forward attached Android phones over USB and generate Kismet source lines.
# Usage:
#   ./multi_phone.sh [--base-port 9875] [--prefix /usr/local] [--gps-port 8766] [--no-gps] [--out cell_sources.conf] [--apply-path /etc/kismet/datasources.d/cell.conf]

set -euo pipefail

BASE_PORT=9875
PREFIX="/usr"
OUT="cell_sources.conf"
APPLY_PATH=""
GPS_PORT=8766
FORWARD_GPS=1
KEEP_EMPTY=0
KEEP_STALE_SOURCES="${KEEP_STALE_SOURCES:-1}"
PORTMAP_PATH="${PORTMAP_PATH:-/var/lib/kismet/cell/portmap.tsv}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-port)
      BASE_PORT="$2"; shift 2 ;;
    --prefix)
      PREFIX="$2"; shift 2 ;;
    --gps-port)
      GPS_PORT="$2"; shift 2 ;;
    --no-gps)
      FORWARD_GPS=0; shift 1 ;;
    --keep-empty)
      KEEP_EMPTY=1; shift 1 ;;
    --transport)
      if [[ "$2" != "usb" ]]; then
        echo "Invalid --transport '$2' (only usb is supported)" >&2
        exit 1
      fi
      shift 2 ;;
    --out)
      OUT="$2"; shift 2 ;;
    --apply-path)
      APPLY_PATH="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1 ;;
  esac
done

ADB_BIN="$(command -v adb || true)"
if [[ -z "${ADB_BIN}" ]]; then
  echo "adb not found; please install Android platform tools" >&2
  exit 1
fi

bool_from_env() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) echo 1 ;;
    *) echo 0 ;;
  esac
}

KEEP_STALE_SOURCES="$(bool_from_env "${KEEP_STALE_SOURCES}")"

declare -A PORTMAP=()
declare -A USED_PORTS=()

load_portmap() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  while IFS=$'\t' read -r serial port; do
    [[ -n "${serial}" && -n "${port}" ]] || continue
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    PORTMAP["${serial}"]="${port}"
    USED_PORTS["${port}"]=1
  done < "${file}"
}

save_portmap() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  for serial in "${!PORTMAP[@]}"; do
    printf '%s\t%s\n' "${serial}" "${PORTMAP[${serial}]}" >> "${tmp}"
  done
  if [[ -s "${tmp}" ]]; then
    sort -k1,1 "${tmp}" > "${tmp}.sorted"
    mv "${tmp}.sorted" "${tmp}"
  fi
  install -d "$(dirname "${file}")"
  mv "${tmp}" "${file}"
  chmod 644 "${file}" 2>/dev/null || true
}

next_free_port() {
  local p
  p="${BASE_PORT}"
  while [[ -n "${USED_PORTS[${p}]:-}" ]]; do
    p=$((p + 1))
  done
  echo "${p}"
}

# When running as root (for systemd service), prefer known user adb keys so
# authorized phones remain usable after host reboot.
if [[ "${EUID}" -eq 0 && -z "${ADB_VENDOR_KEYS:-}" ]]; then
  key_paths=()
  if [[ -f /home/user/.android/adbkey ]]; then
    key_paths+=(/home/user/.android)
  fi
  while IFS= read -r keyfile; do
    keydir="$(dirname "${keyfile}")"
    found=0
    for existing in "${key_paths[@]:-}"; do
      [[ "${existing}" == "${keydir}" ]] && found=1 && break
    done
    if [[ "${found}" -eq 0 ]]; then
      key_paths+=("${keydir}")
    fi
  done < <(find /home -maxdepth 3 -type f -name adbkey 2>/dev/null || true)

  if [[ "${#key_paths[@]}" -gt 0 ]]; then
    joined="$(IFS=:; echo "${key_paths[*]}")"
    export ADB_VENDOR_KEYS="${joined}"
    echo "[*] Using ADB_VENDOR_KEYS=${ADB_VENDOR_KEYS}"
  fi
fi

# Keep service-side adb operations isolated from interactive user adb sessions.
# This avoids user-level adb daemons clobbering authorization/forward state for
# autosetup on boot and reconnect.
if [[ "${EUID}" -eq 0 && -z "${ADB_SERVER_SOCKET:-}" ]]; then
  export ADB_SERVER_SOCKET="localfilesystem:/run/adb-cell.sock"
  echo "[*] Using dedicated ADB server socket ${ADB_SERVER_SOCKET}"
fi

# Reclaim USB ownership from any default adb daemon (tcp:5037) so our
# dedicated service-side daemon remains authoritative across reboots/reconnects.
if [[ "${EUID}" -eq 0 && "${ADB_SERVER_SOCKET:-}" == localfilesystem:* ]]; then
  env -u ADB_SERVER_SOCKET "${ADB_BIN}" kill-server >/dev/null 2>&1 || true
fi

"${ADB_BIN}" start-server >/dev/null 2>&1 || true
mapfile -t SERIALS < <("${ADB_BIN}" devices | awk 'NR>1 && $2=="device"{print $1}')
mapfile -t ADB_WARNINGS < <("${ADB_BIN}" devices | awk 'NR>1 && $1!="" && $2!="device"{print $1 " (" $2 ")"}')

if [[ ${#SERIALS[@]} -eq 0 ]]; then
  echo "[*] No attached USB devices"
fi
if [[ ${#ADB_WARNINGS[@]} -gt 0 ]]; then
  printf '[*] Ignoring non-ready ADB devices: %s\n' "${ADB_WARNINGS[*]}"
fi

echo "[*] Transport mode: usb"
echo "[*] Using USB base port ${BASE_PORT}, prefix ${PREFIX}"
if [[ ${FORWARD_GPS} -eq 1 ]]; then
  echo "[*] GPS forwarding enabled on host port ${GPS_PORT} (device tcp:8766, first device only)"
fi

load_portmap "${PORTMAP_PATH}"

declare -A PRESENT=()
tmp_out="$(mktemp)"
trap 'rm -f "${tmp_out}"' EXIT

idx=0
for serial in "${SERIALS[@]}"; do
  PRESENT["${serial}"]=1
  port="${PORTMAP[${serial}]:-}"
  if [[ -z "${port}" || ! "${port}" =~ ^[0-9]+$ ]]; then
    port="$(next_free_port)"
    PORTMAP["${serial}"]="${port}"
    USED_PORTS["${port}"]=1
  fi
  echo "[*] ${serial} -> tcp:${port}"
  if ! "${ADB_BIN}" -s "${serial}" forward "tcp:${port}" "tcp:8765"; then
    echo "[!] Failed adb forward for ${serial} tcp:${port}->tcp:8765; skipping device" >&2
    continue
  fi
  echo "source=tcp://127.0.0.1:${port}:name=cell-${serial},type=cell" >> "${tmp_out}"
  if [[ ${FORWARD_GPS} -eq 1 && ${idx} -eq 0 ]]; then
    echo "[*] ${serial} (GPS) -> tcp:${GPS_PORT}"
    "${ADB_BIN}" -s "${serial}" forward "tcp:${GPS_PORT}" "tcp:8766" || true
  fi
  idx=$((idx + 1))
done

if [[ "${KEEP_STALE_SOURCES}" -eq 1 ]]; then
  for serial in "${!PORTMAP[@]}"; do
    if [[ -n "${PRESENT[${serial}]:-}" ]]; then
      continue
    fi
    port="${PORTMAP[${serial}]}"
    echo "[*] Keeping stale source for missing serial ${serial} on tcp:${port}"
    echo "source=tcp://127.0.0.1:${port}:name=cell-${serial},type=cell" >> "${tmp_out}"
  done
fi

mv "${tmp_out}" "${OUT}"
save_portmap "${PORTMAP_PATH}"

echo "[+] Wrote $(wc -l < "${OUT}") sources to ${OUT}"

if [[ -n "${APPLY_PATH}" ]]; then
  line_count="$(wc -l < "${OUT}")"
  if [[ "${line_count}" -eq 0 && "${KEEP_EMPTY}" -ne 1 ]]; then
    echo "[*] Source list is empty; leaving existing ${APPLY_PATH} unchanged"
    exit 0
  fi
  echo "[*] Writing sources to ${APPLY_PATH}"
  install -d "$(dirname "${APPLY_PATH}")"
  tmpfile="$(mktemp)"
  cat "${OUT}" > "${tmpfile}"
  mv "${tmpfile}" "${APPLY_PATH}"
  chown root:kismet "${APPLY_PATH}" 2>/dev/null || true
  chmod 644 "${APPLY_PATH}" 2>/dev/null || true
  echo "[+] Done; restart Kismet to pick up new sources"
fi
