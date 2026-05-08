# Android UI Reference

Package:
- `dev.alsatianconsulting.cellulardatasource`

## Main Screen

### Menu Button

- ID: `menuButton`
- Display: three-line icon in the top left
- Opens the app menu

Menu items:
- `Settings`
- `Quit App`

### Status Text

- ID: `statusText`
- Displays `Stream stopped`, `Stream running`, or `Stream running (<status>)`

### Start/Stop Button

- ID: `toggleButton`
- Stopped label: `Start Stream`
- Running label: `Stop Stream`
- Starts or stops `CellStreamService`

### Attached Stream Status

- ID: `attachedStatusText`
- Displays whether an attached host is connected to the local stream
- Values:
  - `Attached stream waiting`
  - `Attached stream connected`

### Cell Indicator

- Light ID: `cellStatusLight`
- Label ID: `cellStatusText`
- Green/`Active` when cell observations are present and cell streaming is enabled
- Red/`Idle` otherwise

### GPS Indicator

- Light ID: `gpsStatusLight`
- Label ID: `gpsStatusText`
- Green/`Active` when a GPS fix is present and GPS streaming is enabled
- Red/`Idle` otherwise

### Current GPS Fix

- ID: `gpsInfoText`
- Shows latitude/longitude, provider, accuracy, altitude, speed, and satellites
- Placeholder: `No GPS fix yet`

### Latest Cell Towers

- ID: `cellInfoText`
- Shows up to 10 current cell observations
- Includes RAT, MCC/MNC, TAC/LAC, cell ID, PCI/PSC, and RSSI where available
- Placeholder: `No cell data yet`

## Settings Dialog

### Stream Cellular Towers

- ID: `switchStreamCell`
- Preference key: `stream_cellular`
- Controls whether cellular observations are included in JSON output

### Stream GPS Location

- ID: `switchStreamGps`
- Preference key: `stream_gps`
- Controls whether GPS fields and NMEA output are enabled

### Auto-Start Stream On App Launch

- ID: `switchAutoStart`
- Preference key: `auto_start_stream`
- Starts the service automatically when the app UI opens

### Begin On Startup

- ID: `switchStartOnBoot`
- Preference key: `start_on_boot`
- Starts the foreground service on boot/unlock intents

### Launch App UI On Startup

- ID: `switchLaunchUiOnBoot`
- Preference key: `launch_ui_on_boot`
- Attempts to open the app UI after boot/unlock
- Android/OEM background launch restrictions may prevent the foreground UI from appearing

## Quit App

`Quit App` stops `CellStreamService` and closes the task with `finishAffinity()`.

## Foreground Notification

Notification title values:
- `Streaming Cell`
- `Streaming GPS`
- `Streaming Cell+GPS`
- `Not Streaming`

Notification text:
- `Attached local stream active`

Tapping the notification opens `MainActivity`.

## First Launch Permission Notice

On first launch only, the app explains that location permission is used to collect and display GPS fixes and nearby cellular observations for geotagging while the foreground service runs.

## Runtime Permissions

The app may request:
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_BACKGROUND_LOCATION`
- `READ_PHONE_STATE`
- `POST_NOTIFICATIONS`
