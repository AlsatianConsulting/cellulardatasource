#!/usr/bin/env bash
# Turnkey installer for Raspberry Pi: installs Kismet + all capture helpers, then installs
# the cellular datasource plugin and enables services with restart-on-failure.
# Run as root:  sudo ./pi_kismet_cell_turnkey.sh

set -euo pipefail

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run this script as root." >&2; exit 1; }

# Tunables
PREFIX="${PREFIX:-/usr}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cellulardatasource}"
REPO_URL="${REPO_URL:-https://github.com/AlsatianConsulting/cellulardatasource.git}"
BRANCH="${BRANCH:-main}"
MAKE_JOBS="${MAKE_JOBS:-1}"

CODENAME="$(lsb_release -cs)"
KEYRING="/usr/share/keyrings/kismet-archive-keyring.gpg"
SOURCELIST="/etc/apt/sources.list.d/kismet.list"

log "Adding Kismet APT repo for ${CODENAME}"
apt-get update
apt-get install -y ca-certificates curl gpg lsb-release
if [[ ! -s "${KEYRING}" ]]; then
  curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg | gpg --dearmor -o "${KEYRING}"
fi
echo "deb [signed-by=${KEYRING}] https://www.kismetwireless.net/repos/apt/release ${CODENAME} main" > "${SOURCELIST}"

log "Installing Kismet and capture packages (single-core builds: MAKE_JOBS=${MAKE_JOBS})"
apt-get update
apt-get install -y \
  git build-essential pkg-config android-tools-adb python3 \
  kismet kismet-core kismet-logtools kismet-adsb-icao-data \
  kismet-capture-linux-wifi kismet-capture-linux-bluetooth \
  kismet-capture-rtl433-v2 kismet-capture-rtladsb-v2 \
  kismet-capture-freaklabs-zigbee-v2 \
  kismet-capture-ti-cc-2540 kismet-capture-ti-cc-2531 \
  kismet-capture-nrf-51822 kismet-capture-nrf-52840 \
  kismet-capture-nxp-kw41z kismet-capture-nrf-mousejack \
  kismet-capture-rz-killerbee kismet-capture-ubertooth-one \
  kismet-capture-serial-radview kismet-capture-radiacode-usb \
  kismet-capture-antsdr-droneid kismet-capture-hak5-wifi-coconut

log "Fetching cellular datasource repo (${BRANCH}) to ${INSTALL_DIR}"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  git -C "${INSTALL_DIR}" fetch --all
  git -C "${INSTALL_DIR}" checkout "${BRANCH}"
  git -C "${INSTALL_DIR}" reset --hard "origin/${BRANCH}"
else
  install -d "${INSTALL_DIR}"
  git clone --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

log "Installing cell plugin (skip Kismet rebuild)"
pushd "${INSTALL_DIR}/kismet-cap-cell" >/dev/null
MAKE_JOBS="${MAKE_JOBS}" ./install.sh \
  --prefix "${PREFIX}" \
  --install-config \
  --skip-multi \
  --skip-kismet-build
popd >/dev/null

log "Ensuring datasource entry exists"
install -d /etc/kismet/datasources.d
cat > /etc/kismet/datasources.d/cell.conf <<EOF
source=cell:name=cell-1,type=cell,exec=${PREFIX}/bin/kismet_cap_cell_capture:tcp://127.0.0.1:8765
EOF

log "Forcing restart policy on Kismet service"
install -d /etc/systemd/system/kismet.service.d
cat > /etc/systemd/system/kismet.service.d/override.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5
EOF

log "Reloading systemd and enabling services"
systemctl daemon-reload
systemctl unmask kismet || true
systemctl enable --now kismet
systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer

log "Done. If you change datasources, restart: systemctl restart kismet"
