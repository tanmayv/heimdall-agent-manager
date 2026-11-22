#!/bin/sh
# Builds check.c against the flake's nats.c and runs it against the flake's nats-server.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
OUT="$HOME/.cache/heimdall-tests/s1-natscheck-$$"
mkdir -p "$OUT/store"
cc -std=c11 -Wall -o "$OUT/check" "$D/check.c" -lnats_static -lssl -lcrypto -lpthread
nats-server -js -a 127.0.0.1 -p 14333 -sd "$OUT/store" >"$OUT/server.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$OUT"' EXIT
sleep 1
nats-server --version
"$OUT/check" nats://127.0.0.1:14333
