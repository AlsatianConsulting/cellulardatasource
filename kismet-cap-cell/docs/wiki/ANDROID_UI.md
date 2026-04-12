# Android UI Reference (Complete)

This page documents every visible menu item, button, toggle, indicator, and display section in the Android app.

App package:
- `dev.alsatianconsulting.cellulardatasource`

Main activity layout source:
- `android-app/app/src/main/res/layout/activity_main.xml`

Settings dialog layout source:
- `android-app/app/src/main/res/layout/dialog_settings.xml`

Menu source:
- `android-app/app/src/main/res/menu/main_app_menu.xml`

## Main Screen Elements

### Top-left menu button (`menuButton`)

- Display: three-line/hamburger icon
- Action: opens popup app menu
- Menu items:
  - `Settings`
  - `Quit App`

### Status text (`statusText`)

Possible values:
- `Stream stopped`
- `Stream running`

Behavior:
- updates based on foreground service running state (`CellStreamService`)

### Start/Stop button (`toggleButton`)

States:
- stopped state
  - label: `Start Stream`
  - style: `btn_start`
- running state
  - label: `Stop Stream`
  - style: `btn_stop`

Action:
- if stopped: permission checks then starts foreground service
- if running: stops foreground service

### Main screen quick toggles

#### `Cell Measurements` switch (`switchCellToggle`)

- Controls whether cellular payload is included in output stream
- Persists to `stream_cellular`
- When disabled:
  - cell connectivity indicator forced to Not Connected

#### `GPS` switch (`switchGpsToggle`)

- Controls whether GPS payload/NMEA output is included
- Persists to `stream_gps`
- When disabled:
  - GPS connectivity indicator forced to Not Connected

### Connectivity indicators

#### Cell indicator

- light view: `cellStatusLight`
- text label: `cellStatusText`
- text values:
  - `Connected`
  - `Not Connected`
- color:
  - green when connected and switch enabled
  - red otherwise

#### GPS indicator

- light view: `gpsStatusLight`
- text label: `gpsStatusText`
- text values:
  - `Connected`
  - `Not Connected`
- color:
  - green when connected and switch enabled
  - red otherwise

## Data Display Sections

### Cellular data text (`cellInfoText`)

Initial placeholder:
- `Waiting for cell data...`

Possible content:
- status-only payload text (`Status: no_permission`, etc.)
- parsed cell details including:
  - `Network`
  - `Technology`
  - `MCC`
  - `MNC`
  - `LAC/TAC`
  - `Cell ID`
  - `eNB ID`
  - `PCI`
  - `CQI` (currently static `N/A`)
  - `Timing Advance`
  - `ARFCN`
  - `RSSI`
  - `RSRP`
  - `RSRQ`
  - `SNR`

### GPS data text (`gpsInfoText`)

Display block includes:
- `GPS:`
- `Lat/Lon`
- `Accuracy (m)`
- `Satellites`

## App Menu (from top-left button)

### `Settings`

- opens settings dialog

### `Quit App`

- stops `CellStreamService`
- closes app task via `finishAffinity()`
- app remains stopped until manually started or boot auto-start conditions trigger

## Settings Dialog Elements (Complete)

Dialog title:
- `Settings`

Dialog close button:
- `Close`

### Transport mode

Display:
- `Transport mode: USB`

Persistence key:
- `transport_mode` with value `usb`

Effect:
- service exposes USB TCP server(s) for stream and GPS forwarding

### `Stream cellular data` switch (`switchStreamCell`)

Persistence key:
- `stream_cellular`

Effect:
- include/exclude cell measurements in streamed payload

### `Stream GPS data` switch (`switchStreamGps`)

Persistence key:
- `stream_gps`

Effect:
- include/exclude GPS fields/NMEA output

### `Auto-stream on launch` switch (`switchAutoStart`)

Persistence key:
- `auto_start_stream`

Effect:
- on app open, if enabled and service is not running, app attempts to start stream automatically

### `Begin on startup` switch (`switchStartOnBoot`)

Persistence key:
- `start_on_boot` (stored in CE and DE prefs)

Effect:
- `BootReceiver` starts foreground service on boot/unlock/start-related intents

### `Launch app UI on startup` switch (`switchLaunchUiOnBoot`)

Persistence key:
- `launch_ui_on_boot` (stored in CE and DE prefs)

Effect:
- `BootReceiver` attempts best-effort launch of `MainActivity` during/after boot
- includes delayed retries to handle OEM boot restrictions

## Foreground Notification

Notification channel:
- `cellstream` (`Cell Stream`)

Notification title values:
- `Streaming Cell`
- `Streaming GPS`
- `Streaming Cell+GPS`
- `Not Streaming`

Notification text:
- `Tap to open Cellular Datasource`

Behavior:
- ongoing foreground notification while service is active
- tapping notification opens `MainActivity`
- notification updates on stream setting changes

## Runtime Permission Prompts

The app may request:
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `READ_PHONE_STATE`
- `POST_NOTIFICATIONS` (Android 13+)
- `BLUETOOTH_CONNECT` (Android 12+ when BT transport is selected)
- `ACCESS_BACKGROUND_LOCATION` (Android 10+)

Additional system prompt path:
- battery optimization exemption (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)

## Boot-Time Behavior Reference

Receiver:
- `BootReceiver`

Handled intents:
- `BOOT_COMPLETED`
- `LOCKED_BOOT_COMPLETED`
- `USER_UNLOCKED`
- `USER_PRESENT`
- `MY_PACKAGE_REPLACED`
- `QUICKBOOT_POWERON`

Startup logic:
- if `Begin on startup` enabled, starts foreground service
- if `Launch app UI on startup` enabled, attempts to bring UI to foreground
