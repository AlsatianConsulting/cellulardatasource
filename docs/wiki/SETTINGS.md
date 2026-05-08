# Settings Reference

## Installer options (`./one` / `./one_shot_install.sh`)

- `--install-services 0|1`
  - `1`: installs/enables autosetup services
  - `0`: skips service units

- `--overwrite-config 0|1`
  - `1`: rewrites:
    - `/etc/kismet/kismet_site.conf`
    - `/etc/kismet/datasources.d/cell.conf`
  - `0`: does not overwrite; prints exact manual lines to add

- `--install-kismet 0|1`
  - `1`: builds and installs Kismet from source
  - `0`: leaves the existing Kismet install alone

- `--kismet-install-mode source|system`
  - `source`: clone/build/install Kismet from source
  - `system`: use an already-installed Kismet tree and skip source install

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

- `Stream cellular towers`
  - include/exclude cellular payload fields from output

- `Stream GPS location`
  - include/exclude location and NMEA output

- `Auto-stream on launch`
  - starts service when app UI opens

- `Begin on startup`
  - starts foreground service on boot/unlock

- `Launch app UI on startup`
  - best-effort launch of activity on boot/unlock (device policy dependent)
