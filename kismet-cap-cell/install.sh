#!/usr/bin/env bash
# Install cellular datasource components for Kismet.
# This installer is intentionally single-device focused and does not configure RTL433.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

PREFIX="${PREFIX:-/usr}"
MAKE_JOBS="${MAKE_JOBS:-1}"
WITH_COLLECTOR="${WITH_COLLECTOR:-0}"
INSTALL_SERVICES="${INSTALL_SERVICES:-ask}"   # ask|0|1
INSTALL_KISMET="${INSTALL_KISMET:-ask}"       # ask|0|1
KIS_REPO_CODENAME="${KIS_REPO_CODENAME:-$(lsb_release -cs)}"
KIS_REPO_TRUSTED="${KIS_REPO_TRUSTED:-auto}"  # auto|0|1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PREFIX}/bin"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

append_line_if_missing() {
  local file="$1"
  local line="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
  fi
}

set_service_kv() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "${file}" ]]; then
    printf '[Service]\n' > "${file}"
  elif ! grep -q '^\[Service\]$' "${file}"; then
    printf '\n[Service]\n' >> "${file}"
  fi

  if grep -q "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|g" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

resolve_toggle() {
  local var_name="$1"
  local prompt="$2"
  local value="${!var_name}"

  case "${value}" in
    0|1) return 0 ;;
    ask)
      if [[ -t 0 ]]; then
        local ans=""
        read -r -p "${prompt} [y/N]: " ans
        case "${ans}" in
          y|Y|yes|YES) printf -v "${var_name}" '%s' "1" ;;
          *) printf -v "${var_name}" '%s' "0" ;;
        esac
      else
        printf -v "${var_name}" '%s' "0"
      fi
      ;;
    *)
      echo "${var_name} must be ask, 0, or 1 (got: ${value})" >&2
      exit 1
      ;;
  esac
}

resolve_toggle INSTALL_KISMET "Install Kismet from apt repo now?"
resolve_toggle INSTALL_SERVICES "Install and enable systemd services now?"

if [[ "${INSTALL_KISMET}" == "1" ]]; then
  log "Adding Kismet apt repo (${KIS_REPO_CODENAME}) and installing kismet"
  apt-get update
  apt-get install -y ca-certificates curl gpg

  keytmp="$(mktemp)"
  curl -fsSL "https://www.kismetwireless.net/repos/kismet-release.gpg.key" > "${keytmp}" || true
  if [[ -s "${keytmp}" ]]; then
    gpg --dearmor < "${keytmp}" > /usr/share/keyrings/kismet-archive-keyring.gpg
  fi
  rm -f "${keytmp}"

  if [[ "${KIS_REPO_TRUSTED}" == "auto" ]]; then
    KIS_REPO_TRUSTED=0
  fi
  if [[ "${KIS_REPO_TRUSTED}" == "0" && ! -s /usr/share/keyrings/kismet-archive-keyring.gpg ]]; then
    KIS_REPO_TRUSTED=1
  fi

  if [[ "${KIS_REPO_TRUSTED}" == "1" ]]; then
    REPO_LINE="deb [trusted=yes] https://www.kismetwireless.net/repos/apt/release/${KIS_REPO_CODENAME} ${KIS_REPO_CODENAME} main"
  else
    REPO_LINE="deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/${KIS_REPO_CODENAME} ${KIS_REPO_CODENAME} main"
  fi

  for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "${f}" ]] || continue
    sed -i '\|kismetwireless\.net/repos/apt/release|d' "${f}" || true
  done
  printf '%s\n' "${REPO_LINE}" > /etc/apt/sources.list.d/kismet.list

  apt-get update
  apt-get install -y kismet kismet-core kismet-logtools kismet-capture-linux-wifi kismet-capture-linux-bluetooth
else
  log "Skipping Kismet apt install"
fi

log "Installing build/runtime dependencies"
apt-get update
apt-get install -y \
  build-essential pkg-config git curl ca-certificates python3 \
  libprotobuf-c-dev protobuf-c-compiler libcap-dev \
  libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
  libmicrohttpd-dev libpcap-dev libnss3-dev libiw-dev libsqlite3-dev \
  zlib1g-dev libnm-dev libavahi-client-dev libusb-1.0-0-dev libudev-dev \
  libpcre2-dev libgnutls28-dev libsensors-dev libssl-dev libdw-dev \
  libncurses-dev libzmq3-dev libftdi1-dev \
  libjansson-dev libwebsockets-dev libbtbb-dev \
  libmosquitto-dev android-tools-adb rfkill jq netcat-openbsd usbutils

log "Building capture helper"
pushd "${SCRIPT_DIR}" >/dev/null
./build_capture.sh
popd >/dev/null

KIS_SRC_DIR=""
for cand in /usr/local/src/kismet-* /usr/src/kismet-* /opt/kismet-*; do
  if [[ -f "${cand}/globalregistry.h" ]]; then
    KIS_SRC_DIR="${cand}"
    break
  fi
done

if [[ -z "${KIS_SRC_DIR}" ]]; then
  if [[ -f "/usr/include/kismet/version.h" ]]; then
    KIS_SRC_DIR="/usr/include/kismet"
  else
    echo "Unable to locate Kismet headers needed for plugin build." >&2
    exit 1
  fi
fi

log "Building cell plugin"
pushd "${SCRIPT_DIR}/plugin" >/dev/null
KIS_INC_DIR="${KIS_SRC_DIR}" KIS_SRC_DIR="${KIS_SRC_DIR}" make -j"${MAKE_JOBS}"
popd >/dev/null

PLUGIN_DIR="${PREFIX}/lib/kismet/cell"
JS_DIR="${PLUGIN_DIR}/httpd/js"

log "Installing plugin, helper, and scripts"
install -d "${PLUGIN_DIR}" "${JS_DIR}" "${BIN_DIR}"
install -m 444 "${SCRIPT_DIR}/plugin/manifest.conf" "${PLUGIN_DIR}/"
install -m 755 "${SCRIPT_DIR}/plugin/cell.so" "${PLUGIN_DIR}/"
install -m 644 "${SCRIPT_DIR}/plugin/httpd/js/kismet.ui.cell.js" "${JS_DIR}/"
install -m 755 "${SCRIPT_DIR}/kismet_cap_cell_capture" "${BIN_DIR}/"
ln -sf "${BIN_DIR}/kismet_cap_cell_capture" "${BIN_DIR}/kismet_cap_cell"
ln -sf "${BIN_DIR}/kismet_cap_cell_capture" "${BIN_DIR}/kismet_cap_cellstream"

install -m 755 "${SCRIPT_DIR}/multi_phone.sh" "${BIN_DIR}/multi_phone.sh"
install -m 755 "${SCRIPT_DIR}/cell_autoconfig.sh" "${BIN_DIR}/cell_autoconfig.sh"
install -m 755 "${SCRIPT_DIR}/kismet_cell_injector.sh" "${BIN_DIR}/kismet_cell_injector.sh"
install -m 755 "${SCRIPT_DIR}/cell_remote_bridge.py" "${BIN_DIR}/cell_remote_bridge.py"
install -m 755 "${SCRIPT_DIR}/cell_transport_toggle.sh" "${BIN_DIR}/cell_transport_toggle.sh"
install -m 755 "${SCRIPT_DIR}/uds_forwarder.py" "${BIN_DIR}/uds_forwarder.py"
ln -sf "${BIN_DIR}/cell_transport_toggle.sh" "${BIN_DIR}/cell-transport-mode"

if [[ "${WITH_COLLECTOR}" == "1" ]]; then
  install -m 755 "${SCRIPT_DIR}/collector.py" "${BIN_DIR}/collector.py"
fi

log "Seeding Kismet config fragments"
install -d /etc/kismet /etc/kismet/datasources.d
SITE_CONF="/etc/kismet/kismet_site.conf"
CELL_CONF="/etc/kismet/datasources.d/cell.conf"

touch "${SITE_CONF}"
append_line_if_missing "${SITE_CONF}" "plugin=/usr/lib/kismet/cell/manifest.conf"
append_line_if_missing "${SITE_CONF}" "opt_include=/etc/kismet/datasources.d/*.conf"

if [[ ! -f "${CELL_CONF}" ]]; then
  cat > "${CELL_CONF}" <<'CFEOF'
# Managed by cell_autoconfig.sh
# Runtime cell sources are bridged by kismet-cell-bridge.service.
CFEOF
fi
chown root:kismet "${SITE_CONF}" "${CELL_CONF}" 2>/dev/null || true
chmod 640 "${SITE_CONF}" 2>/dev/null || true
chmod 644 "${CELL_CONF}" 2>/dev/null || true

if [[ "${INSTALL_SERVICES}" == "1" ]]; then
  log "Installing cellular systemd services"
  CELL_SERVICE_PATH="/etc/systemd/system/kismet-cell-autosetup.service"
  CELL_TIMER_PATH="/etc/systemd/system/kismet-cell-autosetup.timer"
  BRIDGE_SERVICE_PATH="/etc/systemd/system/kismet-cell-bridge.service"

  cat > "${CELL_SERVICE_PATH}" <<EOF2
[Unit]
Description=Auto-configure Kismet cell datasource and GPS forwarding
After=network.target

[Service]
Type=oneshot
KillMode=process
Environment=PREFIX=${PREFIX}
Environment=BASE_PORT=9875
Environment=GPS_PORT=8766
Environment=FORWARD_GPS=1
Environment=TRANSPORT_MODE=usb
ExecStart=${BIN_DIR}/cell_autoconfig.sh

[Install]
WantedBy=multi-user.target
EOF2

  cat > "${CELL_TIMER_PATH}" <<'EOF2'
[Unit]
Description=Periodic Kismet cell datasource autoconfig

[Timer]
OnBootSec=10sec
OnUnitActiveSec=30sec
Unit=kismet-cell-autosetup.service

[Install]
WantedBy=timers.target
EOF2

  cat > "${BRIDGE_SERVICE_PATH}" <<EOF2
[Unit]
Description=Supervise cellular remote-capture helper processes for Kismet
After=network.target kismet.service kismet-cell-autosetup.service
Wants=kismet.service kismet-cell-autosetup.service

[Service]
Type=simple
KillMode=control-group
Environment=SOURCE_FILE=/var/lib/kismet/cell/sources.generated
Environment=REMOTE_HOSTPORT=127.0.0.1:3501
Environment=HELPER_BIN=${BIN_DIR}/kismet_cap_cell_capture
Environment=POLL_INTERVAL=5
Environment=LOG_DIR=/var/log/kismet/cell-bridge
ExecStart=${BIN_DIR}/cell_remote_bridge.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2

  install -d /etc/systemd/system/kismet.service.d
  cat > /etc/systemd/system/kismet.service.d/cell-autosetup-order.conf <<'EOF2'
[Unit]
Wants=kismet-cell-autosetup.service
After=kismet-cell-autosetup.service
EOF2

  cat > /etc/systemd/system/kismet.service.d/cell-killmode.conf <<'EOF2'
[Service]
KillMode=control-group
EOF2

  cat > /etc/systemd/system/kismet.service.d/cell-rfkill-unblock.conf <<'EOF2'
[Service]
PermissionsStartOnly=true
ExecStartPre=/bin/sh -c 'command -v rfkill >/dev/null 2>&1 && rfkill unblock all || true'
EOF2

  systemctl daemon-reload
  systemctl disable --now kismet-cell-injector.service 2>/dev/null || true
  systemctl enable --now kismet-cell-autosetup.service kismet-cell-autosetup.timer kismet-cell-bridge.service

  if [[ "${INSTALL_KISMET}" == "1" ]]; then
    systemctl unmask kismet || true
    systemctl enable --now kismet || true
  fi
else
  log "Skipping service installation"
fi

log "Done"
