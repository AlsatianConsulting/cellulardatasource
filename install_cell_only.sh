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
    libmosquitto-dev
else
  log "apt-get not available; install equivalent build deps manually."
fi

log "Building and installing cell plugin (PREFIX=${PREFIX}, MAKE_JOBS=${MAKE_JOBS})"
pushd "${SCRIPT_DIR}" >/dev/null
MAKE_JOBS="${MAKE_JOBS}" WITH_COLLECTOR="${WITH_COLLECTOR}" \
  ./install.sh --prefix "${PREFIX}" --skip-kismet-build --skip-multi --install-config
popd >/dev/null

log "Ensuring datasource entry exists"
install -d /etc/kismet/datasources.d
cat > /etc/kismet/datasources.d/cell.conf <<EOF
source=cell:name=cell-1,type=cell,exec=${PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:8765
EOF

log "Reloading systemd and enabling autosetup units"
systemctl daemon-reload
systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer || true

if systemctl list-unit-files | grep -q '^kismet.service'; then
  log "Kismet service detected; enabling to start at boot"
  systemctl enable --now kismet || true
else
  log "Kismet systemd unit not found; ensure you start Kismet or create a unit if desired."
fi

log "Done. Restart Kismet if running: systemctl restart kismet"
