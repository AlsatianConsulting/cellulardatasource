#!/usr/bin/env python3
"""Standalone phone stream export server.

Receives newline-delimited JSON payloads from the phone stream and writes:
- capture.json (full message objects)
- capture.csv (flattened rows, one row per cell)
- capture.kmz (KML points zipped in KMZ)
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import signal
import socketserver
import threading
import zipfile
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape


def ts_to_iso(ts: Any) -> str:
    try:
        return dt.datetime.fromtimestamp(float(ts), tz=dt.timezone.utc).isoformat()
    except Exception:
        return ""


class ExportWriters:
    CSV_FIELDS = [
        "record_index",
        "ts_epoch",
        "ts_iso",
        "lat",
        "lon",
        "alt_m",
        "accuracy_m",
        "provider",
        "network_type",
        "network_name",
        "satellites",
        "transport_mode",
        "cell_index",
        "rat",
        "registered",
        "mcc",
        "mnc",
        "tac",
        "cid",
        "full_cell_id",
        "enb_id",
        "sector_id",
        "earfcn",
        "nrarfcn",
        "pci",
        "rssi",
        "rsrp",
        "rsrq",
        "snr",
        "timing_advance",
        "band",
        "bandwidth_khz",
        "dl_freq_mhz",
        "ul_freq_mhz",
        "ss_rsrp",
        "ss_rsrq",
        "ss_sinr",
        "nci",
        "vqi",
    ]

    def __init__(self, outdir: Path, prefix: str) -> None:
        self.outdir = outdir
        self.outdir.mkdir(parents=True, exist_ok=True)

        self.json_path = self.outdir / f"{prefix}.json"
        self.csv_path = self.outdir / f"{prefix}.csv"
        self.kml_path = self.outdir / f"{prefix}.kml"
        self.kmz_path = self.outdir / f"{prefix}.kmz"

        self._json_fh = self.json_path.open("w", encoding="utf-8")
        self._csv_fh = self.csv_path.open("w", encoding="utf-8", newline="")
        self._kml_fh = self.kml_path.open("w", encoding="utf-8")

        self._csv_writer = csv.DictWriter(self._csv_fh, fieldnames=self.CSV_FIELDS)
        self._csv_writer.writeheader()

        self._json_first = True
        self._record_index = 0
        self._total_cells = 0

        self._json_fh.write("[\n")
        self._write_kml_header()

    def _write_kml_header(self) -> None:
        self._kml_fh.write(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n"
            "  <Document>\n"
            "    <name>Cellular Capture</name>\n"
        )

    def _write_kml_footer(self) -> None:
        self._kml_fh.write("  </Document>\n</kml>\n")

    def write_record(self, obj: dict[str, Any]) -> None:
        self._record_index += 1
        self._write_json(obj)
        self._write_csv_rows(obj)
        self._write_kml_points(obj)

    def _write_json(self, obj: dict[str, Any]) -> None:
        blob = json.dumps(obj, ensure_ascii=False)
        if self._json_first:
            self._json_fh.write(f"  {blob}")
            self._json_first = False
        else:
            self._json_fh.write(f",\n  {blob}")

    def _write_csv_rows(self, obj: dict[str, Any]) -> None:
        base = {
            "record_index": self._record_index,
            "ts_epoch": obj.get("ts"),
            "ts_iso": ts_to_iso(obj.get("ts")),
            "lat": obj.get("lat"),
            "lon": obj.get("lon"),
            "alt_m": obj.get("alt_m"),
            "accuracy_m": obj.get("accuracy_m"),
            "provider": obj.get("provider"),
            "network_type": obj.get("network_type"),
            "network_name": obj.get("network_name"),
            "satellites": obj.get("satellites"),
            "transport_mode": obj.get("transport_mode"),
        }

        cells = obj.get("cells") or []
        if not isinstance(cells, list):
            cells = []

        if not cells:
            row = dict(base)
            row["cell_index"] = ""
            self._csv_writer.writerow({k: row.get(k, "") for k in self.CSV_FIELDS})
            return

        for idx, cell in enumerate(cells):
            if not isinstance(cell, dict):
                continue
            self._total_cells += 1
            row = dict(base)
            row.update(
                {
                    "cell_index": idx,
                    "rat": cell.get("rat"),
                    "registered": cell.get("registered"),
                    "mcc": cell.get("mcc"),
                    "mnc": cell.get("mnc"),
                    "tac": cell.get("tac"),
                    "cid": cell.get("cid"),
                    "full_cell_id": cell.get("full_cell_id"),
                    "enb_id": cell.get("enb_id"),
                    "sector_id": cell.get("sector_id"),
                    "earfcn": cell.get("earfcn"),
                    "nrarfcn": cell.get("nrarfcn"),
                    "pci": cell.get("pci"),
                    "rssi": cell.get("rssi"),
                    "rsrp": cell.get("rsrp"),
                    "rsrq": cell.get("rsrq"),
                    "snr": cell.get("snr"),
                    "timing_advance": cell.get("timing_advance"),
                    "band": cell.get("band"),
                    "bandwidth_khz": cell.get("bandwidth_khz"),
                    "dl_freq_mhz": cell.get("dl_freq_mhz"),
                    "ul_freq_mhz": cell.get("ul_freq_mhz"),
                    "ss_rsrp": cell.get("ss_rsrp"),
                    "ss_rsrq": cell.get("ss_rsrq"),
                    "ss_sinr": cell.get("ss_sinr"),
                    "nci": cell.get("nci"),
                    "vqi": cell.get("vqi"),
                }
            )
            self._csv_writer.writerow({k: row.get(k, "") for k in self.CSV_FIELDS})

    def _write_kml_points(self, obj: dict[str, Any]) -> None:
        lat = obj.get("lat")
        lon = obj.get("lon")
        if lat is None or lon is None:
            return

        try:
            lat_f = float(lat)
            lon_f = float(lon)
        except Exception:
            return

        alt = obj.get("alt_m")
        try:
            alt_f = float(alt) if alt is not None else 0.0
        except Exception:
            alt_f = 0.0

        ts_iso = ts_to_iso(obj.get("ts"))
        cells = obj.get("cells") or []
        if not isinstance(cells, list):
            cells = []

        if not cells:
            name = escape(f"record-{self._record_index}")
            desc = escape(f"ts={ts_iso}")
            self._kml_fh.write(
                "    <Placemark>\n"
                f"      <name>{name}</name>\n"
                f"      <description>{desc}</description>\n"
                "      <Point>\n"
                f"        <coordinates>{lon_f},{lat_f},{alt_f}</coordinates>\n"
                "      </Point>\n"
                "    </Placemark>\n"
            )
            return

        for idx, cell in enumerate(cells):
            if not isinstance(cell, dict):
                continue
            rat = cell.get("rat") or "CELL"
            cid = cell.get("cid") if cell.get("cid") is not None else cell.get("nci")
            name = escape(f"{rat} #{cid} @ rec {self._record_index}:{idx}")
            desc = {
                "ts": ts_iso,
                "provider": obj.get("provider"),
                "network_type": obj.get("network_type"),
                "mcc": cell.get("mcc"),
                "mnc": cell.get("mnc"),
                "tac": cell.get("tac"),
                "pci": cell.get("pci"),
                "rssi": cell.get("rssi"),
                "rsrp": cell.get("rsrp"),
                "rsrq": cell.get("rsrq"),
                "snr": cell.get("snr"),
            }
            desc_text = escape(json.dumps(desc, ensure_ascii=False))
            self._kml_fh.write(
                "    <Placemark>\n"
                f"      <name>{name}</name>\n"
                f"      <description>{desc_text}</description>\n"
                "      <Point>\n"
                f"        <coordinates>{lon_f},{lat_f},{alt_f}</coordinates>\n"
                "      </Point>\n"
                "    </Placemark>\n"
            )

    def flush(self) -> None:
        self._json_fh.flush()
        self._csv_fh.flush()
        self._kml_fh.flush()

    def close(self) -> None:
        self._json_fh.write("\n]\n")
        self._json_fh.close()
        self._csv_fh.close()
        self._write_kml_footer()
        self._kml_fh.close()

        with zipfile.ZipFile(self.kmz_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.write(self.kml_path, arcname=self.kml_path.name)

        try:
            self.kml_path.unlink()
        except OSError:
            pass

    @property
    def stats(self) -> dict[str, Any]:
        return {
            "records": self._record_index,
            "cell_rows": self._total_cells,
            "json": str(self.json_path),
            "csv": str(self.csv_path),
            "kmz": str(self.kmz_path),
        }


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class StreamHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        server: "PhoneExportServer" = self.server  # type: ignore[assignment]
        peer = f"{self.client_address[0]}:{self.client_address[1]}"
        print(f"[client] connected {peer}")

        buf = b""
        while True:
            chunk = self.request.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self._consume_line(line, server)

        if buf.strip():
            self._consume_line(buf, server)

        print(f"[client] disconnected {peer}")

    def _consume_line(self, line: bytes, server: "PhoneExportServer") -> None:
        raw = line.decode("utf-8", errors="replace").strip()
        if not raw:
            return

        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            with server.lock:
                server.bad_lines += 1
            return

        if not isinstance(obj, dict):
            with server.lock:
                server.bad_lines += 1
            return

        with server.lock:
            server.writers.write_record(obj)
            server.lines_ok += 1
            if server.lines_ok % server.flush_every == 0:
                server.writers.flush()


class PhoneExportServer(ThreadedTCPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[StreamHandler],
        writers: ExportWriters,
        flush_every: int,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.writers = writers
        self.flush_every = max(1, flush_every)
        self.lines_ok = 0
        self.bad_lines = 0
        self.lock = threading.Lock()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Phone stream exporter (JSON/CSV/KMZ)")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=9875, help="Bind port (default: 9875)")
    parser.add_argument(
        "--output-dir",
        default="./exports",
        help="Output directory for capture files (default: ./exports)",
    )
    parser.add_argument(
        "--prefix",
        default=None,
        help="Output file prefix (default: capture-YYYYmmdd-HHMMSS)",
    )
    parser.add_argument(
        "--flush-every",
        type=int,
        default=25,
        help="Flush files every N valid messages (default: 25)",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()

    prefix = args.prefix or f"capture-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    outdir = Path(args.output_dir).expanduser().resolve()

    writers = ExportWriters(outdir=outdir, prefix=prefix)
    server = PhoneExportServer((args.host, args.port), StreamHandler, writers, args.flush_every)
    stop_reason = {"text": "requested"}

    def _handle_signal(signum: int, _frame: Any) -> None:
        sig_name = signal.Signals(signum).name
        stop_reason["text"] = sig_name
        print(f"\\n[stop] signal {sig_name}")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    print(f"[start] listening on {args.host}:{args.port}")
    print(f"[start] writing to {outdir}")
    print(f"[files] {writers.stats}")

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.shutdown()
        server.server_close()
        with server.lock:
            writers.flush()
            writers.close()
            summary = {
                "stop_reason": stop_reason["text"],
                "messages_ok": server.lines_ok,
                "messages_bad": server.bad_lines,
            }
            summary.update(writers.stats)
        print(f"[done] {summary}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
