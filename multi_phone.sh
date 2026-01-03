#!/usr/bin/env bash
# Auto-forward all attached Android phones and generate Kismet source lines.
# Usage:
#   ./multi_phone.sh [--base-port 9875] [--prefix /usr/local] [--out cell_sources.conf] [--apply-path /usr/local/etc/kismet/datasources.d/cell.conf]
#
# For each attached device (via `adb devices`), this will:
#   - forward tcp:<base-port+N> on the host to tcp:8765 on the phone
#   - emit a Kismet source line using that port and the given prefix for the binary
# If --apply-path is provided, the generated lines are appended there (otherwise written to --out).

set -euo pipefail

BASE_PORT=9875
PREFIX="/usr/local"
OUT="cell_sources.conf"
APPLY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-port)
      BASE_PORT="$2"; shift 2;;
    --prefix)
      PREFIX="$2"; shift 2;;
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
> "${OUT}"

idx=0
for serial in "${SERIALS[@]}"; do
  port=$((BASE_PORT + idx))
  echo "[*] ${serial} -> tcp:${port}"
  "${ADB_BIN}" -s "${serial}" forward "tcp:${port}" "tcp:8765"
  echo "source=cell:name=cell-${serial},type=cell,exec=${PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:${port}" >> "${OUT}"
  idx=$((idx + 1))
done

echo "[+] Wrote $(wc -l < "${OUT}") sources to ${OUT}"

if [[ -n "${APPLY_PATH}" ]]; then
  echo "[*] Appending sources to ${APPLY_PATH}"
  cat "${OUT}" >> "${APPLY_PATH}"
  echo "[+] Done; restart Kismet to pick up new sources"
fi
