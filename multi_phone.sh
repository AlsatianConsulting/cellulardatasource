#!/usr/bin/env bash
# Auto-forward all attached Android phones and generate Kismet source lines.
# Usage:
#   ./multi_phone.sh [--base-port 9875] [--prefix /usr/local] [--gps-port 8766] [--no-gps] [--out cell_sources.conf] [--apply-path /usr/local/etc/kismet/datasources.d/cell.conf]
#
# For each attached device (via `adb devices`), this will:
#   - forward tcp:<base-port+N> on the host to tcp:8765 on the phone
#   - emit a Kismet source line using that port and the given prefix for the binary
# If --apply-path is provided, the generated lines replace that file.
# If GPS forwarding is enabled (default), the first device also forwards TCP GPS on tcp:8766 on phone -> tcp:<gps-port> on host.

set -euo pipefail

BASE_PORT=9875
PREFIX="/usr/local"
OUT="cell_sources.conf"
APPLY_PATH=""
GPS_PORT=8766
FORWARD_GPS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-port)
      BASE_PORT="$2"; shift 2;;
    --prefix)
      PREFIX="$2"; shift 2;;
    --gps-port)
      GPS_PORT="$2"; shift 2;;
    --no-gps)
      FORWARD_GPS=0; shift 1;;
    --out)
      OUT="$2"; shift 2;;
    --apply-path)
      APPLY_PATH="$2"; shift 2;;
    *)
      echo "Unknown option: $1" >&2
      exit 1;;
  esac
done

ADB_BIN="$(command -v adb || true)"
if [[ -z "${ADB_BIN}" ]]; then
  echo "adb not found; please install Android platform tools" >&2
  exit 1
fi

mapfile -t SERIALS < <("${ADB_BIN}" devices | awk 'NR>1 && $2=="device"{print $1}')
if [[ ${#SERIALS[@]} -eq 0 ]]; then
  echo "No attached devices" >&2
  exit 1
fi

echo "[*] Using base port ${BASE_PORT}, prefix ${PREFIX}"
if [[ ${FORWARD_GPS} -eq 1 ]]; then
  echo "[*] GPS forwarding enabled on host port ${GPS_PORT} (device tcp:8766, first device only)"
fi
> "${OUT}"

idx=0
for serial in "${SERIALS[@]}"; do
  port=$((BASE_PORT + idx))
  echo "[*] ${serial} -> tcp:${port}"
  "${ADB_BIN}" -s "${serial}" forward "tcp:${port}" "tcp:8765"
  echo "source=cell:name=cell-${serial},type=cell,exec=${PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:${port}" >> "${OUT}"
  if [[ ${FORWARD_GPS} -eq 1 && ${idx} -eq 0 ]]; then
    echo "[*] ${serial} (GPS) -> tcp:${GPS_PORT}"
    "${ADB_BIN}" -s "${serial}" forward "tcp:${GPS_PORT}" "tcp:8766"
  fi
  idx=$((idx + 1))
done

echo "[+] Wrote $(wc -l < "${OUT}") sources to ${OUT}"

if [[ -n "${APPLY_PATH}" ]]; then
  echo "[*] Writing sources to ${APPLY_PATH}"
  install -d "$(dirname "${APPLY_PATH}")"
  tmpfile="$(mktemp)"
  cat "${OUT}" > "${tmpfile}"
  mv "${tmpfile}" "${APPLY_PATH}"
  echo "[+] Done; restart Kismet to pick up new sources"
fi
