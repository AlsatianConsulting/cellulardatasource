# Features

## Install/Deployment

- `one` / `one_shot_install.sh`
  - interactive installer
  - can build and install Kismet from source
  - can skip Kismet install and layer only the cellular datasource stack on an existing host
  - supports optional config overwrite
  - supports optional service installation/enabling
  - supports USB transport

## Cellular Capture Stack

- `kismet_cap_cell_capture`
  - Kismet external capture helper for `cell` datasource
  - receives JSON lines and forwards to Kismet datasource protocol

- `plugin/cell.so`
  - Kismet plugin registering `cell` PHY and datasource type
  - UI integration script in `plugin/httpd/js/kismet.ui.cell.js`

- `cell_autoconfig.sh`
  - enumerates attached phones via `adb`
  - writes datasource definitions into `/etc/kismet/datasources.d/cell.conf`
  - optionally sets GPS forwarding source

- `multi_phone.sh`
  - creates `adb forward` mappings for multiple phones
  - maps phone `tcp:8765` stream to host `tcp:<BASE_PORT + n>`
  - maps GPS `tcp:8766` when enabled

## Kismet Integrations

- additive inclusion pattern:
  - `opt_include=/etc/kismet/datasources.d/*.conf`

## Android App

- foreground streaming service (`CellStreamService`)
  - cellular measurements + GPS
  - USB TCP server (`8765`)
  - GPS/NMEA TCP server (`8766`)

- boot/start behavior (`BootReceiver`)
  - optional start service on boot
  - optional best-effort launch of app UI on boot/unlock

- runtime settings:
  - transport mode
  - stream cellular on/off
  - stream GPS on/off
  - auto-stream on launch
  - begin on startup
  - launch app UI on startup
