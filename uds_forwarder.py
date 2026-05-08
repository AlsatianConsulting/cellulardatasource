#!/usr/bin/env python3
"""
Local TCP -> UNIX socket forwarder for kismet_cap_cell.

Use case: phone connects via adb reverse to 127.0.0.1:<port> on the Pi;
this forwarder relays the TCP stream into the UNIX domain socket that
kismet_cap_cell listens on, so no UDP/TCP port is needed by the capture
daemon itself. The TCP listener is bound to loopback only.
"""
import argparse
import asyncio
import sys


async def handle_client(reader, writer, uds_path: str):
    try:
        uds_reader, uds_writer = await asyncio.open_unix_connection(uds_path)
    except Exception as e:
        sys.stderr.write(f"Failed to connect to UDS {uds_path}: {e}\n")
        writer.close()
        await writer.wait_closed()
        return

    async def pipe(src, dst):
        try:
            while data := await src.read(4096):
                dst.write(data)
                await dst.drain()
        except Exception:
            pass
        finally:
            # Signal EOF and close so the opposite-direction pipe wakes from
            # its blocked read and the gather() below can finish.
            try:
                if dst.can_write_eof():
                    dst.write_eof()
            except Exception:
                pass
            try:
                dst.close()
            except Exception:
                pass

    await asyncio.gather(
        pipe(reader, uds_writer),
        pipe(uds_reader, writer),
    )
    for w in (writer, uds_writer):
        try:
            await w.wait_closed()
        except Exception:
            pass


async def main():
    parser = argparse.ArgumentParser(description="TCP to UDS forwarder")
    parser.add_argument(
        "--tcp-port",
        type=int,
        default=8765,
        help="Loopback TCP port to listen on (default: 8765)",
    )
    parser.add_argument(
        "--uds",
        default="/var/run/kismet/cell.sock",
        help="Path to UNIX domain socket (default: /var/run/kismet/cell.sock)",
    )
    args = parser.parse_args()

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, args.uds),
        host="127.0.0.1",
        port=args.tcp_port,
    )
    addrs = ", ".join(str(s.getsockname()) for s in server.sockets)
    print(f"Forwarding TCP {addrs} -> UDS {args.uds}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
