# Cellular Datasource for Kismet

This guide is written for someone who can use the Kismet GUI, but is not expected to know Linux, Android debugging, or Kismet internals.

The goal is simple:

1. Power on the phone and the Pi.
2. Plug the phone into the Pi with USB.
3. Start the phone app stream.
4. Open Kismet and see cellular devices and phone GPS.

This repository provides the Kismet capture helper, Kismet plugin, and setup scripts to make that happen.

## What this system does (plain English)

- The Android app reads cell and GPS data from the phone.
- The phone app streams that data over USB to the Pi.
- The Pi runs a small helper that feeds that data into Kismet.
- Kismet shows the cells as devices and can use the phone GPS.

Default ports used:

- Phone cell JSON stream: `8765`
- Phone GPS NMEA stream: `8766`
- Pi forwarded Kismet cell source port(s): `9875`, `9876`, ...
- Pi GPS port (from first phone): `8766` by default

## What is in this repo

- `kismet-cap-cell/install.sh`: one-time installer on the Pi (installs Kismet + this datasource/plugin and sets up services)
- `kismet-cap-cell/multi_phone.sh`: finds attached phones with `adb`, creates port forwards, writes Kismet datasource lines
- `kismet-cap-cell/cell_autoconfig.sh`: auto-refreshes phone forwarding + Kismet config on boot and on a timer
- `kismet-cap-cell/kismet_cap_cell_capture`: helper binary Kismet launches for each phone source
- `kismet-cap-cell/plugin/...`: Kismet plugin files that add cell UI fields/tags/panels
- `collector.py` (optional): optional utility, not required for normal use
- `android-app/`: Android app source (if you build the app yourself)

## Before you begin (one-time requirements)

You need:

- A Raspberry Pi (or Linux host) running Kismet
- An Android phone with the Cellular Datasource app installed
- A USB data cable (not charge-only)
- Internet access on the Pi for first-time install (`install.sh` installs packages)

This guide assumes the default install path used by the scripts:

- Kismet prefix: `/usr`
- Kismet config directory: `/etc/kismet`

## First-time setup (operator walkthrough)

### 1. Prepare the phone

On the Android phone:

1. Power on and unlock the phone.
2. Install and open the app (`Cellular Datasource` / package `dev.alsatianconsulting.cellulardatasource`).
3. Enable phone location/GPS.
4. In the app, make sure:
   - `Cell Measurements` is enabled.
   - `GPS` is enabled.
5. Tap `Start Stream`.
6. Grant permissions when prompted (location, phone state, etc.).

What you should see in the app:

- Status text changes to `Stream running`
- The cell/GPS "Connected" lights may stay red until the Pi side connects
- Once Kismet datasource is connected, those lights should turn green

### 2. Enable USB debugging on the phone (required for USB forwarding)

If this phone has never been used with `adb` on the Pi:

1. On Android, enable Developer Options.
2. Enable `USB debugging`.
3. Plug the phone into the Pi.
4. Accept the "Allow USB debugging?" prompt on the phone.
5. (Recommended) Check "Always allow from this computer".

### 3. Verify the Pi can see the phone

On the Pi:

```bash
adb devices
```

Expected result:

- The phone serial appears with state `device`

If it says `unauthorized`, unlock the phone and accept the USB debugging prompt.

### 4. Run the installer on the Pi (first time only)

From the repo root on the Pi:

```bash
cd kismet-cap-cell
sudo ./install.sh
```

What this does:

- Installs Kismet packages and build dependencies
- Builds and installs the cellular capture helper and Kismet plugin
- Creates/updates Kismet config files
- Creates auto-setup systemd service + timer
- Enables and starts Kismet

You only need to do this once per Pi (unless you are updating the software).

### 5. Open Kismet GUI and verify reception

After the installer finishes:

1. Open the Kismet web UI.
2. Hard refresh the browser once (`Shift+Reload`) so the plugin JS loads.
3. Wait up to ~30 seconds for the auto-setup timer to refresh USB forwards/sources.

What you should see:

- In the Kismet Datasources/Sources view, one or more `cell-<phone-serial>` sources
- Cellular devices appear in Kismet
- Cell-specific metadata appears (MCC/MNC/TAC/etc.)
- Kismet GPS uses the phone GPS (first attached phone)
- In the phone app, the `Connected` lights under `Cell Measurements` and `GPS` turn green

## Daily startup (normal use after first install)

This is the handoff workflow for a non-technical operator.

1. Power on the Pi.
2. Power on and unlock the phone.
3. Plug the phone into the Pi with USB.
4. Open the phone app and tap `Start Stream`.
5. Open Kismet GUI.
6. Wait a few seconds for data to appear.

If data does not appear within ~30 seconds:

1. Check `adb devices` on the Pi.
2. Make sure the phone app still says `Stream running`.
3. Replug the USB cable.
4. Reopen Kismet GUI / refresh the page.

## Which files are automatically edited (and why)

The scripts in this repo intentionally write several files for you. This is normal.

### Files auto-written by `kismet-cap-cell/install.sh`

- `/etc/kismet/datasources.d/cell.conf`
  - Why: creates a Kismet datasource entry for the cell capture helper
  - Note: later, `cell_autoconfig.sh`/`multi_phone.sh` may replace this file with one entry per attached phone

- `/etc/kismet/kismet_site.conf`
  - Why: ensures the cell plugin manifest is loaded and (via autosetup) adds GPS settings
  - Note: plugin line is appended if missing; GPS lines are managed by autosetup

- `/etc/kismet/kismet.conf` (only if missing)
  - Why: seeds a base Kismet config if your system does not already have one

- `/etc/systemd/system/kismet-cell-autosetup.service`
  - Why: runs auto phone detection + port forwarding + Kismet config refresh

- `/etc/systemd/system/kismet-cell-autosetup.timer`
  - Why: reruns autosetup periodically (default every 30 seconds) so replugged phones get picked up

- `/etc/systemd/system/kismet.service`
  - Why: installs/overwrites a systemd unit to run Kismet with restart policy

### Files auto-written by `kismet-cap-cell/cell_autoconfig.sh` (runs via systemd)

- `/etc/kismet/datasources.d/cell.conf`
  - Why: regenerated from currently attached phones
  - Uses `multi_phone.sh` output so Kismet always has the right source list
  - If no phones are attached, this file may be rewritten empty (this is expected)

- `/etc/kismet/kismet_site.conf`
  - Why: ensures Kismet GPS is enabled and points to the forwarded phone GPS port
  - It manages:
    - `gps=enabled`
    - `gps=tcp:127.0.0.1:<GPS_PORT>` (default `8766`)

### Files installed (not typically edited)

- `/usr/bin/kismet_cap_cell_capture`
- `/usr/bin/multi_phone.sh`
- `/usr/bin/cell_autoconfig.sh`
- `/usr/bin/uds_forwarder.py`
- `/usr/lib/kismet/cell/manifest.conf`
- `/usr/lib/kismet/cell/cell.so`
- `/usr/lib/kismet/cell/httpd/js/kismet.ui.cell.js`

These are installed so Kismet and the helper scripts can run. You normally do not edit them.

## Which files you may need to edit manually (and why)

For a basic single-phone USB setup, you usually do not need to edit anything manually.

The files below are only for customization.

### `/etc/kismet/datasources.d/cell.conf`

Edit this only if you want manual control of datasource entries (for example, custom names, custom ports, or Wi-Fi phone connections).

Why you might edit it:

- Give friendlier names than `cell-<serial>`
- Use a different host port
- Point to a phone IP over Wi-Fi instead of `127.0.0.1`

Important:

- If the autosetup timer is enabled, it can overwrite this file on the next run.
- If you want manual control, disable the autosetup timer/service first.

### `/etc/kismet/kismet_site.conf`

Edit this if you want custom Kismet settings beyond what the scripts add.

Why you might edit it:

- Change GPS source behavior
- Add other Kismet plugins/settings

Important:

- `cell_autoconfig.sh` may update the `gps=tcp:127.0.0.1:<port>` line.

### `kismet-cap-cell/multi_phone.sh` (repo copy) or `/usr/bin/multi_phone.sh`

Edit only if you want to change script defaults permanently.

Why you might edit it:

- Change default base port (`9875`)
- Change default GPS port (`8766`)
- Change default Kismet install prefix (`/usr`)

Most users should use command-line flags instead of editing the script.

## What happens automatically when a phone is plugged in (USB)

This is the "why" behind the scripts.

1. `cell_autoconfig.sh` runs (on boot and every 30 seconds by default).
2. It runs `multi_phone.sh`.
3. `multi_phone.sh` runs `adb devices` and finds attached phones.
4. For each phone, it creates an `adb forward`:
   - Host `tcp:9875+N` -> Phone `tcp:8765`
5. For the first phone only, it also forwards GPS:
   - Host `tcp:8766` -> Phone `tcp:8766`
6. It rewrites `/etc/kismet/datasources.d/cell.conf` with one Kismet source line per phone.
7. `cell_autoconfig.sh` ensures `kismet_site.conf` has the phone GPS line.
8. `cell_autoconfig.sh` restarts Kismet so the new sources are picked up.

This is why the operator usually only needs to:

- plug in the phone
- start the app stream
- open Kismet GUI

## Manual recovery commands (copy/paste)

Use these if something looks stuck.

### Check phone connection

```bash
adb devices
```

### Regenerate phone forwards and datasource file right now

```bash
sudo /usr/bin/cell_autoconfig.sh
```

### Restart Kismet

```bash
sudo systemctl restart kismet
```

### See recent autosetup logs

```bash
journalctl -u kismet-cell-autoconfig.service -n 50 --no-pager
```

## Troubleshooting (common operator issues)

### Kismet shows no cellular devices

- Phone app is not running: open app and tap `Start Stream`
- USB debugging not authorized: run `adb devices` and accept prompt on phone
- Bad USB cable: replace with a data cable
- Autosetup has not run yet: wait ~30 seconds or run `sudo /usr/bin/cell_autoconfig.sh`

### Phone app shows red "Connected" lights

That means the Pi/Kismet side is not currently connected to the phone streams.

Check:

- `adb devices` shows `device`
- Kismet is running: `systemctl status kismet`
- Autosetup service is working: `journalctl -u kismet-cell-autoconfig.service -n 50 --no-pager`

### GPS is missing in Kismet but cells are present

- Make sure `GPS` is enabled in the phone app
- `cell_autoconfig.sh` only forwards GPS from the first attached phone
- Check `/etc/kismet/kismet_site.conf` contains:
  - `gps=enabled`
  - `gps=tcp:127.0.0.1:8766`

### Phone replugged but Kismet did not catch up

- Wait for the timer (default 30s)
- Or run:

```bash
sudo /usr/bin/cell_autoconfig.sh
```

## Advanced / optional (not needed for first-time success)

- Multiple phones are supported; each gets its own datasource line and host port (`9875`, `9876`, ...)
- Wi-Fi phone streaming is possible, but USB is recommended for simple operator handoff
- `collector.py` is optional and not required for standard Kismet reception

## Technical data captured (reference)

- Identity: `mcc`, `mnc`, `tac`/`lac`, `cid`/`full_cell_id`, `enb_id`, `sector_id`
- Channel: `earfcn`/`nrarfcn`/`arfcn`, derived `band`, derived `dl_freq_mhz`/`ul_freq_mhz`, `bandwidth_khz`, `pci`
- Signal: `rssi`, `rsrp`, `rsrq`, `snr`, `timing_advance`
- Network: `network_name`, `network_type`, `registered`
- GPS: `lat`, `lon`, `alt_m`, `accuracy_m`, `speed_mps`, `bearing_deg`, `satellites`
