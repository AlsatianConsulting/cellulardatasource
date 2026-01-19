#!/usr/bin/env bash
# Install just the cellular datasource (capture helper + plugin) and wire it into an existing Kismet install.
# Run as root on the target (e.g., Raspberry Pi) where Kismet is already installed from packages or source.
#
# Tunables (env):
#   PREFIX (/usr default) – where Kismet is installed
#   MAKE_JOBS (default 1) – build parallelism
#   WITH_COLLECTOR (default 0) – set to 1 to also install collector.py

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

PREFIX="${PREFIX:-/usr}"
MAKE_JOBS="${MAKE_JOBS:-1}"
WITH_COLLECTOR="${WITH_COLLECTOR:-0}"
KISMET_VERSION="${KISMET_VERSION:-kismet-2025-09-R1}"
KISMET_TARBALL_URL="${KISMET_TARBALL_URL:-https://github.com/kismetwireless/kismet/archive/refs/tags/${KISMET_VERSION}.tar.gz}"
KISMET_SRC_ROOT="${KISMET_SRC_ROOT:-/usr/local/src}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

log "Adding Kismet APT repo (trixie) and installing kismet"
apt-get update
apt-get install -y ca-certificates curl gpg
wget -qO- https://www.kismetwireless.net/repos/kismet-release.gpg.key | gpg --dearmor > /usr/share/keyrings/kismet-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/trixie trixie main" > /etc/apt/sources.list.d/kismet.list
apt-get update
apt-get install -y kismet

log "Installing build deps (minimal for plugin/helper)"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y build-essential pkg-config git curl ca-certificates \
    libprotobuf-c-dev protobuf-c-compiler libcap-dev \
    libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
    libmicrohttpd-dev libpcap-dev libnss3-dev libiw-dev libsqlite3-dev \
    zlib1g-dev libnm-dev libavahi-client-dev libusb-1.0-0-dev libudev-dev \
    libpcre2-dev libgnutls28-dev libsensors-dev libssl-dev libdw-dev \
    libncurses-dev libzmq3-dev libbluetooth-dev libftdi1-dev \
    libjansson-dev libwebsockets-dev librtlsdr-dev rtl-433 libbtbb-dev \
    libmosquitto-dev android-tools-adb
else
  log "apt-get not available; install equivalent build deps manually."
fi

log "Building capture helper"
pushd "${SCRIPT_DIR}" >/dev/null
./build_capture.sh
popd >/dev/null

log "Preparing Kismet source for plugin build (${KISMET_VERSION})"
install -d "${KISMET_SRC_ROOT}"
KIS_SRC_DIR=""
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

if [[ -z "${KIS_SRC_DIR}" ]]; then
  curl -fsSL "${KISMET_TARBALL_URL}" | tar -xz -C "${KISMET_SRC_ROOT}"
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

if [[ -z "${KIS_SRC_DIR}" || ! -f "${KIS_SRC_DIR}/globalregistry.h" ]]; then
  echo "[!] Unable to locate Kismet headers (globalregistry.h) for plugin build." >&2
  exit 1
fi

if [[ ! -f "${KIS_SRC_DIR}/Makefile.inc" ]]; then
  log "Configuring Kismet source tree to generate Makefile.inc (no install)"
  pushd "${KIS_SRC_DIR}" >/dev/null
  ./configure --prefix="${PREFIX}"
  popd >/dev/null
fi

log "Building cell plugin (using KIS_INC_DIR=${KIS_SRC_DIR}, MAKE_JOBS=${MAKE_JOBS})"
pushd "${SCRIPT_DIR}/plugin" >/dev/null
KIS_INC_DIR="${KIS_SRC_DIR}" KIS_SRC_DIR="${KIS_SRC_DIR}" make -j"${MAKE_JOBS}"
popd >/dev/null

PLUGIN_DIR="${PREFIX}/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"
BIN_DIR="${PREFIX}/bin"

log "Installing plugin and helper"
install -d "${PLUGIN_DIR}" "${JS_DIR}" "${BIN_DIR}"
install -m 444 "${SCRIPT_DIR}/plugin/manifest.conf" "${PLUGIN_DIR}/"
install -m 755 "${SCRIPT_DIR}/plugin/cell.so" "${PLUGIN_DIR}/"
install -m 644 "${SCRIPT_DIR}/plugin/httpd/js/kismet.ui.cell.js" "${JS_DIR}/"
install -m 755 "${SCRIPT_DIR}/kismet_cap_cell_capture" "${BIN_DIR}/"
if [[ "${WITH_COLLECTOR}" -eq 1 ]]; then
  install -m 755 "${SCRIPT_DIR}/../collector.py" "${BIN_DIR}/collector.py"
fi
# Helper scripts for autosetup
install -m 755 "${SCRIPT_DIR}/multi_phone.sh" "${BIN_DIR}/multi_phone.sh"
install -m 755 "${SCRIPT_DIR}/cell_autoconfig.sh" "${BIN_DIR}/cell_autoconfig.sh"
install -m 755 "${SCRIPT_DIR}/uds_forwarder.py" "${BIN_DIR}/uds_forwarder.py"

log "Seeding kismet.conf if missing"
install -d /etc/kismet
if [[ ! -f /etc/kismet/kismet.conf ]]; then
  for seed in "${KIS_SRC_DIR}/kismet.conf" /usr/etc/kismet.conf /usr/etc/kismet/kismet.conf /usr/share/kismet/kismet.conf; do
    [[ -f "${seed}" ]] && install -m 644 "${seed}" /etc/kismet/kismet.conf && break
  done
fi

log "Ensuring datasource entry exists"
install -d /etc/kismet/datasources.d
cat > /etc/kismet/datasources.d/cell.conf <<EOF
source=cell:name=cell-1,type=cell,exec=${PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:8765
EOF
# Ensure plugin is loaded
SITE_CONF="/etc/kismet/kismet_site.conf"
touch "${SITE_CONF}"
if ! grep -q "/usr/lib/kismet/cell/manifest.conf" "${SITE_CONF}"; then
  echo "plugin=/usr/lib/kismet/cell/manifest.conf" >> "${SITE_CONF}"
fi

log "Reloading systemd and enabling autosetup units"
SERVICE_PATH="/etc/systemd/system/kismet-cell-autosetup.service"
TIMER_PATH="/etc/systemd/system/kismet-cell-autosetup.timer"
if [[ ! -f "${SERVICE_PATH}" ]]; then
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Auto-configure Kismet cell datasource and GPS forwarding
After=network.target

[Service]
Type=oneshot
Environment=PREFIX=${PREFIX}
Environment=BASE_PORT=9875
Environment=GPS_PORT=8766
Environment=FORWARD_GPS=1
ExecStart=${BIN_DIR}/cell_autoconfig.sh

[Install]
WantedBy=multi-user.target
EOF
fi
if [[ ! -f "${TIMER_PATH}" ]]; then
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
fi
systemctl daemon-reload
systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer || true

# Ensure kismet user/group exist
if ! getent group kismet >/dev/null 2>&1; then
  log "Creating kismet group"
  groupadd --system kismet
fi
if ! id -u kismet >/dev/null 2>&1; then
  log "Creating kismet user"
  useradd --system --gid kismet --home /var/lib/kismet --shell /usr/sbin/nologin kismet
fi
install -d -o kismet -g kismet /var/lib/kismet
install -d -o kismet -g kismet /var/log/kismet

log "Writing kismet.service unit with restart policy"
cat > /etc/systemd/system/kismet.service <<EOF
[Unit]
Description=Kismet wireless IDS server
After=network.target

[Service]
User=kismet
Group=kismet
ExecStart=${PREFIX}/bin/kismet --no-ncurses --config /etc/kismet/kismet.conf --log-prefix /var/log/kismet
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes
KillMode=process
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl unmask kismet || true
systemctl enable --now kismet || true

log "Done. Restart Kismet if running: systemctl restart kismet"
