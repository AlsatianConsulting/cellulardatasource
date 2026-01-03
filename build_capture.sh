#!/usr/bin/env bash
set -euo pipefail
SRC_DIR=$(cd -- "$(dirname "$0")" && pwd)
cd "$SRC_DIR"
cc \
  -Ivendor -Ivendor/protobuf_c_1005000 \
  capture_cell.c \
  vendor/capture_framework.c \
  vendor/simple_ringbuf_c.c \
  vendor/kis_external_packet.c \
  vendor/mpack/mpack.c \
  vendor/version_stub.c \
  vendor/protobuf_c_1005000/*.c \
  -lpthread -lprotobuf-c -o kismet_cap_cell_capture
