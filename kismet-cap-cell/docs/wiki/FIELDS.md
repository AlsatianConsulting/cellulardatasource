# Data Fields Reference

This page documents primary payload fields emitted by the Android app and consumed by the cell datasource stack.

## Top-level JSON fields

- `ts` (number)
  - unix timestamp (seconds, fractional allowed)

- `status` (string, optional)
  - health/status payload values:
    - `no_permission`
    - `location_disabled`
    - `no_cells`

- `network_name` (string, optional)
  - carrier/operator name reported by Android TelephonyManager

- `network_type` (string, optional)
  - current data RAT summary (for example LTE/NR)

- `lat`, `lon` (number, optional)
  - GPS coordinates in decimal degrees

- `alt_m` (number, optional)
  - altitude meters

- `speed_mps` (number, optional)
  - speed meters/second

- `bearing_deg` (number, optional)
  - heading in degrees

- `accuracy_m` (number, optional)
  - estimated horizontal accuracy in meters

- `provider` (string|null, optional)
  - Android location provider source

- `satellites` (number, optional)
  - visible satellites count from GNSS callback

- `cells` (array)
  - list of decoded serving/neighbor cell objects

## Stream health fields

- `stream_clients` (int)
  - active USB/TCP stream client count


- `nmea_clients` (int)
  - active GPS/NMEA TCP client count

- `total_clients` (int)
  - aggregate client count

- `transport_mode` (string)
  - `usb`

- `pi_service_running` (bool)
  - compatibility boolean indicating host-side connectivity activity

- `pi_connected` (bool)
  - connectivity heuristic for active/recent host connection

- `stream_ok` (bool)
  - true when stream writes are recent and clients are active

- `cell_listener_registered` (bool)
  - telephony listener registration status

- `cell_listener_events` (int)
  - count of cell listener callbacks

- `cell_listener_live` (bool)
  - true when listener events are recent

- `cell_listener_last_event_age_s` (number|null)
  - age in seconds of last listener callback

- `stream_last_write_age_s` (number|null)
  - age in seconds of last successful stream write

## Cell object fields

Common fields:
- `rat` (`LTE|NR|WCDMA|GSM`)
- `registered` (bool)
- `mcc`, `mnc`
- identity and signal keys vary by RAT

Examples used by UI and exports:
- `cid`, `enb_id`
- `lac` or `tac`
- `pci`
- `arfcn`, `earfcn`, `nrarfcn`
- `rssi`
- `rsrp`, `rsrq`, `snr`
- `ss_rsrp`, `ss_rsrq`, `ss_sinr` (NR contexts)
- `timing_advance`

## NMEA output

GPS server (`tcp:8766`) emits standard NMEA lines generated from current fix, including:
- `GGA`
- `RMC`
- `GSA`
- `GSV`
