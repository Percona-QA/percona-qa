#!/bin/bash

INSTALL_DIR=$HOME/postgresql/bld_18.1.1/install
TDE_KEY_DIR="$INSTALL_DIR/data/pg_tde"
WAL_DIR="$INSTALL_DIR/data/pg_wal"
PG_TDE_WALDUMP="$INSTALL_DIR/bin/pg_tde_waldump"

# Loop over all WAL files in the WAL directory
for wal_file in "$WAL_DIR"/*; do
  # Extract just the filename
  wal_filename=$(basename "$wal_file")

  if [ -d "$wal_file" ]; then
    echo "Skipping directory: $(basename "$wal_file")"
    continue
  fi

  echo "Processing WAL file: $wal_filename"
  $PG_TDE_WALDUMP -k "$TDE_KEY_DIR" -p "$WAL_DIR" "$wal_filename" | head -n10

  echo "-------------------------------------------------"
done
