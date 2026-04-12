# Cell capture schema (v1 draft)

This is the phone-to-capture JSON line schema the `kismet_cap_cell` daemon will ingest before forwarding into Kismet.

Top-level object:
```json
{
  "schema_version": 1,
  "device_id": "string",              // phone identifier (adb serial or user-provided)
  "ts": 1700000000.123,               // seconds since epoch (float)
  "network_name": "Operator",
  "network_type": "LTE",              // human-readable RAT summary
  "cells": [ { ...cell... }, ... ],   // serving + neighbors
  "location": {                       // optional; attached only if phone GPS toggle is on
    "lat": 12.34,
    "lon": 56.78,
    "alt": 10.0,
    "acc": 5.0,
    "src": "device_gps"
  }
}
```

Cell entry (fields optional per RAT):
```json
{
  "rat": "LTE|NR|WCDMA|GSM",
  "registered": true,
  "mcc": "310",
  "mnc": "260",
  "tac": 12345,          // LTE/NR
  "lac": 12345,          // WCDMA/GSM
  "cid": 123456789,      // LTE ECI, NR NCI, WCDMA/GSM CID
  "full_cell_id": 123456789,
  "enb_id": 12345,       // LTE only (eci/256)
  "sector_id": 12,       // LTE only (eci%256)
  "pci": 123,
  "earfcn": 1234,        // LTE
  "nrarfcn": 123456,     // NR
  "arfcn": 123,          // GSM
  "uarfcn": 12345,       // WCDMA
  "band": 3,
  "bandwidth_khz": 10000,
  "dl_freq_mhz": 1820.0, // derived
  "ul_freq_mhz": 1730.0, // derived
  "rsrp": -95,
  "rsrq": -10,
  "rssi": -70,
  "snr": 15,
  "timing_advance": 1,
  "vqi": null,           // not exposed; reserved
  "network_name": "Operator",  // optional override per cell
  "network_type": "LTE"        // optional override per cell
}
```

Notes:
- Phone GPS is **not** forwarded to Kismet by default; it is retained for optional exports (JSON/CSV/KML). Kismet GPS remains authoritative for in-Kismet geo.
- Schema is versioned; daemons should reject or log unknown `schema_version`.
- Additional fields can be added later; avoid breaking changes to existing keys.
