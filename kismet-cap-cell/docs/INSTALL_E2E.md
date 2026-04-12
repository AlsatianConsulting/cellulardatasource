# End-to-End Build, Package, Install, and Validation Guide

This is the canonical guide for this project. It merges:
- build from source
- Debian package (`.deb`) build/install
- installer usage (`one`, `one_shot_install.sh`, `install.sh`, `pi_one_command_setup.sh`)
- manual file create/edit lines
- reboot/reconnect validation and troubleshooting

## 1) Prerequisites

- Debian/Raspberry Pi OS with `sudo`
- Internet access for apt packages
- USB cable for Android phone
- Optional hardware:
  - monitor-mode Wi-Fi adapter

Install base dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential pkg-config cmake git \
  protobuf-c-compiler libprotobuf-c-dev \
  libsqlite3-dev \
  adb jq netcat-openbsd
```

If using full Kismet stack:

```bash
sudo apt-get install -y \
  kismet kismet-core kismet-logtools \
  kismet-capture-linux-wifi
```

## 2) Clone

```bash
git clone git@github.com:AlsatianConsulting/cellulardatasource.git
cd cellulardatasource
```

## 3) Build From Source

### 3.1 Build capture helper/plugin

```bash
cd kismet-cap-cell
./build_capture.sh
```

Build products:
- `kismet_cap_cell_capture`
- `plugin/cell.so`

### 3.2 Build Android app

```bash
cd android-app
./gradlew assembleDebug
./gradlew assembleRelease
./gradlew bundleRelease
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
cd kismet-cap-cell
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
- `/usr/bin/cellular-datasource-pi-setup`

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
sudo ./one --mode full --install-services 1 --overwrite-config 1 --transport usb
```

Cell datasource only, keep existing config:

```bash
sudo ./one --mode cell-only --install-services 1 --overwrite-config 0 --transport usb
```

### 5.2 One-shot installer

```bash
sudo ./one_shot_install.sh --transport usb
```

Main options:
- `--mode full|cell-only`
- `--install-services 0|1`
- `--overwrite-config 0|1`
- `--install-kismet 0|1`
- `--transport usb`
- `--base-port <port>`
- `--gps-port <port>`
- `--forward-gps 0|1`

### 5.3 Low-level installer

```bash
sudo ./install.sh
```

Use this when you need direct control and already manage host/Kismet state.

### 5.4 Pi profile installer

```bash
sudo ./pi_one_command_setup.sh
```

By default this configures Pi capture sources (`wifi`) and can include the cell stack.

## 6) Manual Files To Create/Edit (Non-Overwrite Path)

Use this when you choose `--overwrite-config 0` or need manual control.

### 6.1 Create datasource include directory

```bash
sudo install -d /etc/kismet/datasources.d
```

### 6.2 Edit `/etc/kismet/kismet_site.conf`

Required lines:

```text
plugin=/usr/lib/kismet/cell/manifest.conf
opt_include=/etc/kismet/datasources.d/*.conf
gps=enabled
gps=tcp:host=127.0.0.1,port=8766
```

Add safely (without overwriting file):

```bash
sudo touch /etc/kismet/kismet_site.conf
grep -q '^plugin=/usr/lib/kismet/cell/manifest.conf$' /etc/kismet/kismet_site.conf || \
  echo 'plugin=/usr/lib/kismet/cell/manifest.conf' | sudo tee -a /etc/kismet/kismet_site.conf
grep -q '^opt_include=/etc/kismet/datasources.d/\*\.conf$' /etc/kismet/kismet_site.conf || \
  echo 'opt_include=/etc/kismet/datasources.d/*.conf' | sudo tee -a /etc/kismet/kismet_site.conf
grep -q '^gps=enabled$' /etc/kismet/kismet_site.conf || \
  echo 'gps=enabled' | sudo tee -a /etc/kismet/kismet_site.conf
grep -q '^gps=tcp:host=127.0.0.1,port=8766$' /etc/kismet/kismet_site.conf || \
  echo 'gps=tcp:host=127.0.0.1,port=8766' | sudo tee -a /etc/kismet/kismet_site.conf
```

### 6.3 Create/Edit `/etc/kismet/datasources.d/cell.conf`

USB example:

```text
source=cell:name=cell-1,type=cell,interface=tcp://127.0.0.1:9875
```

Write USB example:

```bash
echo 'source=cell:name=cell-1,type=cell,interface=tcp://127.0.0.1:9875' | \
  sudo tee /etc/kismet/datasources.d/cell.conf >/dev/null
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
