#!/usr/bin/env bash
# Install cellular datasource components for Kismet.
# This installer is intentionally single-device focused for attached cell/GPS streaming.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

PREFIX="${PREFIX:-/usr}"
MAKE_JOBS="${MAKE_JOBS:-1}"
WITH_COLLECTOR="${WITH_COLLECTOR:-0}"
INSTALL_SERVICES="${INSTALL_SERVICES:-ask}"   # ask|0|1
INSTALL_KISMET="${INSTALL_KISMET:-ask}"       # ask|0|1
KISMET_INSTALL_MODE="${KISMET_INSTALL_MODE:-source}" # source|system
KISMET_SOURCE_URL="${KISMET_SOURCE_URL:-https://github.com/AlsatianConsulting/kismet.git}"
KISMET_SOURCE_REF="${KISMET_SOURCE_REF:-master}"
KISMET_BUILD_ROOT="${KISMET_BUILD_ROOT:-/usr/local/src}"
KISMET_SOURCE_DIR="${KISMET_SOURCE_DIR:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PREFIX}/bin"
PKG_MANAGER=""

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

detect_pkg_manager() {
  if [[ -n "${PKG_MANAGER}" ]]; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  else
    PKG_MANAGER="none"
  fi
}

pkg_update() {
  detect_pkg_manager
  case "${PKG_MANAGER}" in
    apt) apt-get update ;;
    dnf|yum) ;;
    zypper) zypper --gpg-auto-import-keys refresh ;;
    pacman) pacman -Sy --noconfirm ;;
    apk) apk update ;;
    none) return 0 ;;
    *) echo "Unsupported package manager: ${PKG_MANAGER}" >&2; exit 1 ;;
  esac
}

pkg_install() {
  detect_pkg_manager
  if [[ $# -eq 0 ]]; then
    return 0
  fi

  case "${PKG_MANAGER}" in
    apt) apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
    apk) apk add --no-cache "$@" ;;
    none)
      echo "No supported package manager found; install dependencies manually: $*" >&2
      exit 1
      ;;
    *)
      echo "Unsupported package manager: ${PKG_MANAGER}" >&2
      exit 1
      ;;
  esac
}

install_runtime_and_build_deps() {
  detect_pkg_manager
  log "Installing build/runtime dependencies via ${PKG_MANAGER}"
  pkg_update

  case "${PKG_MANAGER}" in
    apt)
      pkg_install \
        build-essential pkg-config git curl ca-certificates python3 \
        autoconf automake libtool flex bison \
        protobuf-compiler libprotobuf-dev \
        libprotobuf-c-dev protobuf-c-compiler libcap-dev \
        libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
        libmicrohttpd-dev libpcap-dev libnss3-dev libiw-dev libsqlite3-dev \
        zlib1g-dev libnm-dev libavahi-client-dev libusb-1.0-0-dev libudev-dev \
        libpcre2-dev libgnutls28-dev libsensors-dev libssl-dev libdw-dev libelf-dev \
        libncurses-dev libzmq3-dev libftdi1-dev libjansson-dev \
        libwebsockets-dev libbtbb-dev libmosquitto-dev libbluetooth-dev \
        android-tools-adb bluez rfkill iw jq netcat-openbsd usbutils
      ;;
    dnf)
      pkg_install \
        gcc gcc-c++ make pkgconf-pkg-config git curl ca-certificates python3 \
        autoconf automake libtool flex bison \
        protobuf-devel protobuf-compiler protobuf-c-devel protobuf-c-compiler \
        libcap-devel libnl3-devel libpcap-devel nss-devel wireless-tools-devel \
        sqlite-devel zlib-devel NetworkManager-libnm-devel avahi-devel \
        libusb1-devel systemd-devel pcre2-devel gnutls-devel lm_sensors-devel \
        openssl-devel elfutils-devel ncurses-devel zeromq-devel libftdi-devel \
        jansson-devel libwebsockets-devel libbtbb-devel mosquitto-devel \
        bluez-libs-devel bluez jq nmap-ncat usbutils android-tools iw rfkill
      ;;
    yum)
      pkg_install \
        gcc gcc-c++ make pkgconfig git curl ca-certificates python3 \
        autoconf automake libtool flex bison \
        protobuf-devel protobuf-compiler protobuf-c-devel \
        libcap-devel libnl3-devel libpcap-devel nss-devel wireless-tools-devel \
        sqlite-devel zlib-devel NetworkManager-libnm-devel avahi-devel \
        libusb1-devel systemd-devel pcre2-devel gnutls-devel lm_sensors-devel \
        openssl-devel elfutils-devel ncurses-devel zeromq-devel libftdi-devel \
        jansson-devel libwebsockets-devel mosquitto-devel bluez-libs-devel \
        bluez jq nmap-ncat usbutils android-tools iw
      ;;
    zypper)
      pkg_install \
        gcc gcc-c++ make pkg-config git curl ca-certificates python3 \
        autoconf automake libtool flex bison \
        protobuf-devel protobuf-c-devel libcap-devel libnl3-devel libpcap-devel \
        mozilla-nss-devel wireless-tools sqlite3-devel zlib-devel \
        NetworkManager-devel avahi-devel libusb-1_0-devel systemd-devel \
        pcre2-devel gnutls-devel sensors libopenssl-devel elfutils-devel \
        ncurses-devel zeromq-devel libftdi1-devel libjansson-devel \
        libwebsockets-devel mosquitto-devel bluez-devel jq netcat-openbsd usbutils iw
      ;;
    pacman)
      pkg_install \
        base-devel pkgconf git curl ca-certificates python \
        autoconf automake libtool flex bison \
        protobuf protobuf-c libcap libnl libpcap nss iw sqlite zlib networkmanager \
        avahi libusb systemd pcre2 gnutls lm_sensors openssl elfutils ncurses \
        zeromq libftdi jansson libwebsockets mosquitto bluez bluez-utils \
        android-tools jq openbsd-netcat usbutils rfkill
      ;;
    apk)
      pkg_install \
        alpine-sdk pkgconf git curl ca-certificates python3 \
        autoconf automake libtool flex bison \
        protobuf-dev protobuf-c-dev libcap-dev libnl3-dev libpcap-dev nss-dev \
        wireless-tools-dev sqlite-dev zlib-dev networkmanager-dev avahi-dev \
        libusb-dev eudev-dev pcre2-dev gnutls-dev lm-sensors-dev openssl-dev \
        elfutils-dev ncurses-dev zeromq-dev libftdi1-dev jansson-dev \
        libwebsockets-dev mosquitto-dev bluez-dev bluez usbutils iw jq
      ;;
    none)
      log "No supported package manager detected; assuming dependencies are preinstalled"
      ;;
  esac
}

kismet_source_checkout_dir() {
  if [[ -n "${KISMET_SOURCE_DIR}" ]]; then
    printf '%s\n' "${KISMET_SOURCE_DIR}"
  else
    printf '%s\n' "${KISMET_BUILD_ROOT}/kismet"
  fi
}

systemd_unit_dir() {
  local d
  for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
    if [[ -d "${d}" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
  done
  printf '/etc/systemd/system\n'
}

install_kismet_systemd_unit() {
  local src_dir="$1"
  local unit_dir
  unit_dir="$(systemd_unit_dir)"

  if [[ -f "${src_dir}/packaging/systemd/kismet.service" ]]; then
    install -m 644 "${src_dir}/packaging/systemd/kismet.service" "${unit_dir}/kismet.service"
  fi
}

build_and_install_kismet_from_source() {
  local src_dir
  src_dir="$(kismet_source_checkout_dir)"
  install -d "$(dirname "${src_dir}")"

  if [[ ! -d "${src_dir}/.git" ]]; then
    log "Cloning Kismet source from ${KISMET_SOURCE_URL}"
    git clone "${KISMET_SOURCE_URL}" "${src_dir}"
  fi

  log "Updating Kismet source checkout (${KISMET_SOURCE_REF})"
  git -C "${src_dir}" fetch --tags origin
  git -C "${src_dir}" checkout -f "${KISMET_SOURCE_REF}"
  if git -C "${src_dir}" rev-parse --verify "origin/${KISMET_SOURCE_REF}" >/dev/null 2>&1; then
    log "Resetting installer-managed Kismet checkout to origin/${KISMET_SOURCE_REF}; local changes under ${src_dir} will be discarded"
    git -C "${src_dir}" reset --hard "origin/${KISMET_SOURCE_REF}"
  fi

  pushd "${src_dir}" >/dev/null
  log "Configuring Kismet source build"
  ./configure --prefix="${PREFIX}" --sysconfdir=/etc --localstatedir=/var
  log "Building Kismet from source"
  make -j"${MAKE_JOBS}"
  log "Installing Kismet from source"
  log "Running Kismet make suidinstall; this installs Kismet with its standard elevated-permission binaries"
  make suidinstall
  popd >/dev/null

  install_kismet_systemd_unit "${src_dir}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
  fi
}

append_line_if_missing() {
  local file="$1"
  local line="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '%s\n' "${line}" >> "${file}"
  fi
}

detect_kismet_site_conf() {
  if [[ -n "${KISMET_SITE_CONF:-}" ]]; then
    printf '%s\n' "${KISMET_SITE_CONF}"
  elif [[ -f /etc/kismet.conf || -f /etc/kismet_site.conf ]]; then
    printf '%s\n' "/etc/kismet_site.conf"
  else
    printf '%s\n' "/etc/kismet/kismet_site.conf"
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

remove_legacy_network_survey() {
  log "Removing legacy network-survey bridge components"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now kismet-network-survey-bridge.service 2>/dev/null || true
  fi
  pkill -f '[n]etwork_survey_bridge.py' 2>/dev/null || true
  rm -f \
    /etc/systemd/system/kismet-network-survey-bridge.service \
    /usr/lib/systemd/system/kismet-network-survey-bridge.service \
    /lib/systemd/system/kismet-network-survey-bridge.service \
    "${BIN_DIR}/network_survey_bridge.py"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
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

resolve_toggle INSTALL_KISMET "Install Kismet from source now?"
resolve_toggle INSTALL_SERVICES "Install and enable systemd services now?"

install_runtime_and_build_deps
remove_legacy_network_survey

if [[ "${INSTALL_KISMET}" == "1" ]]; then
  case "${KISMET_INSTALL_MODE}" in
    source) build_and_install_kismet_from_source ;;
    system) log "Skipping Kismet source build; expecting an existing system Kismet install" ;;
    *)
      echo "KISMET_INSTALL_MODE must be source or system (got: ${KISMET_INSTALL_MODE})" >&2
      exit 1
      ;;
  esac
else
  log "Skipping Kismet installation"
fi

log "Building capture helper"
pushd "${SCRIPT_DIR}" >/dev/null
./build_capture.sh
popd >/dev/null

KIS_SRC_DIR=""
for cand in "$(kismet_source_checkout_dir)" /usr/local/src/kismet /usr/local/src/kismet-* /usr/src/kismet /usr/src/kismet-* /opt/kismet /opt/kismet-*; do
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
make clean
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
install -m 755 "${SCRIPT_DIR}/cell_remote_bridge.py" "${BIN_DIR}/cell_remote_bridge.py"
install -m 755 "${SCRIPT_DIR}/cell_transport_toggle.sh" "${BIN_DIR}/cell_transport_toggle.sh"
install -m 755 "${SCRIPT_DIR}/uds_forwarder.py" "${BIN_DIR}/uds_forwarder.py"
ln -sf "${BIN_DIR}/cell_transport_toggle.sh" "${BIN_DIR}/cell-transport-mode"

if [[ "${WITH_COLLECTOR}" == "1" ]]; then
  install -m 755 "${SCRIPT_DIR}/collector.py" "${BIN_DIR}/collector.py"
fi

log "Seeding Kismet config fragments"
SITE_CONF="$(detect_kismet_site_conf)"
CELL_CONF="/etc/kismet/datasources.d/cell.conf"

install -d "$(dirname "${SITE_CONF}")" /etc/kismet/datasources.d
touch "${SITE_CONF}"
sed -i '\|^plugin=/usr/lib/kismet/cell/manifest\.conf$|d' "${SITE_CONF}"
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
Environment=ADB_LIBUSB=1
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
After=network.target kismet.service
Wants=kismet.service

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
