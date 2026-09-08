#!/usr/bin/env bash
# Lightweight point-in-time snapshot and restore protocol for hub.db
set -euo pipefail

DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
DB_PATH="${HEIMDALL_DB_PATH:-$DATA_DIR/hub.db}"
SNAPSHOT_DIR="$DATA_DIR/snapshots"

mkdir -p "$SNAPSHOT_DIR"
chmod 0700 "$SNAPSHOT_DIR"

ACTION="${1:-export}"

case "$ACTION" in
  export)
    if [ ! -f "$DB_PATH" ]; then
      echo "[-] Error: Database not found at $DB_PATH" >&2
      exit 1
    fi
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    OUT_FILE="${2:-$SNAPSHOT_DIR/hub-$TIMESTAMP.db}"
    echo "[snapshot] Exporting snapshot to $OUT_FILE..."
    if ! command -v sqlite3 >/dev/null 2>&1 || ! sqlite3 "$DB_PATH" ".backup '$OUT_FILE'" 2>/dev/null; then
      cp "$DB_PATH" "$OUT_FILE"
    fi
    chmod 0600 "$OUT_FILE"
    echo "[+] Snapshot successfully exported: $OUT_FILE (chmod 0600)"
    find "$SNAPSHOT_DIR" -name "hub-*.db" -type f -mtime +30 -delete 2>/dev/null || true
    ;;
  restore)
    RESTORE_FILE="${2:-}"
    if [ -z "$RESTORE_FILE" ] || [ ! -f "$RESTORE_FILE" ]; then
      echo "[-] Error: Specify valid snapshot file to restore: $0 restore <snapshot-file>" >&2
      exit 1
    fi
    echo "[snapshot] Restoring database from $RESTORE_FILE to $DB_PATH..."
    mkdir -p "$(dirname "$DB_PATH")"
    cp "$RESTORE_FILE" "$DB_PATH"
    chmod 0600 "$DB_PATH"
    echo "[+] Successfully restored database to $DB_PATH (chmod 0600)"
    ;;
  list)
    echo "[snapshot] Available snapshots in $SNAPSHOT_DIR:"
    ls -lh "$SNAPSHOT_DIR"/hub-*.db 2>/dev/null || echo "  (none)"
    ;;
  *)
    echo "Usage: $0 {export [out_path]|restore <file>|list}"
    exit 1
    ;;
esac
