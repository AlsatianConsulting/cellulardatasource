#!/usr/bin/env python3
"""
Multi-device collector for the cellular datasource prototype.
Discovers adb-connected devices, sets up port reverse, and reads JSON streams.
Adds optional outputs: JSONL, CSV, SQLite, KML, GPX. Each record is flattened with
device info, location (if provided by the phone), and a consolidated full_cell_key.
Supports a gps-only mode to emit location records even when no cell is present.
Optional NMEA/TCP output lets Kismet or gpsd consume the phone GPS directly.
"""
import argparse
import asyncio
import atexit
import csv
import json
import os
import sqlite3
import subprocess
import time
from typing import Dict, List, Optional

PORT = 8765
NMEA_PHONE_PORT = 8766
MAX_CONNECT_RETRIES = 10
FIELDNAMES = [
    "ts",
    "device_id",
    "network_name",
    "network_type",
    "lat",
    "lon",
    "alt_m",
    "speed_mps",
    "bearing_deg",
    "accuracy_m",
    "provider",
    "rat",
    "registered",
    "mcc",
    "mnc",
    "tac",
    "lac",
    "cid",
    "full_cell_id",
    "full_cell_key",
    "enb_id",
    "sector_id",
    "earfcn",
    "arfcn",
    "nrarfcn",
    "band",
    "bandwidth_khz",
    "pci",
    "rssi",
    "rsrp",
    "rsrq",
    "snr",
    "timing_advance",
    "vqi",
    "dl_freq_mhz",
    "ul_freq_mhz",
    "satellites",
    "neighbors",
]

# LTE band plan (subset; extend as needed)
LTE_BANDS = {
    # band: (fdl_low, ful_low, noffs_dl)
    1: (2110.0, 1920.0, 0),
    2: (1930.0, 1850.0, 600),
    3: (1805.0, 1710.0, 1200),
    4: (2110.0, 1710.0, 1950),
    5: (869.0, 824.0, 2400),
    6: (830.0, 875.0, 2650),
    7: (2620.0, 2500.0, 2750),
    8: (925.0, 880.0, 3450),
    9: (1844.9, 1749.9, 3800),
    10: (2110.0, 1710.0, 4150),
    11: (1475.9, 1427.9, 4750),
    12: (729.0, 699.0, 5010),
    13: (746.0, 777.0, 5180),
    14: (758.0, 788.0, 5280),
    17: (734.0, 704.0, 5035),
    18: (860.0, 815.0, 5850),
    19: (875.0, 830.0, 6000),
    20: (791.0, 832.0, 6150),
    21: (1495.9, 1447.9, 6450),
    22: (3510.0, 3410.0, 6600),
    23: (2180.0, 2000.0, 7500),
    24: (1525.0, 1626.5, 7700),
    25: (1930.0, 1850.0, 8040),
    26: (859.0, 814.0, 8690),
    27: (852.0, 807.0, 9040),
    28: (758.0, 703.0, 9210),
    29: (717.0, None, 9660),  # DL only
    30: (2350.0, 2305.0, 9770),
    31: (462.5, 452.5, 9870),
    32: (1452.0, None, 9920),  # DL only
    33: (1900.0, None, 36000),
    34: (2010.0, None, 36200),
    35: (1850.0, None, 36350),
    36: (1930.0, None, 36950),
    37: (1910.0, None, 37550),
    38: (2570.0, None, 37750),
    39: (1880.0, None, 38250),
    40: (2300.0, None, 38650),
    41: (2496.0, None, 39650),
    42: (3400.0, None, 41590),
    43: (3600.0, None, 43590),
    48: (3550.0, None, 55240),
    65: (2110.0, 1920.0, 65536),
    66: (2110.0, 1710.0, 66436),
    67: (738.0, None, 67336),   # DL only
    68: (753.0, 698.0, 68336),
    71: (617.0, 663.0, 13470),
}

LTE_BAND_RANGES = [
    (1, 0, 599),
    (2, 600, 1199),
    (3, 1200, 1949),
    (4, 1950, 2399),
    (5, 2400, 2649),
    (6, 2650, 2749),
    (7, 2750, 3449),
    (8, 3450, 3799),
    (9, 3800, 4149),
    (10, 4150, 4749),
    (11, 4750, 4949),
    (12, 5010, 5179),
    (13, 5180, 5279),
    (14, 5280, 5379),
    (17, 5730, 5849),
    (18, 5850, 5999),
    (19, 6000, 6149),
    (20, 6150, 6449),
    (21, 6450, 6599),
    (22, 6600, 7399),
    (23, 7500, 7699),
    (24, 7700, 8039),
    (25, 8040, 8689),
    (26, 8690, 9039),
    (27, 9040, 9209),
    (28, 9210, 9659),
    (29, 9660, 9769),
    (30, 9770, 9869),
    (31, 9870, 9919),
    (32, 9920, 10359),
    (33, 36000, 36199),
    (34, 36200, 36349),
    (35, 36350, 36949),
    (36, 36950, 37549),
    (37, 37550, 37749),
    (38, 37750, 38249),
    (39, 38250, 38649),
    (40, 38650, 39649),
    (41, 39650, 41589),
    (42, 41590, 43589),
    (43, 43590, 45589),
    (48, 55240, 56739),
    (65, 65536, 66435),
    (66, 66436, 67335),
    (67, 67336, 67535),
    (68, 68336, 68585),
    (71, 13470, 13719),
]

def calc_lte_freqs(earfcn: Optional[int], band: Optional[int]) -> (Optional[float], Optional[float]):
    if earfcn is None or band is None:
        return None, None
    if band not in LTE_BANDS:
        return None, None
    fdl_low, ful_low, noffs = LTE_BANDS[band]
    if fdl_low is None or noffs is None:
        return None, None
    dl = fdl_low + 0.1 * (earfcn - noffs)
    ul = None
    if ful_low is not None:
        ul = ful_low + 0.1 * (earfcn - noffs)
    return round(dl, 3), round(ul, 3) if ul is not None else None

def derive_band_from_earfcn(earfcn: Optional[int]) -> Optional[int]:
    if earfcn is None:
        return None
    for band, lo, hi in LTE_BAND_RANGES:
        if lo <= earfcn <= hi:
            return band
    return None


def nmea_checksum(sentence: str) -> str:
    cs = 0
    for ch in sentence:
        cs ^= ord(ch)
    return f"{cs:02X}"


def nmea_coord(value: float, is_lat: bool) -> (str, str):
    hemi = "N" if is_lat else "E"
    if value < 0:
        hemi = "S" if is_lat else "W"
    abs_val = abs(value)
    deg = int(abs_val)
    minutes = (abs_val - deg) * 60.0
    if is_lat:
        coord = f"{deg:02d}{minutes:07.4f}"
    else:
        coord = f"{deg:03d}{minutes:07.4f}"
    return coord, hemi


async def list_devices() -> List[str]:
    proc = await asyncio.create_subprocess_exec(
        "adb", "devices", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    out, err = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"adb devices failed: {err.decode().strip()}")
    serials = []
    for line in out.decode().splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    return serials


def full_cell_key(cell: Dict) -> str:
    mcc = cell.get("mcc") or ""
    mnc = cell.get("mnc") or ""
    tac = cell.get("tac") or cell.get("lac") or ""
    cid = cell.get("full_cell_id") or cell.get("cid") or cell.get("nci") or ""
    return f"{mcc}-{mnc}-{tac}-{cid}"


def flatten_record(device_id: str, root: Dict, cell: Dict, neighbors: Optional[List[Dict]] = None) -> Dict:
    rec = {k: None for k in FIELDNAMES}
    rec["device_id"] = device_id
    rec["ts"] = root.get("ts")
    rec["network_name"] = root.get("network_name")
    rec["network_type"] = root.get("network_type")
    # location
    for lk, rk in [
        ("lat", "lat"),
        ("lon", "lon"),
        ("alt_m", "alt_m"),
        ("speed_mps", "speed_mps"),
        ("bearing_deg", "bearing_deg"),
        ("accuracy_m", "accuracy_m"),
        ("provider", "provider"),
        ("satellites", "satellites"),
    ]:
        if rk in root:
            rec[lk] = root.get(rk)
    # cell fields
    for ck in [
        "rat",
        "registered",
        "mcc",
        "mnc",
        "tac",
        "lac",
        "cid",
        "full_cell_id",
        "enb_id",
        "sector_id",
        "earfcn",
        "arfcn",
        "nrarfcn",
        "band",
        "bandwidth_khz",
        "pci",
        "rssi",
        "rsrp",
        "rsrq",
        "snr",
        "timing_advance",
        "vqi",
        "dl_freq_mhz",
        "ul_freq_mhz",
    ]:
        if ck in cell:
            rec[ck] = cell.get(ck)
    # Compute LTE UL/DL frequencies when not present
    if rec.get("dl_freq_mhz") is None and rec.get("ul_freq_mhz") is None:
        try:
            earfcn = None
            for key in ("earfcn", "nrarfcn"):
                if rec.get(key) is not None:
                    earfcn = int(rec.get(key))
                    break
            band = rec.get("band")
            if band is None:
                band = derive_band_from_earfcn(earfcn)
            else:
                band = int(band)
            dl, ul = calc_lte_freqs(earfcn, band)
            if dl is not None:
                rec["dl_freq_mhz"] = dl
            if ul is not None:
                rec["ul_freq_mhz"] = ul
            if rec.get("band") is None and band is not None:
                rec["band"] = band
        except Exception:
            pass
    rec["full_cell_key"] = full_cell_key(cell)
    if neighbors is not None:
        rec["neighbors"] = json.dumps(neighbors)
    return rec


class OutputWriters:
    def __init__(self, args: argparse.Namespace):
        self.jsonl_path = args.jsonl
        self.csv_path = args.csv
        self.sqlite_path = args.sqlite
        self.kml_path = args.kml
        self.gpx_path = args.gpx
        self.csv_writer = None
        self.csv_file = None
        self.sqlite_conn = None
        self.kml_file = None
        self.gpx_file = None

        if self.jsonl_path:
            os.makedirs(os.path.dirname(self.jsonl_path) or ".", exist_ok=True)
        if self.csv_path:
            os.makedirs(os.path.dirname(self.csv_path) or ".", exist_ok=True)
            self.csv_file = open(self.csv_path, "a", newline="", encoding="utf-8")
            self.csv_writer = csv.DictWriter(self.csv_file, fieldnames=FIELDNAMES)
            if self.csv_file.tell() == 0:
                self.csv_writer.writeheader()
        if self.sqlite_path:
            os.makedirs(os.path.dirname(self.sqlite_path) or ".", exist_ok=True)
            self.sqlite_conn = sqlite3.connect(self.sqlite_path)
            self._ensure_sqlite()
            atexit.register(self.sqlite_conn.close)
        if self.kml_path:
            os.makedirs(os.path.dirname(self.kml_path) or ".", exist_ok=True)
            exists = os.path.isfile(self.kml_path)
            self.kml_file = open(self.kml_path, "a", encoding="utf-8")
            if not exists:
                self.kml_file.write('<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2">\n<Document>\n')
            atexit.register(self._close_kml)
        if self.gpx_path:
            os.makedirs(os.path.dirname(self.gpx_path) or ".", exist_ok=True)
            exists = os.path.isfile(self.gpx_path)
            self.gpx_file = open(self.gpx_path, "a", encoding="utf-8")
            if not exists:
                self.gpx_file.write('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="collector" xmlns="http://www.topografix.com/GPX/1/1">\n<trk><name>cellstream</name><trkseg>\n')
            atexit.register(self._close_gpx)

    def _ensure_sqlite(self):
        cur = self.sqlite_conn.cursor()
        cols = ", ".join(f"{f} TEXT" for f in FIELDNAMES)
        cur.execute(f"CREATE TABLE IF NOT EXISTS cell_data ({cols});")
        # Add missing columns (handles upgrades)
        cur.execute("PRAGMA table_info(cell_data);")
        existing_cols = {row[1] for row in cur.fetchall()}
        for f in FIELDNAMES:
            if f not in existing_cols:
                cur.execute(f"ALTER TABLE cell_data ADD COLUMN {f} TEXT;")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_cell_key ON cell_data(full_cell_key);")
        self.sqlite_conn.commit()

    def write(self, rec: Dict):
        if self.jsonl_path:
            with open(self.jsonl_path, "a", encoding="utf-8") as jf:
                jf.write(json.dumps(rec))
                jf.write("\n")
        if self.csv_writer:
            self.csv_writer.writerow(rec)
            self.csv_file.flush()
        if self.sqlite_conn:
            placeholders = ",".join("?" for _ in FIELDNAMES)
            values = [rec.get(f) for f in FIELDNAMES]
            self.sqlite_conn.execute(
                f"INSERT INTO cell_data ({','.join(FIELDNAMES)}) VALUES ({placeholders});",
                values,
            )
            self.sqlite_conn.commit()
        if self.kml_file and rec.get("lat") is not None and rec.get("lon") is not None:
            name = rec.get("full_cell_key") or rec.get("device_id")
            desc = json.dumps(rec)
            self.kml_file.write(
                f'<Placemark><name>{name}</name><description><![CDATA[{desc}]]></description>'
                f'<Point><coordinates>{rec.get("lon")},{rec.get("lat")},{rec.get("alt_m") or 0}</coordinates></Point></Placemark>\n'
            )
            self.kml_file.flush()
        if self.gpx_file and rec.get("lat") is not None and rec.get("lon") is not None:
            ele = rec.get("alt_m") or 0
            self.gpx_file.write(
                f'<trkpt lat="{rec.get("lat")}" lon="{rec.get("lon")}"><ele>{ele}</ele></trkpt>\n'
            )
            self.gpx_file.flush()

    def _close_kml(self):
        if self.kml_file:
            self.kml_file.write("</Document></kml>\n")
            self.kml_file.close()

    def _close_gpx(self):
        if self.gpx_file:
            self.gpx_file.write("</trkseg></trk></gpx>\n")
            self.gpx_file.close()

class NmeaBroadcaster:
    def __init__(self, port: int, device_filter: Optional[str] = None):
        self.port = port
        self.device_filter = device_filter
        self.latest_fix: Optional[Dict] = None
        self.clients: List[asyncio.StreamWriter] = []
        self.server: Optional[asyncio.AbstractServer] = None

    async def start(self):
        self.server = await asyncio.start_server(self._handle_client, host="0.0.0.0", port=self.port)
        print(f"NMEA TCP server listening on 0.0.0.0:{self.port}")
        asyncio.create_task(self._pump())

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.clients.append(writer)
        try:
            await writer.drain()
            await reader.read(1)  # wait until client closes
        except Exception:
            pass
        finally:
            try:
                self.clients.remove(writer)
            except ValueError:
                pass
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _pump(self):
        while True:
            await asyncio.sleep(1)
            if not self.latest_fix:
                continue
            sentences = self._sentences(self.latest_fix)
            if not sentences:
                continue
            dead = []
            for w in self.clients:
                try:
                    for line in sentences:
                        w.write((line + "\n").encode())
                    await w.drain()
                except Exception:
                    dead.append(w)
            for w in dead:
                try:
                    self.clients.remove(w)
                except ValueError:
                    pass

    def update(self, device_id: str, msg: Dict):
        if self.device_filter and device_id != self.device_filter:
            return
        if msg.get("lat") is None or msg.get("lon") is None:
            return
        self.latest_fix = {
            "ts": msg.get("ts") or time.time(),
            "lat": msg.get("lat"),
            "lon": msg.get("lon"),
            "alt": msg.get("alt_m"),
            "speed": msg.get("speed_mps"),
            "course": msg.get("bearing_deg"),
            "sats": msg.get("satellites"),
            "acc": msg.get("accuracy_m"),
        }

    def _sentences(self, fix: Dict) -> List[str]:
        gmt = time.gmtime(fix["ts"])
        hhmmss = f"{gmt.tm_hour:02d}{gmt.tm_min:02d}{gmt.tm_sec:02d}"
        date_str = f"{gmt.tm_mday:02d}{gmt.tm_mon:02d}{(gmt.tm_year % 100):02d}"
        lat_str, lat_hemi = nmea_coord(float(fix["lat"]), True)
        lon_str, lon_hemi = nmea_coord(float(fix["lon"]), False)
        sats = int(fix["sats"]) if fix.get("sats") is not None else 8
        hdop = float(fix["acc"]) / 5.0 if fix.get("acc") else 1.0
        alt = float(fix["alt"]) if fix.get("alt") is not None else 0.0
        speed_knots = float(fix["speed"]) * 1.943844 if fix.get("speed") is not None else 0.0
        course = float(fix["course"]) if fix.get("course") is not None else 0.0

        gga_core = f"GPGGA,{hhmmss},{lat_str},{lat_hemi},{lon_str},{lon_hemi},1,{sats:02d},{hdop:.1f},{alt:.1f},M,0.0,M,,"
        rmc_core = f"GPRMC,{hhmmss},A,{lat_str},{lat_hemi},{lon_str},{lon_hemi},{speed_knots:.1f},{course:.1f},{date_str},,"
        return [
            f"${gga_core}*{nmea_checksum(gga_core)}",
            f"${rmc_core}*{nmea_checksum(rmc_core)}",
        ]


async def handle_device(serial: str, outputs: OutputWriters, gps_only: bool = False, nmea: Optional[NmeaBroadcaster] = None):
    # Set up port forwarding so host can reach device-local server.
    print(f"[{serial}] setting adb forward tcp:{PORT} -> tcp:{PORT}")
    subprocess.run(["adb", "-s", serial, "forward", f"tcp:{PORT}", f"tcp:{PORT}"], check=True)
    # Also expose the phone-side NMEA TCP feed (8766) for tools that want direct GPS.
    try:
        print(f"[{serial}] setting adb forward tcp:{NMEA_PHONE_PORT} -> tcp:{NMEA_PHONE_PORT}")
        subprocess.run(
            ["adb", "-s", serial, "forward", f"tcp:{NMEA_PHONE_PORT}", f"tcp:{NMEA_PHONE_PORT}"],
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        print(f"[{serial}] failed to forward NMEA port {NMEA_PHONE_PORT}: {exc}")

    # Best-effort: try to start the foreground service on the device.
    try:
        subprocess.run(
            [
                "adb",
                "-s",
                serial,
                "shell",
                "am",
                "start-foreground-service",
                "-n",
                "com.example.cellstream/.CellStreamService",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        pass

    reader = writer = None
    for attempt in range(1, MAX_CONNECT_RETRIES + 1):
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", PORT)
            break
        except Exception as exc:
            if attempt == MAX_CONNECT_RETRIES:
                print(f"[{serial}] failed to connect to 127.0.0.1:{PORT}: {exc}")
                return
            print(f"[{serial}] connect attempt {attempt} failed, retrying...")
            time.sleep(1)
    if not reader or not writer:
        print(f"[{serial}] could not open connection")
        return
    print(f"[{serial}] connected, waiting for data...")
    try:
        while True:
            line = await reader.readline()
            if not line:
                print(f"[{serial}] connection closed by peer")
                break
            try:
                msg = json.loads(line)
                if nmea:
                    nmea.update(serial, msg)
                cells = [c for c in msg.get("cells", []) if c.get("mcc") and c.get("mnc")]
                if cells:
                    # Choose primary as the first registered; if none registered, first cell.
                    primary = None
                    neighbors: List[Dict] = []
                    for cell in cells:
                        if primary is None and cell.get("registered"):
                            primary = cell
                        else:
                            neighbors.append(cell)
                    if primary is None and cells:
                        primary = cells[0]
                        neighbors = cells[1:]
                    if primary:
                        rec = flatten_record(serial, msg, primary, neighbors)
                        outputs.write(rec)
                        gps_str = ""
                        if msg.get("lat") is not None and msg.get("lon") is not None:
                            gps_str = f" GPS=({msg.get('lat')},{msg.get('lon')} acc={msg.get('accuracy_m')})"
                        ncount = len(neighbors)
                        print(f"[{serial}] {rec.get('rat','?')} {rec.get('full_cell_key')}, RSSI={rec.get('rssi')} neighbors={ncount}{gps_str}")
                elif gps_only and msg.get("lat") is not None and msg.get("lon") is not None:
                    # Emit a GPS-only record when requested
                    rec = flatten_record(serial, msg, {}, [])
                    rec["rat"] = rec.get("rat") or "GPS"
                    rec["full_cell_key"] = rec.get("full_cell_key") or "gps-only"
                    outputs.write(rec)
                    gps_str = f" GPS=({msg.get('lat')},{msg.get('lon')} acc={msg.get('accuracy_m')})"
                    print(f"[{serial}] GPS-only{gps_str}")
            except json.JSONDecodeError:
                print(f"[{serial}] bad JSON: {line!r}")
    except Exception as exc:
        print(f"[{serial}] error: {exc}")
    finally:
        writer.close()
        await writer.wait_closed()
        print(f"[{serial}] disconnected")


async def main():
    parser = argparse.ArgumentParser(description="Collect cell data from Android datasources over adb reverse")
    parser.add_argument("--jsonl", help="Path to append JSONL output")
    parser.add_argument("--csv", help="Path to append CSV output")
    parser.add_argument("--sqlite", help="Path to SQLite database for storage")
    parser.add_argument("--kml", help="Path to KML file to append placemarks")
    parser.add_argument("--gpx", help="Path to GPX file to append trackpoints")
    parser.add_argument("--gps-only", action="store_true", help="Emit GPS-only records when no cell data is present")
    parser.add_argument(
        "--nmea-port",
        type=int,
        help="Serve live NMEA sentences over TCP for Kismet/gpsd (e.g. 31337). Disabled when omitted.",
    )
    parser.add_argument(
        "--nmea-device",
        help="When using --nmea-port, restrict GPS feed to this device serial. Defaults to newest fix from any device.",
    )
    args = parser.parse_args()

    outputs = OutputWriters(args)
    nmea = None
    if args.nmea_port:
        nmea = NmeaBroadcaster(args.nmea_port, device_filter=args.nmea_device)
        await nmea.start()

    tasks = {}
    waiting_printed = False
    while True:
        serials = await list_devices()
        # Start handlers for newly seen devices
        for s in serials:
            if s not in tasks or tasks[s].done():
                print(f"Found device: {s}")
                tasks[s] = asyncio.create_task(handle_device(s, outputs, gps_only=args.gps_only, nmea=nmea))
        # Clean up finished tasks for devices no longer present
        for s, t in list(tasks.items()):
            if t.done():
                tasks.pop(s, None)
        if not serials and not tasks:
            if not waiting_printed:
                print("Waiting for a device to appear over adb...")
                waiting_printed = True
        else:
            waiting_printed = False
        await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())
