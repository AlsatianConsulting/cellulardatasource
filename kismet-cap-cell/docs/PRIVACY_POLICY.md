# Privacy Policy

Last updated: 2026-03-20

This project includes:
- Android app: `CellularDatasource` (package: `dev.alsatianconsulting.cellulardatasource`)
- Pi/host scripts and Kismet integration components

## Summary

- The app collects cellular and GPS telemetry from your device when enabled.
- Data is streamed to destinations you configure (USB/ADB, localhost TCP/Kismet pipelines).
- The project does not include a cloud backend operated by Alsatian Consulting.
- Data handling and retention are controlled by the systems you send data to (for example, Kismet logs, export files).

## Data We Process

Depending on enabled settings and device capabilities, the software may process:
- Cellular metadata (for example MCC/MNC, cell ID, TAC/LAC, PCI, ARFCN/EARFCN/NRARFCN, radio/signal metrics)
- GPS/location data (latitude/longitude, altitude, speed, bearing, accuracy, satellite count)
- Timestamps and stream health/transport status fields

## How Data Is Used

Data is used to:
- Display live telemetry in the Android app
- Stream telemetry to local/nearby collectors (for example Kismet datasource capture helpers)
- Generate optional exports (for example JSON/CSV/KMZ) on systems you control

## Network and Transport

The project can stream over:
- USB ADB forwarding (localhost TCP endpoints on the host)
- Localhost services/scripts on the host

The project does not require sending telemetry to a vendor-operated internet service.

## Permissions (Android)

The Android app may request permissions including:
- Location (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`)
- Phone state (`READ_PHONE_STATE`)
- Foreground service and notifications (`FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`)
- Boot completed (`RECEIVE_BOOT_COMPLETED`)

Permissions are used to support continuous telemetry collection/streaming features you enable.

## Data Retention

- The app itself is designed for live streaming and status display.
- Retention primarily occurs in downstream tools (for example Kismet `.kismet` logs, export files, system logs).
- You control retention by deleting logs/files and configuring your host tools.

## Data Sharing

- The software shares telemetry only with endpoints/devices you configure.
- No built-in third-party analytics or ad SDKs are included by default in this project.

## Security Notes

- Use trusted hosts and networks.
- Protect devices and logs with OS-level controls.
- If using custom keystores/signing keys, store them securely and rotate if compromised.

## Children’s Privacy

This project is not directed to children and is intended for technical/security operations use.

## Changes to This Policy

This policy may be updated as features change. The latest version will be kept in this repository.

## Contact

For project questions, open an issue in this repository:
- https://github.com/AlsatianConsulting/cellulardatasource/issues
