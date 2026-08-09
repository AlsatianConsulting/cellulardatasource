# Cellular Datasource for Kismet

<a href="https://play.google.com/store/apps/details?id=dev.alsatianconsulting.cellulardatasource"><img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" alt="Get it on Google Play" height="80"></a>

CellularDatasource streams Android cellular tower observations and GPS fixes into Kismet using an attached USB connection.

The project contains:
- Android app: `dev.alsatianconsulting.cellulardatasource`
- Kismet external capture helper: `kismet_cap_cell_capture`
- Kismet plugin: `cell` PHY and `Cell Info` device detail panel
- Raspberry Pi/Linux installer and systemd automation
- Optional collector/export utility for JSONL, CSV, SQLite, KML, and GPX outputs

## What It Collects

When the Android foreground service is running, the app can collect:
- Cellular RAT: `LTE`, `NR`, `WCDMA`, `GSM`
- MCC/MNC
- TAC/LAC
- CID/full cell ID/NCI where Android exposes it
- ARFCN/EARFCN/NRARFCN/UARFCN
- PCI/PSC
- Signal values such as RSSI, RSRP, RSRQ, RSSNR, NR SS/CSI metrics where supported
- Registered/neighbor cell state
- GPS latitude/longitude
- GPS altitude, accuracy, speed, bearing, provider, and satellite count where available
- Attached stream health such as connected client counts and listener status

The app uses Android telephony and location APIs. It does not use monitor mode, does not scan Wi-Fi, and does not scan Bluetooth.

##Screenshots
**App UI** 
<img width="1080" height="2340" alt="App_UI" src="https://github.com/user-attachments/assets/adda544a-3729-4892-9c89-4b403b947591" />
**Kismet UI**
<img width="508" height="1147" alt="Kismet_UI" src="https://github.com/user-attachments/assets/4be3150f-ecef-4067-ba61-8bc130ded4c0" />



## How Streaming Works

Phone side:
- Cell JSON server: `localabstract:cellstream_data` (Android abstract UNIX socket)
- GPS NMEA server: `localabstract:cellstream_nmea` (Android abstract UNIX socket)
- Foreground notification shows `Streaming Cell`, `Streaming GPS`, `Streaming Cell+GPS`, or `Not Streaming`

Host side:
- `adb forward tcp:9875 localabstract:cellstream_data`
- `adb forward tcp:8766 localabstract:cellstream_nmea` when GPS forwarding is enabled
- Runtime datasource definitions are generated into `/var/lib/kismet/cell/sources.generated`

Kismet side:
- Plugin manifest: `/usr/lib/kismet/cell/manifest.conf`
- Plugin binary: `/usr/lib/kismet/cell/cell.so`
- Capture helper: `/usr/bin/kismet_cap_cell_capture`
- Config include path: `/etc/kismet/datasources.d/*.conf`
- Cell towers appear as Kismet `CELL` devices with a `Cell Info` detail panel
- Phone GPS is forwarded to Kismet as TCP NMEA

## Install

Primary entrypoint (run from the repository root):

```bash
sudo ./one
```

`./one` runs `one_shot_install.sh`, which prompts for:
- install Kismet or not
- install services or not
- add cellular datasource or not
- overwrite datasource config fragments or not

Non-interactive full source install:

```bash
sudo ./one_shot_install.sh \
  --install-kismet 1 \
  --kismet-install-mode source \
  --install-services 1 \
  --enable-cell-datasource 1 \
  --overwrite-config 1
```

When Kismet is selected for installation, the installer builds from the project fork at `https://github.com/AlsatianConsulting/kismet.git`. It uses the local OS package manager only for build/runtime dependencies, not for installing Kismet from a Kismet APT repository.

Cell datasource only, preserving existing Kismet config:

```bash
sudo ./one_shot_install.sh \
  --install-kismet 0 \
  --install-services 1 \
  --enable-cell-datasource 1 \
  --overwrite-config 0
```

## Android App

Source lives in `android-app/`.

Build a debug APK:

```bash
cd android-app
./gradlew assembleDebug
```

Install to an attached phone:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

On the phone:
- open `CellularDatasource`
- grant location, background location, phone state, and notification permissions when prompted
- enable `Stream cellular towers` and `Stream GPS location` in Settings
- tap `Start Stream`
- allow USB debugging from the Pi/Linux host

Build a signed release APK:

```bash
cd android-app
./gradlew assembleRelease \
  -Pandroid.injected.signing.store.file=$HOME/Documents/dev/keys/cellulardatasource.jks \
  -Pandroid.injected.signing.store.password=<store-password> \
  -Pandroid.injected.signing.key.alias=<key-alias> \
  -Pandroid.injected.signing.key.password=<key-password>
```

Output: `app/build/outputs/apk/release/app-release.apk`

Install the signed APK:

```bash
adb install -r app/build/outputs/apk/release/app-release.apk
```

## Services

Installed when services are enabled:
- `kismet-cell-autosetup.service`
- `kismet-cell-autosetup.timer`
- `kismet-cell-bridge.service`

Roles:
- `kismet-cell-autosetup`: discovers attached phones, applies ADB forwards, writes source state
- `kismet-cell-autosetup.timer`: periodically re-runs autosetup so reconnects recover
- `kismet-cell-bridge`: supervises capture helpers and keeps them connected to Kismet remote capture

Useful checks:

```bash
systemctl status kismet --no-pager
systemctl status kismet-cell-autosetup.timer --no-pager
systemctl status kismet-cell-bridge.service --no-pager
journalctl -u kismet-cell-autosetup.service -n 120 --no-pager
journalctl -u kismet-cell-bridge.service -n 120 --no-pager
adb devices
adb forward --list
```

## Collector And Exports

`collector.py` is optional and separate from Kismet. It discovers ADB-connected phones, forwards the phone JSON stream, and writes flattened records.

Example:

```bash
python3 collector.py \
  --jsonl capture.jsonl \
  --csv capture.csv \
  --kml capture.kml \
  --gpx capture.gpx \
  --sqlite capture.sqlite
```

Records include device ID, GPS fields, cell identity fields, signal fields, and derived LTE band/frequency fields when possible.

## Key Files

- `one`: convenience installer wrapper
- `one_shot_install.sh`: prompted/non-interactive installer
- `install.sh`: low-level installer
- `uninstall.sh`: removes installed components
- `undo_install.sh`: reverts installer-managed changes
- `cell_autoconfig.sh`: ADB forwarding and datasource generation
- `cell_remote_bridge.py`: remote-capture helper supervisor
- `capture_cell.c`: Kismet external capture helper source
- `plugin/cell_plugin.cc`: Kismet `CELL` PHY and datasource plugin
- `plugin/httpd/js/kismet.ui.cell.js`: Kismet `Cell Info` panel
- `SCHEMA.md`: JSON field reference

## Build Helpers

Build capture helper:

```bash
./build_capture.sh
```

Build Debian package:

```bash
./build_dpkg.sh
```

## Additional Docs

- End-to-end install: `docs/INSTALL_E2E.md`
- Privacy policy: `docs/PRIVACY_POLICY.md`
- Wiki index: `docs/wiki/INDEX.md`
