#!/usr/bin/env bash
# Package the cell capture helper and Kismet plugin into a tarball.
# Usage: ./package.sh [--kismet-prefix /usr/local] [--output cell-datasource.tar.gz] [--with-collector]
# Defaults:
#   KISMET_PREFIX=/usr/local
#   OUTPUT=cell-datasource.tar.gz
#
# The resulting tarball contains:
#   bin/kismet_cap_cell_capture
#   kismet-plugin/cell/{manifest.conf,cell.so,httpd/js/kismet.ui.cell.js}
#   datasource-cell.conf.sample
#   (optional) collector.py

set -euo pipefail

KISMET_PREFIX="/usr/local"
OUTPUT="cell-datasource.tar.gz"
WITH_COLLECTOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kismet-prefix)
      KISMET_PREFIX="$2"; shift 2;;
    --output)
      OUTPUT="$2"; shift 2;;
    --with-collector)
      WITH_COLLECTOR=1; shift 1;;
    *)
      echo "Unknown option: $1" >&2
      exit 1;;
  esac
done

ROOT="$(pwd)"
STAGE="${ROOT}/pkgroot"

echo "[*] Cleaning stage dir ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/kismet-plugin/cell/httpd/js"

echo "[*] Building capture helper"
./build_capture.sh
cp "${ROOT}/kismet_cap_cell_capture" "${STAGE}/bin/"

echo "[*] Building plugin"
pushd "${ROOT}/plugin" >/dev/null
make
cp manifest.conf "${STAGE}/kismet-plugin/cell/"
cp cell.so "${STAGE}/kismet-plugin/cell/"
cp httpd/js/kismet.ui.cell.js "${STAGE}/kismet-plugin/cell/httpd/js/"
popd >/dev/null

echo "[*] Copying configs"
cp "${ROOT}/datasource-cell.conf.sample" "${STAGE}/"
cp "${ROOT}/install.sh" "${STAGE}/"
cp "${ROOT}/multi_phone.sh" "${STAGE}/"
if [[ ${WITH_COLLECTOR} -eq 1 ]]; then
  COLLECTOR_SRC="${ROOT}/../collector.py"
  if [[ ! -f "${COLLECTOR_SRC}" && -f "${ROOT}/../collector.bak" ]]; then
    COLLECTOR_SRC="${ROOT}/../collector.bak"
  fi
  if [[ -f "${COLLECTOR_SRC}" ]]; then
    cp "${COLLECTOR_SRC}" "${STAGE}/collector.py"
  else
    echo "[!] Collector not found; skipping"
  fi
fi

echo "[*] Writing INSTALL.txt with prefix ${KISMET_PREFIX}"
cat > "${STAGE}/INSTALL.txt" <<EOF
Install instructions (prefix ${KISMET_PREFIX}):

Plugin:
  sudo install -d ${KISMET_PREFIX}/lib/kismet/cell/httpd/js
  sudo install -m 444 kismet-plugin/cell/manifest.conf ${KISMET_PREFIX}/lib/kismet/cell/
  sudo install -m 755 kismet-plugin/cell/cell.so ${KISMET_PREFIX}/lib/kismet/cell/
  sudo install -m 644 kismet-plugin/cell/httpd/js/kismet.ui.cell.js ${KISMET_PREFIX}/lib/kismet/cell/httpd/js/

Capture binary:
  sudo install -d ${KISMET_PREFIX}/bin
  sudo install -m 755 bin/kismet_cap_cell_capture ${KISMET_PREFIX}/bin/

Kismet source config (append to a .conf, e.g. ${KISMET_PREFIX}/etc/kismet_site.conf):
  source=cell:name=cell-1,type=cell,exec=${KISMET_PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:8765

After install:
  - Restart Kismet
  - Hard-refresh the web UI to load the cell JS
EOF

echo "[*] Creating tarball ${OUTPUT}"
tar -C "${STAGE}" -czf "${OUTPUT}" .
echo "[+] Done: ${OUTPUT}"
