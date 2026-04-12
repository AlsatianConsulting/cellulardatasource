# Cellular Datasource for Kismet

This project provides a cellular + GPS datasource pipeline from Android phones into Kismet.

It includes:
- Android app (`dev.alsatianconsulting.cellulardatasource`)
- Kismet capture helper (`kismet_cap_cell_capture`)
- Kismet plugin (`cell` PHY + UI panel)
- USB forwarding and service automation for Raspberry Pi/Linux hosts
- Standalone installer flow for a single target device

## What It Collects

When streaming is enabled in the Android app, it collects:
- Cellular metadata:
  - RAT (`LTE`, `NR`, `WCDMA`, `GSM`)
  - MCC/MNC
  - TAC/LAC
  - CID/full cell ID (where available)
  - channel/frequency (`arfcn`, `earfcn`, `nrarfcn`)
  - signal values (`rssi`, `rsrp`, `rsrq`, `snr`, NR SS metrics where supported)
  - serving + neighbor cell records
- GPS/location metadata:
  - latitude/longitude
  - altitude
  - accuracy
  - speed/bearing (if available)
  - satellite count
- Stream health/status metadata:
  - client counts
  - listener status
  - transport status

## How Streaming Works

Phone side:
- JSON telemetry server on `8765`
- NMEA GPS server on `8766`

Host side:
- `adb forward tcp:9875 tcp:8765`
- `adb forward tcp:8766 tcp:8766` (when GPS forwarding is enabled)
- Runtime datasource definitions are generated into:
  - `/var/lib/kismet/cell/sources.generated`

Kismet side:
- Plugin manifest: `/usr/lib/kismet/cell/manifest.conf`
- Plugin binary: `/usr/lib/kismet/cell/cell.so`
- Capture helper: `/usr/bin/kismet_cap_cell_capture`
- Config include path: `/etc/kismet/datasources.d/*.conf`

## Standalone Installer (Single Device)

Primary entrypoint:

```bash
cd ~/cellulardatasource/kismet-cap-cell
sudo ./one
```

`./one` runs `one_shot_install.sh`, which prompts for:
- install Kismet or not
- install services or not
- add cellular datasource or not
- overwrite datasource config fragments or not

You can also run non-interactively:

```bash
sudo ./one_shot_install.sh \
  --install-kismet 1 \
  --install-services 1 \
  --enable-cell-datasource 1 \
  --overwrite-config 1
```

## Service Components

Installed (when services are enabled):
- `kismet-cell-autosetup.service`
- `kismet-cell-autosetup.timer`
- `kismet-cell-bridge.service`

Roles:
- autosetup: discovers connected phones, applies ADB forwards, writes runtime sources
- bridge: keeps capture helper processes connected to Kismet remote capture

## Transport

USB transport is supported.

Toggle command:

```bash
sudo /usr/bin/cell-transport-mode usb
```

## Key Files

- Installer scripts:
  - `one`
  - `one_shot_install.sh`
  - `install.sh`
  - `uninstall.sh`
  - `undo_install.sh`
- Runtime state:
  - `/var/lib/kismet/cell/sources.generated`
  - `/var/lib/kismet/cell/portmap.tsv`
- Kismet config:
  - `/etc/kismet/kismet_site.conf`
  - `/etc/kismet/datasources.d/cell.conf`

## Build Helpers

Build capture helper:

```bash
./build_capture.sh
```

Build package:

```bash
./build_dpkg.sh
```

## Android App

Android source is included in:
- `android-app/`

Package name:
- `dev.alsatianconsulting.cellulardatasource`

## Additional Docs

- End-to-end install: `docs/INSTALL_E2E.md`
- Privacy policy: `docs/PRIVACY_POLICY.md`
- Wiki index: `docs/wiki/INDEX.md`
