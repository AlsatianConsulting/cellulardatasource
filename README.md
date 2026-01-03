# kismet_cap_cell (skeleton)

Native capture stub for a future Kismet “cell” datasource.

Current state:
- Listens on a UNIX domain socket (default `/var/run/kismet/cell.sock`), optional TCP listener only when `--enable-tcp` is provided.
- Accepts line-delimited JSON from phone feeders; prints to stdout with basic per-client tagging.
- No Kismet protocol wiring yet (TODO); intended as the starting point for a proper `kismet_cap_*` capture module.
- Draft schema in `SCHEMA.md` (schema_version 1).
- `--list` prints capabilities metadata so Kismet GUI can detect the datasource type.

Build:
```bash
g++ -std=c++17 -O2 -pthread main.cpp -o kismet_cap_cell
```

Run (local UDS only):
```bash
sudo ./kismet_cap_cell --socket /var/run/kismet/cell.sock
```

Run (enable TCP explicitly, non-default port):
```bash
sudo ./kismet_cap_cell --socket /var/run/kismet/cell.sock --enable-tcp --tcp-port 8765
```

Optional forwarder (keeps kismet_cap_cell purely UDS):
```bash
cd "$(dirname "$0")"
./uds_forwarder.py --tcp-port 8765 --uds /var/run/kismet/cell.sock
# Then use adb reverse tcp:8765 tcp:8765 so the phone reaches the forwarder.
```

List capabilities (for GUI discovery):
```bash
./kismet_cap_cell --list
```

Sample Kismet datasource entry (copy from `datasource-cell.conf.sample`):
```text
datasource=cell:name=cell-1,type=cell,source=uds:/var/run/kismet/cell.sock
```
Name additional sources as `cell-2`, `cell-3`, etc.

Kismet GPS using the phone:
- Direct phone feed: ensure `adb reverse tcp:8766 tcp:8766` (or rely on `collector.py` forwarding), then set in `kismet.conf`:
  ```
  gps=enabled
  gps=tcp:127.0.0.1:8766
  ```
- Or via collector rebroadcast: run `python3 collector.py --nmea-port 31337` and use `gps=tcp:127.0.0.1:31337`.

Notes:
- Default mode does **not** open a TCP port; only a local UNIX socket is used to avoid accidental exposure.
- This is a scaffold; the next steps are to add schema validation and the Kismet capture protocol handshake to register the `cell` datasource, plus forwarding into kismet_server and export routines (JSON/CSV/KML).
- See `SCHEMA.md` for the phone-to-daemon payload fields; the daemon should validate `schema_version` and normalize before forwarding.
