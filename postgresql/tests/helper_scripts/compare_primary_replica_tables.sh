#!/bin/bash

# Configuration
INSTALL_DIR="/home/mohit.joshi/postgresql/pg_tde/bld_tde/install"
PRIMARY_PORT="5432"
REPLICA_PORT="5433"
DB_NAME="sbtest"

# Track mismatch status
MISMATCH_FOUND=0

echo "🔍 Checking row counts for tables ddl_test_1 to ddl_test_500..."

# Loop through table names from ddl_test_1 to ddl_test_500
for i in $(seq 1 500); do
    TABLE="ddl_test_$i"

    # Get row count from Primary
    PRIMARY_COUNT=$($INSTALL_DIR/bin/psql -p $PRIMARY_PORT -d $DB_NAME -t -c \
    "SELECT COUNT(*) FROM $TABLE;" | tr -d '[:space:]')

    # Get row count from Replica
    REPLICA_COUNT=$($INSTALL_DIR/bin/psql -p $REPLICA_PORT -d $DB_NAME -t -c \
    "SELECT COUNT(*) FROM $TABLE;" | tr -d '[:space:]')

    # Compare counts
    if [[ "$PRIMARY_COUNT" -ne "$REPLICA_COUNT" ]]; then
        echo "❌ Mismatch in table '$TABLE': Primary=$PRIMARY_COUNT, Replica=$REPLICA_COUNT"
        MISMATCH_FOUND=1
    else
        echo "✅ Table '$TABLE' matches: $PRIMARY_COUNT rows"
    fi
done

# Exit with error if any mismatch is found
if [[ "$MISMATCH_FOUND" -eq 1 ]]; then
    echo "🚨 Row count mismatch detected in one or more tables!"
    exit 1
else
    echo "🎉 All tables match perfectly!"
    exit 0
fi

