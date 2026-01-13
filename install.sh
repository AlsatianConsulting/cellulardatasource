#!/usr/bin/env bash
# Install the cell capture helper and Kismet plugin with a configurable prefix.
# Usage:
#   ./install.sh [--prefix /usr] [--install-config] [--with-collector] [--skip-multi] [--base-port 9875]
#
# Defaults:
#   PREFIX=/usr
#   Config is NOT installed unless --install-config is given
#   Collector is NOT installed unless --with-collector is given
#   multi_phone.sh is run to auto-forward all attached phones and write sources unless --skip-multi is given
#   Base port for multi_phone is 9875 unless overridden
#
# Paths used (under PREFIX unless otherwise noted):
#   Plugin:   $PREFIX/lib/kismet/cell/{cell.so,manifest.conf,httpd/js/kismet.ui.cell.js}
#   Binary:   $PREFIX/bin/kismet_cap_cell_capture
#   Config:   /etc/kismet/datasource-cell.conf.sample (only with --install-config)

set -euo pipefail

PREFIX="/usr"
INSTALL_CONFIG=0
WITH_COLLECTOR=0
SKIP_MULTI=0
FORWARD_GPS=1
GPS_PORT=8766
BASE_PORT=9875
ENABLE_AUTOSTART=1
KIS_SRC_DIR="${KIS_SRC_DIR:-}"
KIS_INC_DIR="${KIS_INC_DIR:-}"
KISMET_VERSION="${KISMET_VERSION:-kismet-2025-09-R1}"
KISMET_TARBALL_URL="${KISMET_TARBALL_URL:-https://github.com/kismetwireless/kismet/archive/refs/tags/${KISMET_VERSION}.tar.gz}"
KISMET_SRC_ROOT="${KISMET_SRC_ROOT:-/usr/local/src}"
KISMET_REUSE_SRC="${KISMET_REUSE_SRC:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"; shift 2;;
    --install-config)
      INSTALL_CONFIG=1; shift 1;;
    --with-collector)
      WITH_COLLECTOR=1; shift 1;;
    --no-service)
      ENABLE_AUTOSTART=0; shift 1;;
    --gps-port)
      GPS_PORT="$2"; shift 2;;
    --no-gps)
      FORWARD_GPS=0; shift 1;;
    --skip-multi)
      SKIP_MULTI=1; shift 1;;
    --base-port)
      BASE_PORT="$2"; shift 2;;
    *)
      echo "Unknown option: $1" >&2
      exit 1;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="${PREFIX}/bin"
PLUGIN_DIR="${PREFIX}/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"
CONFIG_DIR="/etc/kismet"
CONFIG_DS_DIR="${CONFIG_DIR}/datasources.d"
SERVICE_PATH="/etc/systemd/system/kismet-cell-autosetup.service"
TIMER_PATH="/etc/systemd/system/kismet-cell-autosetup.timer"

echo "[*] Using PREFIX=${PREFIX}"
echo "[*] Binary will go to ${BIN_DIR}"
echo "[*] Plugin will go to ${PLUGIN_DIR}"
if [[ ${INSTALL_CONFIG} -eq 1 ]]; then
  echo "[*] Config sample will go to ${CONFIG_DIR}"
fi
if [[ ${WITH_COLLECTOR} -eq 1 ]]; then
  echo "[*] Collector will be installed"
fi

echo "[*] Installing build dependencies"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y git curl ca-certificates build-essential pkg-config \
    libprotobuf-c-dev protobuf-c-compiler libprotobuf-dev protobuf-compiler \
    libcap-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
    libmicrohttpd-dev libpcap-dev libnss3-dev libiw-dev libsqlite3-dev \
    zlib1g-dev libnm-dev libavahi-client-dev libusb-1.0-0-dev libudev-dev \
    libpcre2-dev libgnutls28-dev libsensors-dev libssl-dev libdw-dev \
    libncurses-dev libzmq3-dev libbluetooth-dev libftdi1-dev \
    libjansson-dev libwebsockets-dev librtlsdr-dev rtl-433 libbtbb-dev \
    libmosquitto-dev
else
  echo "[!] apt-get not found; please install equivalent dependencies manually." >&2
fi

echo "[*] Building capture helper"
cd "${SCRIPT_DIR}"
./build_capture.sh

echo "[*] Building plugin"
if [[ -z "${KIS_SRC_DIR}" ]]; then
  # Attempt to reuse existing source tree with headers
  if [[ -n "${KIS_INC_DIR}" && -f "${KIS_INC_DIR}/globalregistry.h" ]]; then
    KIS_SRC_DIR="${KIS_INC_DIR}"
  elif [[ -d "${KISMET_SRC_ROOT}" ]]; then
    # Look for an existing extracted tree
    for cand in \
      "${KISMET_SRC_ROOT}/${KISMET_VERSION}" \
      "${KISMET_SRC_ROOT}/kismet-${KISMET_VERSION}" \
      "${KISMET_SRC_ROOT}/kismet-kismet-${KISMET_VERSION}"
    do
      if [[ -f "${cand}/globalregistry.h" ]]; then
        KIS_SRC_DIR="${cand}"
        break
      fi
    done
  fi
fi

echo "[*] Fetching Kismet source (${KISMET_VERSION})"
install -d "${KISMET_SRC_ROOT}"
if [[ "${KISMET_REUSE_SRC}" != "1" ]]; then
  for old in "${KISMET_SRC_ROOT}/${KISMET_VERSION}" "${KISMET_SRC_ROOT}/kismet-${KISMET_VERSION}" "${KISMET_SRC_ROOT}/kismet-kismet-${KISMET_VERSION}"; do
    [[ -d "${old}" ]] && rm -rf "${old}"
  done
fi
if [[ ! -d "${KISMET_SRC_ROOT}/${KISMET_VERSION}" && ! -d "${KISMET_SRC_ROOT}/kismet-${KISMET_VERSION}" && ! -d "${KISMET_SRC_ROOT}/kismet-kismet-${KISMET_VERSION}" ]]; then
  curl -fL "${KISMET_TARBALL_URL}" | tar -xz -C "${KISMET_SRC_ROOT}"
fi
for cand in \
  "${KISMET_SRC_ROOT}/${KISMET_VERSION}" \
  "${KISMET_SRC_ROOT}/kismet-${KISMET_VERSION}" \
  "${KISMET_SRC_ROOT}/kismet-kismet-${KISMET_VERSION}"
do
  if [[ -f "${cand}/globalregistry.h" ]]; then
    KIS_SRC_DIR="${cand}"
    break
  fi
done

if [[ -z "${KIS_SRC_DIR}" || ! -f "${KIS_SRC_DIR}/globalregistry.h" ]]; then
  echo "[!] Unable to locate Kismet headers (globalregistry.h). Set KIS_SRC_DIR to your Kismet source tree and re-run." >&2
  exit 1
fi

if ! getent group kismet >/dev/null 2>&1; then
  echo "[*] Creating kismet group"
  groupadd --system kismet
fi
if ! id -u kismet >/dev/null 2>&1; then
  echo "[*] Creating kismet user"
  useradd --system --gid kismet --shell /usr/sbin/nologin --home /var/lib/kismet kismet
fi

echo "[*] Building Kismet from source at ${KIS_SRC_DIR}"
pushd "${KIS_SRC_DIR}" >/dev/null
if [[ -f Makefile ]]; then
  make clean || true
fi
./configure --prefix="${PREFIX}"
make
make install
popd >/dev/null

export KIS_SRC_DIR
export KIS_INC_DIR="${KIS_INC_DIR:-${KIS_SRC_DIR}}"
pushd "${SCRIPT_DIR}/plugin" >/dev/null
make
popd >/dev/null

echo "[*] Installing plugin files"
install -d "${PLUGIN_DIR}" "${JS_DIR}"
install -m 444 "${SCRIPT_DIR}/plugin/manifest.conf" "${PLUGIN_DIR}/"
install -m 755 "${SCRIPT_DIR}/plugin/cell.so" "${PLUGIN_DIR}/"
install -m 644 "${SCRIPT_DIR}/plugin/httpd/js/kismet.ui.cell.js" "${JS_DIR}/"

echo "[*] Installing capture binary"
install -d "${BIN_DIR}"
install -m 755 "${SCRIPT_DIR}/kismet_cap_cell_capture" "${BIN_DIR}/"

if [[ ${INSTALL_CONFIG} -eq 1 ]]; then
  echo "[*] Installing config sample"
  install -d "${CONFIG_DIR}"
  install -m 644 "${SCRIPT_DIR}/datasource-cell.conf.sample" "${CONFIG_DIR}/datasource-cell.conf.sample"
fi

if [[ ${WITH_COLLECTOR} -eq 1 ]]; then
  echo "[*] Installing collector.py"
  install -d "${BIN_DIR}"
  install -m 755 "${SCRIPT_DIR}/../collector.py" "${BIN_DIR}/collector.py"
fi

echo "[*] Ensuring Kismet config directory ${CONFIG_DIR}"
install -d "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_DIR}/kismet.conf" && -f "${KIS_SRC_DIR}/kismet.conf" ]]; then
  echo "[*] Installing kismet.conf to ${CONFIG_DIR}"
  install -m 644 "${KIS_SRC_DIR}/kismet.conf" "${CONFIG_DIR}/kismet.conf"
fi

echo "[*] Installing helper scripts"
install -m 755 "${SCRIPT_DIR}/multi_phone.sh" "${BIN_DIR}/multi_phone.sh"
install -m 755 "${SCRIPT_DIR}/cell_autoconfig.sh" "${BIN_DIR}/cell_autoconfig.sh"

if [[ ${SKIP_MULTI} -eq 0 ]]; then
  echo "[*] Running multi_phone to set up sources (base port ${BASE_PORT}, gps port ${GPS_PORT})"
  mkdir -p "${CONFIG_DS_DIR}"
  CELL_CONF="${CONFIG_DS_DIR}/cell.conf"
  TMP_CONF="$(mktemp)"
  if command -v adb >/dev/null 2>&1; then
    if "${BIN_DIR}/multi_phone.sh" --base-port "${BASE_PORT}" --prefix "${PREFIX}" --gps-port "${GPS_PORT}" $( [[ ${FORWARD_GPS} -eq 0 ]] && echo --no-gps ) --out "${TMP_CONF}" --apply-path "${CELL_CONF}"; then
      if [[ -s "${CELL_CONF}" ]]; then
        echo "[+] Wrote $(wc -l < "${CELL_CONF}") sources to ${CELL_CONF}"
      else
        echo "[!] multi_phone produced no sources; leaving ${CELL_CONF} unchanged" >&2
      fi
    else
      echo "[!] multi_phone.sh did not complete; check adb/devices. You can re-run it later manually." >&2
    fi
  else
    echo "[!] adb not found; skipping multi_phone. Install Android platform tools and re-run multi_phone.sh manually." >&2
  fi
else
  echo "[*] Skipping multi_phone per --skip-multi"
fi

cat <<EOF
[+] Install complete.

Add this line (adjust host/port if needed) to your Kismet config, e.g. ${CONFIG_DIR}/kismet_site.conf:
  source=cell:name=cell-1,type=cell,exec=${BIN_DIR}/kismet_cap_cell_capture:tcp://127.0.0.1:8765

Then restart Kismet and hard-refresh the web UI to load the cell plugin JS.
EOF

if [[ ${ENABLE_AUTOSTART} -eq 1 ]]; then
  echo "[*] Installing kismet-cell-autosetup systemd service"
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Auto-configure Kismet cell datasource and GPS forwarding
After=network.target

[Service]
Type=oneshot
Environment=PREFIX=${PREFIX}
Environment=BASE_PORT=${BASE_PORT}
Environment=GPS_PORT=${GPS_PORT}
Environment=FORWARD_GPS=${FORWARD_GPS}
ExecStart=${BIN_DIR}/cell_autoconfig.sh

[Install]
WantedBy=multi-user.target
EOF
  echo "[*] Installing kismet-cell-autosetup timer"
  cat > "${TIMER_PATH}" <<EOF
[Unit]
Description=Periodic Kismet cell datasource autoconfig

[Timer]
OnBootSec=10sec
OnUnitActiveSec=30sec
Unit=kismet-cell-autosetup.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer || true
fi

if command -v systemctl >/dev/null 2>&1; then
  echo "[*] Installing kismet.service"
  cat > /etc/systemd/system/kismet.service <<EOF
[Unit]
Description=Kismet wireless IDS server
After=network.target

[Service]
User=kismet
Group=kismet
ExecStart=/usr/bin/kismet --no-ncurses --config /etc/kismet/kismet.conf
Restart=on-failure
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes
KillMode=process
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now kismet || true
fi
