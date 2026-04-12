# Phone Export Server

Standalone TCP server that receives newline-delimited JSON payloads from the phone stream and exports:

- `*.json` (full records)
- `*.csv` (flattened cell rows)
- `*.kmz` (geotagged KML zipped to KMZ)

## Run

```bash
cd phone_export_server
python3 export_server.py --host 0.0.0.0 --port 9875 --output-dir ./exports
```

## Connect Phone Stream

If using USB forwarding from Android device:

```bash
adb forward tcp:9875 tcp:9875
```

Then start streaming in the app.

## Output

Files are created as:

- `exports/capture-YYYYmmdd-HHMMSS.json`
- `exports/capture-YYYYmmdd-HHMMSS.csv`
- `exports/capture-YYYYmmdd-HHMMSS.kmz`

Stop with `Ctrl+C`; the server finalizes JSON/KMZ on shutdown.
