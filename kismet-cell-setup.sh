#!/usr/bin/env bash
set -euo pipefail
umask 022

log() { printf '[*] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID:-0} -ne 0 ]]; then
  die "Run as root (sudo /home/user/kismet-cell-setup.sh)."
fi

RUN_USER="${SUDO_USER:-${USER:-root}}"
USER_HOME="$(getent passwd "${RUN_USER}" | awk -F: '{print $6}')"
if [[ -z "${USER_HOME}" ]]; then
  die "Unable to resolve home directory for ${RUN_USER}."
fi
RUN_GROUP="$(id -gn "${RUN_USER}")"
RUN_UID="$(id -u "${RUN_USER}")"
RUN_GID="$(id -g "${RUN_USER}")"
if [[ -z "${RUN_GROUP}" ]]; then
  die "Unable to resolve group for ${RUN_USER}."
fi

if command -v runuser >/dev/null 2>&1; then
  AS_USER_PREFIX=(runuser -u "${RUN_USER}" -- env HOME="${USER_HOME}" USER="${RUN_USER}" LOGNAME="${RUN_USER}")
elif command -v sudo >/dev/null 2>&1; then
  AS_USER_PREFIX=(sudo -u "${RUN_USER}" -- env HOME="${USER_HOME}" USER="${RUN_USER}" LOGNAME="${RUN_USER}")
else
  die "runuser or sudo is required to run commands as ${RUN_USER}."
fi

as_user() {
  if [[ "${RUN_USER}" == "root" ]]; then
    "$@"
  else
    "${AS_USER_PREFIX[@]}" "$@"
  fi
}

write_file() {
  local dest="$1"
  local mode="$2"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}"
  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    rm -f "${tmp}"
  else
    install -m "${mode}" "${tmp}" "${dest}"
  fi
}

fix_ownership() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    local cur_uid cur_gid
    cur_uid="$(stat -c '%u' "${path}")"
    cur_gid="$(stat -c '%g' "${path}")"
    if [[ "${cur_uid}" != "${RUN_UID}" || "${cur_gid}" != "${RUN_GID}" ]]; then
      chown -R "${RUN_USER}:${RUN_GROUP}" "${path}"
    fi
  fi
}

choose_pkg() {
  local p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

PREFIX="/usr/local"
SYSCONFDIR="${PREFIX}/etc"
SRC_DIR="${USER_HOME}/src"
KISMET_SRC="${SRC_DIR}/kismet"
CELL_SRC="${SRC_DIR}/cellulardatasource"
KISMET_REPO="https://github.com/kismetwireless/kismet.git"
CELL_REPO="https://github.com/AlsatianConsulting/cellulardatasource"

APT_PKGS=(
  build-essential
  git
  pkg-config
  autoconf
  automake
  libtool
  libdw-dev
  libnm-dev
  libpcap-dev
  libnl-3-dev
  libnl-genl-3-dev
  libcap-dev
  libssl-dev
  zlib1g-dev
  libprotobuf-c-dev
  libprotobuf-dev
  protobuf-compiler
  protobuf-c-compiler
  libwebsockets-dev
  libsqlite3-dev
  libusb-1.0-0-dev
  libsystemd-dev
  libreadline-dev
  libexpat1-dev
  libubertooth-dev
  libbtbb-dev
  libmosquitto-dev
  librtlsdr-dev
  rtl-433
  python3
  python3-dev
  python3-setuptools
  python3-protobuf
  python3-requests
  python3-numpy
  python3-serial
  python3-usb
  python3-websockets
  android-sdk-platform-tools
)

log "Installing packages"
apt-get update
PKG_NCURSES="$(choose_pkg libncurses-dev libncurses5-dev)" || die "No ncurses dev package found."
PKG_SENSORS="$(choose_pkg libsensors-dev libsensors4-dev)" || die "No libsensors dev package found."
PKG_PCRE="$(choose_pkg libpcre2-dev libpcre3-dev)" || die "No PCRE dev package found."
APT_PKGS+=("${PKG_NCURSES}" "${PKG_SENSORS}" "${PKG_PCRE}")
apt-get install -y "${APT_PKGS[@]}"

if [[ ! -d "${SRC_DIR}" ]]; then
  install -d -m 755 -o "${RUN_USER}" -g "${RUN_GROUP}" "${SRC_DIR}"
else
  chown "${RUN_USER}:${RUN_GROUP}" "${SRC_DIR}"
  chmod 755 "${SRC_DIR}"
fi
install -d -m 755 "${PREFIX}/bin"
install -d -m 755 "${SYSCONFDIR}"

fix_ownership "${KISMET_SRC}"
fix_ownership "${CELL_SRC}"

if [[ ! -d "${KISMET_SRC}/.git" ]]; then
  log "Cloning Kismet"
  as_user git clone "${KISMET_REPO}" "${KISMET_SRC}"
fi

log "Fetching Kismet tags"
as_user git -C "${KISMET_SRC}" fetch --tags --prune
LATEST_TAG="$(as_user git -C "${KISMET_SRC}" tag --list 'kismet-20*' | sort -V | tail -n 1)"
if [[ -z "${LATEST_TAG}" ]]; then
  LATEST_TAG="$(as_user git -C "${KISMET_SRC}" tag --list 'kismet-*' | grep -v '^kismet-old' | sort -V | tail -n 1)"
fi
if [[ -z "${LATEST_TAG}" ]]; then
  die "No Kismet release tags found."
fi
log "Using Kismet tag: ${LATEST_TAG}"
as_user git -C "${KISMET_SRC}" checkout -f "${LATEST_TAG}"

log "Configuring Kismet"
as_user bash -c "cd \"${KISMET_SRC}\" && ./configure --prefix=\"${PREFIX}\" --sysconfdir=\"${SYSCONFDIR}\" --with-suidgroup=root"

log "Building Kismet (single core)"
as_user bash -c "cd \"${KISMET_SRC}\" && make"

log "Installing Kismet"
bash -c "cd \"${KISMET_SRC}\" && make install INSTUSR=root INSTGRP=root SUIDGROUP=root"
ldconfig

if [[ ! -d "${CELL_SRC}/.git" ]]; then
  log "Cloning cellular datasource repo"
  as_user git clone "${CELL_REPO}" "${CELL_SRC}"
else
  log "Cellular datasource repo already exists; leaving as-is"
fi

log "Building kismet_cap_cell_capture"
as_user bash -c "cd \"${CELL_SRC}\" && \
  cc -Ivendor -Ivendor/protobuf_c_1005000 \
  capture_cell.c \
  vendor/capture_framework.c \
  vendor/simple_ringbuf_c.c \
  vendor/kis_external_packet.c \
  vendor/mpack/mpack.c \
  vendor/version_stub.c \
  vendor/protobuf_c_1005000/*.c \
  -lpthread -lprotobuf-c -o kismet_cap_cell_capture"
install -m 755 "${CELL_SRC}/kismet_cap_cell_capture" "${PREFIX}/bin/kismet_cap_cell_capture"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

log "Building Kismet cell plugin"
as_user make -C "${CELL_SRC}/plugin" KIS_SRC_DIR="${KISMET_SRC}"
log "Installing Kismet cell plugin"
make -C "${CELL_SRC}/plugin" KIS_SRC_DIR="${KISMET_SRC}" install

log "Installing autosetup script"
write_file "${PREFIX}/bin/kismet-cell-autosetup" 755 <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MULTI_PHONE="/home/user/src/cellulardatasource/multi_phone.sh"
SITE_CONF="/usr/local/etc/kismet_site.conf"
BASE_PORT="9875"
PREFIX="/usr/local"

MARK_BEGIN="# BEGIN CELL SOURCES (auto)"
MARK_END="# END CELL SOURCES (auto)"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found; skipping cell autosetup" >&2
  exit 0
fi

if [[ ! -x "${MULTI_PHONE}" ]]; then
  echo "multi_phone.sh not found or not executable at ${MULTI_PHONE}" >&2
  exit 1
fi

adb start-server >/dev/null 2>&1 || true

TMP_SOURCES="$(mktemp)"
TMP_CONF="$(mktemp)"
trap 'rm -f "${TMP_SOURCES}" "${TMP_CONF}"' EXIT

"${MULTI_PHONE}" --base-port "${BASE_PORT}" --prefix "${PREFIX}" --out "${TMP_SOURCES}"

if [[ -f "${SITE_CONF}" ]]; then
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0 == b { inside=1; next }
    $0 == e { inside=0; next }
    /^source=cell:/ { next }
    { if (!inside) print }
  ' "${SITE_CONF}" > "${TMP_CONF}"
else
  : > "${TMP_CONF}"
fi

{
  echo "${MARK_BEGIN}"
  if [[ -s "${TMP_SOURCES}" ]]; then
    cat "${TMP_SOURCES}"
  else
    echo "# (no devices detected)"
  fi
  echo "${MARK_END}"
} >> "${TMP_CONF}"

if [[ -f "${SITE_CONF}" ]] && cmp -s "${SITE_CONF}" "${TMP_CONF}"; then
  exit 0
fi

install -m 644 "${TMP_CONF}" "${SITE_CONF}"

systemctl try-restart kismet >/dev/null 2>&1 || true
EOS

log "Installing systemd units"
write_file "/etc/systemd/system/kismet.service" 644 <<'EOS'
[Unit]
Description=Kismet
ConditionPathExists=/usr/local/bin/kismet
After=network.target auditd.service

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/kismet --no-ncurses-wrapper
KillMode=process
TimeoutSec=0
Restart=always

[Install]
WantedBy=multi-user.target
EOS

write_file "/etc/systemd/system/kismet-cell-autosetup.service" 644 <<'EOS'
[Unit]
Description=Kismet cell datasource autosetup (ADB forwarding + sources)
After=network.target
ConditionPathExists=/usr/local/bin/kismet
ConditionPathExists=/usr/bin/adb

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kismet-cell-autosetup

[Install]
WantedBy=multi-user.target
EOS

write_file "/etc/systemd/system/kismet-cell-autosetup.timer" 644 <<'EOS'
[Unit]
Description=Periodic Kismet cell datasource autosetup

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
EOS

install -d -m 755 /etc/systemd/system/kismet-cell-autosetup.service.d
write_file "/etc/systemd/system/kismet-cell-autosetup.service.d/override.conf" 644 <<'EOS'
[Service]
KillMode=process
EOS

log "Configuring GPS"
TMP_GPS="$(mktemp)"
if [[ -f "${SYSCONFDIR}/kismet_site.conf" ]]; then
  awk 'BEGIN{added=0} /^gps=/{next} {print} END{print "gps=tcp:host=127.0.0.1,port=8766"}' \
    "${SYSCONFDIR}/kismet_site.conf" > "${TMP_GPS}"
else
  printf 'gps=tcp:host=127.0.0.1,port=8766\n' > "${TMP_GPS}"
fi
install -m 644 "${TMP_GPS}" "${SYSCONFDIR}/kismet_site.conf"
rm -f "${TMP_GPS}"

log "Enabling persistent journaling"
install -d -m 755 /etc/systemd/journald.conf.d
write_file "/etc/systemd/journald.conf.d/persistent.conf" 644 <<'EOS'
[Journal]
Storage=persistent
EOS
install -d -m 2755 -o root -g systemd-journal "/var/log/journal/$(cat /etc/machine-id)"
systemctl restart systemd-journald
journalctl --flush || true

log "Reloading systemd"
systemctl daemon-reload

log "Enabling services"
systemctl enable --now kismet.service
systemctl enable --now kismet-cell-autosetup.timer
systemctl start kismet-cell-autosetup.service || true

log "Done"
log "Check status: systemctl status kismet kismet-cell-autosetup.timer"
log "Check forwards: adb forward --list"
log "Check logs: journalctl -u kismet -b | tail -n 50"
