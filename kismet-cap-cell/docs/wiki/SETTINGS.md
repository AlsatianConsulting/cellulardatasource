# Settings Reference

## Installer options (`./one` / `./one_shot_install.sh`)

- `--mode full|cell-only`
  - `full`: installs Kismet and helper capture packages, plus cell stack
  - `cell-only`: installs only cell stack and leaves existing Kismet install

- `--install-services 0|1`
  - `1`: installs/enables autosetup services
  - `0`: skips service units

- `--overwrite-config 0|1`
  - `1`: rewrites:
    - `/etc/kismet/kismet_site.conf`
    - `/etc/kismet/datasources.d/cell.conf`
  - `0`: does not overwrite; prints exact manual lines to add

- `--install-kismet 0|1`
  - controls Kismet package installation via apt

- `--transport usb`
  - controls datasource generation transport behavior

- `--base-port <port>`
  - host TCP start port for phone stream forwards (default `9875`)

- `--gps-port <port>`
  - host TCP port for GPS forwarding (default `8766`)

- `--forward-gps 0|1`
  - enables/disables GPS forwarding setup

## Service environment settings

`kismet-cell-autosetup.service` effective environment:
- `PREFIX`
- `BASE_PORT`
- `GPS_PORT`
- `FORWARD_GPS`
- `TRANSPORT_MODE`

## Android app settings

- `Transport mode`
  - `USB`: host connects through adb-forwarded TCP

- `Stream cellular data`
  - include/exclude cellular payload fields from output

- `Stream GPS data`
  - include/exclude location and NMEA output

- `Auto-stream on launch`
  - starts service when app UI opens

- `Begin on startup`
  - starts foreground service on boot/unlock

- `Launch app UI on startup`
  - best-effort launch of activity on boot/unlock (device policy dependent)
