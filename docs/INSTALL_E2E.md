# End-to-End Build, Package, Install, and Validation Guide

This is the canonical guide for this project. It merges:
- build from source
- Debian package (`.deb`) build/install
- installer usage (`one`, `one_shot_install.sh`, `install.sh`)
- manual file create/edit lines
- reboot/reconnect validation and troubleshooting

## 1) Prerequisites

- Linux system with `sudo`
- Internet access for dependency packages and Kismet source checkout
- USB cable for Android phone

The installer builds Kismet from the project fork when `--install-kismet 1` is selected:

```text
https://github.com/AlsatianConsulting/kismet.git
```

It does not install Kismet from the Kismet APT repository.
Source installs run Kismet's `make suidinstall` target, which installs Kismet binaries with Kismet's standard elevated-permission model.

Reference source-install validation host:
- `10.0.0.58`

Install base dependencies manually only if you are not using the installer.

Debian / Raspberry Pi OS example:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential pkg-config git curl ca-certificates python3 \
  autoconf automake libtool flex bison \
  protobuf-compiler libprotobuf-dev \
  protobuf-c-compiler libprotobuf-c-dev \
  libcap-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev \
  libmicrohttpd-dev libpcap-dev libnss3-dev libiw-dev libsqlite3-dev \
  zlib1g-dev libnm-dev libavahi-client-dev libusb-1.0-0-dev libudev-dev \
  libpcre2-dev libgnutls28-dev libsensors-dev libssl-dev libdw-dev libelf-dev \
  libncurses-dev libzmq3-dev libftdi1-dev libjansson-dev \
  libwebsockets-dev libbtbb-dev libmosquitto-dev libbluetooth-dev \
  android-tools-adb bluez rfkill iw jq netcat-openbsd usbutils
```

## 2) Clone

```bash
git clone git@github.com:AlsatianConsulting/cellulardatasource.git
cd cellulardatasource
```

## 3) Build From Source

### 3.1 Build capture helper/plugin

```bash
./build_capture.sh
```

Build products:
- `kismet_cap_cell_capture`
- `plugin/cell.so`

### 3.2 Build Android app

Android builds require JDK 17 and an Android SDK with API 34 installed. If Gradle cannot find the SDK, set `ANDROID_HOME` or create `android-app/local.properties` with `sdk.dir=<path-to-sdk>`.

```bash
(cd android-app && ./gradlew assembleDebug)
(cd android-app && ./gradlew assembleRelease)
(cd android-app && ./gradlew bundleRelease)
```

Outputs:
- Debug APK: `android-app/app/build/outputs/apk/debug/app-debug.apk`
- Release APK: `android-app/app/build/outputs/apk/release/app-release.apk`
- Release AAB: `android-app/app/build/outputs/bundle/release/app-release.aab`

Install debug APK:

```bash
adb install -r android-app/app/build/outputs/apk/debug/app-debug.apk
```

## 4) Build and Use Debian Package (`.deb`)

### 4.1 Build package

```bash
./build_dpkg.sh
```

Output:
- `dist/cellulardatasource_<version>_<arch>.deb`

Examples:
- `dist/cellulardatasource_0.1.0_amd64.deb`
- `dist/cellulardatasource_0.1.0_arm64.deb`

### 4.2 Install package

```bash
sudo dpkg -i dist/cellulardatasource_0.1.0_<arch>.deb
sudo apt-get -f install -y
```

Installed tree:
- `/opt/cellulardatasource/kismet-cap-cell`

Convenience commands installed by package:
- `/usr/bin/cellular-datasource-one`

Package behavior:
- Installs project files
- Does not auto-run installers or auto-enable services

## 5) Installer Usage

### 5.1 Primary installer (recommended)

Interactive install:

```bash
sudo ./one
```

Non-interactive examples:

Full install, overwrite config, install services:

```bash
sudo ./one_shot_install.sh \
  --install-kismet 1 \
  --kismet-install-mode source \
  --install-services 1 \
  --enable-cell-datasource 1 \
  --overwrite-config 1
```

Cell datasource only, keep existing config:

```bash
sudo ./one_shot_install.sh \
  --install-kismet 0 \
  --install-services 1 \
  --enable-cell-datasource 1 \
  --overwrite-config 0
```

### 5.2 One-shot installer

```bash
sudo ./one_shot_install.sh --transport usb
```

Main options:
- `--install-kismet 0|1`
- `--kismet-install-mode source|system`
- `--install-services 0|1`
- `--overwrite-config 0|1`
- `--enable-cell-datasource 0|1`
- `--transport usb`
- `--base-port <port>`
- `--gps-port <port>`
- `--forward-gps 0|1`

### 5.3 Low-level installer

```bash
sudo ./install.sh
```

Use this when you need direct control and already manage host/Kismet state.

## 6) Manual Files To Create/Edit (Non-Overwrite Path)

Use this when you choose `--overwrite-config 0` or need manual control.

### 6.1 Create datasource include directory

```bash
sudo install -d /etc/kismet/datasources.d
```

### 6.2 Edit `/etc/kismet/kismet_site.conf`

Required lines:

```text
opt_include=/etc/kismet/datasources.d/*.conf
gps=tcp:host=127.0.0.1,port=8766
```

Add safely (without overwriting file):

```bash
sudo touch /etc/kismet/kismet_site.conf
sudo sed -i '\|^plugin=/usr/lib/kismet/cell/manifest\.conf$|d' /etc/kismet/kismet_site.conf
grep -q '^opt_include=/etc/kismet/datasources.d/\*\.conf$' /etc/kismet/kismet_site.conf || \
  echo 'opt_include=/etc/kismet/datasources.d/*.conf' | sudo tee -a /etc/kismet/kismet_site.conf
grep -q '^gps=tcp:host=127.0.0.1,port=8766$' /etc/kismet/kismet_site.conf || \
  echo 'gps=tcp:host=127.0.0.1,port=8766' | sudo tee -a /etc/kismet/kismet_site.conf
```

### 6.3 Create/Edit `/etc/kismet/datasources.d/cell.conf`

Managed placeholder:

```text
# Managed by cell_autoconfig.sh
# Runtime cell sources are bridged by kismet-cell-bridge.service.
```

Write placeholder:

```bash
cat <<'EOF' | \
  sudo tee /etc/kismet/datasources.d/cell.conf >/dev/null
# Managed by cell_autoconfig.sh
# Runtime cell sources are bridged by kismet-cell-bridge.service.
EOF
```

### 6.4 Ensure Kismet startup ordering drop-in

Create `/etc/systemd/system/kismet.service.d/cell-autosetup-order.conf`:

```ini
[Unit]
Wants=kismet-cell-autosetup.service
After=kismet-cell-autosetup.service
```

Command:

```bash
sudo install -d /etc/systemd/system/kismet.service.d
sudo tee /etc/systemd/system/kismet.service.d/cell-autosetup-order.conf >/dev/null <<'EOF'
[Unit]
Wants=kismet-cell-autosetup.service
After=kismet-cell-autosetup.service
EOF
```

## 7) Verify Kismet Data

After the app is streaming and the services are running, verify the attached
cell source and GPS path:

```bash
sudo systemctl status kismet --no-pager
sudo systemctl status kismet-cell-autosetup.timer --no-pager
sudo systemctl status kismet-cell-bridge.service --no-pager
sudo journalctl -u kismet-cell-autosetup.service -n 120 --no-pager
sudo journalctl -u kismet-cell-bridge.service -n 120 --no-pager
adb devices
adb forward --list
```
