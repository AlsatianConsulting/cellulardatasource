# Release Notes - 2026-03-20

## Summary

This release focuses on production stability for Raspberry Pi deployment, phone reconnect behavior, startup automation, and packaging/distribution quality.

## Highlights

- Hardened post-reboot recovery of cellular datasource forwarding and Kismet attach
- Added robust ADB key handling for root-run autosetup context
- Added USB transport configuration support across installer/service flow
- Added one-command install improvements and service configuration controls
- Added full Debian package build flow and release artifact handling
- Expanded documentation: install guides, troubleshooting, UI/field/wiki references

## Key Changes

### Streaming and Recovery

- `cell_autoconfig.sh`
  - detects forward socket readiness transitions and restarts Kismet when needed
  - uses non-blocking `systemctl --no-block restart kismet` to avoid startup deadlocks
- `multi_phone.sh`
  - auto-discovers and exports `ADB_VENDOR_KEYS` when running as root, improving authorized-device behavior after reboot
- Autosetup service semantics
  - enforced `KillMode=process` to avoid terminating `adb` and dropping forward sockets on service exit

### Startup and Service Ordering

- Added Kismet ordering drop-in support:
  - `Wants=kismet-cell-autosetup.service`
  - `After=kismet-cell-autosetup.service`
- Preserves reliable datasource bring-up during boot sequences

### Installer Consolidation

- Clarified installer role boundaries:
  - `install.sh` (low-level)
  - `one_shot_install.sh` / `one` (primary)
  - `pi_one_command_setup.sh` (Pi profile)
- Removed superseded scripts:
  - `pi_kismet_cell_turnkey.sh`
  - `kismet-cell-setup.sh`

### Packaging

- Added Debian packaging script:
  - `build_dpkg.sh`
- Package outputs:
  - `cellulardatasource_<version>_<arch>.deb`
- Includes wrapper commands and project tree under `/opt/cellulardatasource/kismet-cap-cell`

### Android App UX and Runtime

- Added top-left app menu with:
  - `Settings`
  - `Quit App`
- Foreground service notification status states:
  - `Streaming Cell`
  - `Streaming GPS`
  - `Streaming Cell+GPS`
  - `Not Streaming`
- Boot receiver improvements for startup and best-effort foreground launch behavior

## Verification Completed

- Multiple Pi reboot cycles verified:
  - cell TCP stream restored automatically
  - GPS TCP stream restored automatically
  - Kismet datasource launches and GPS connects without manual edits
- Reconnect recovery validated by simulated ADB interruption and autosetup recovery

## Migration Notes

- If you rely on legacy scripts, switch to `./one` or `./one_shot_install.sh`.
- For manual config control, use installer with `--overwrite-config 0` and apply printed guidance.
- For package-based deployment, install `.deb` then run installer from `/opt/cellulardatasource/kismet-cap-cell`.
