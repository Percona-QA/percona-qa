#!/bin/bash
#
# Regression-style checks for SMGR heap encryption (PR #554 / PG-2278):
# reused OpenSSL CBC cipher contexts on read/write paths.
#
# Covers: bulk heaps, interleaved scans, UPDATE/DELETE/VACUUM, restart snapshot,
# range-partitioned tde_heap, TOAST-heavy rows, CTAS + savepoint rollback,
# TRUNCATE + reload, REINDEX + CLUSTER, index-preferred reads, multi-table scan fan-in,
# bulk COPY / wide-row INSERT paths, and sequential scans with working set >> shared_buffers
# (SMGR encrypt/decrypt off disk when pages are not cached).
#
# Performance A/B (manual): compare the same build before/after the SMGR cipher-context change,
# or two installs, with SMGR_CIPHER_LOG_BULK_TIMING=1 so one cold full-seqscan pass logs wall time.
# CI here focuses on correctness; tiny shared_buffers + heap_blks_read checks stress the path.
#
# Run via postgresql/automation/wrapper/test_runner.sh, for example:
#   ./wrapper/test_runner.sh --server_build_path /path/to/pg/install --testname test_smgr_cipher_context_reuse.sh

if [[ "$PG_MAJOR" -lt 17 ]]; then
    echo "SKIP: specifying USING tde_heap on partitioned tables is not supported on PG ${PG_MAJOR} (requires PG 17+)"
    exit 0
fi

KEYFILE="${RUN_DIR}/smgr_cipher_ctx.keyring.per"

log() {
	echo "[$(date '+%H:%M:%S')] $*"
}

stop_cipher_suite_pg() {
	if [[ -n "${PGDATA:-}" && -f "$PGDATA/postmaster.pid" ]]; then
		"$INSTALL_DIR/bin/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1 || true
	fi
}

# --- Run one full cycle with a given CBC key size (must match pg_tde.cipher at first use). ---
run_cipher_suite() {
	local cipher="$1"
	local label="$2"

	log "=== Suite: $label (pg_tde.cipher=$cipher) ==="

	stop_cipher_suite_pg
	rm -f "$KEYFILE"
	mkdir -p "$(dirname "$KEYFILE")"
	touch "$KEYFILE"
	chmod 600 "$KEYFILE" 2>/dev/null || true

	initialize_server "$PGDATA" "$PORT"
	enable_pg_tde "$PGDATA"
	echo "pg_tde.cipher = '$cipher'" >>"$PGDATA/postgresql.conf"
	# Keep most encrypted heap pages out of shared buffers so bulk seqscans hit SMGR read/decrypt.
	echo "shared_buffers = 2MB" >>"$PGDATA/postgresql.conf"

	start_pg "$PGDATA" "$PORT"

	if [[ ! -f "$KEYFILE" ]]; then
		echo "error: keyring file was not created: $KEYFILE" >&2
		return 1
	fi

	# Use a shell-expanded heredoc for the keyring path so the backend sees a
	# normal absolute path. (psql :'var' with -v path="'...'" can produce a
	# path the server cannot open — "No such file or directory".)
	case $KEYFILE in
		*\'*)
			echo "error: KEYFILE path must not contain single quotes: $KEYFILE" >&2
			return 1
			;;
	esac

	"$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<EOSQL
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_database_key_provider_file('smgr-ctx-test', '$KEYFILE');
SELECT pg_tde_create_key_using_database_key_provider('smgr-ctx-key', 'smgr-ctx-test');
SELECT pg_tde_set_key_using_database_key_provider('smgr-ctx-key', 'smgr-ctx-test');

-- Two heap relations with different internal keys (exercises per-relation key + IV on same process-wide CBC ctx).
CREATE TABLE ctx_heap_a (
	id int NOT NULL,
	payload text NOT NULL,
	PRIMARY KEY (id)
) USING tde_heap;

CREATE TABLE ctx_heap_b (
	id int NOT NULL,
	payload text NOT NULL,
	PRIMARY KEY (id)
) USING tde_heap;

INSERT INTO ctx_heap_a
SELECT i, repeat(md5(i::text), 8)
FROM generate_series(1, 60000) AS i;

INSERT INTO ctx_heap_b
SELECT i, repeat(md5((i + 100000)::text), 8)
FROM generate_series(1, 30000) AS i;

-- Interleaved reads (different keys / IVs, same reused EVP_CIPHER_CTX per key length).
-- In an unquoted heredoc, bash would expand $$ to the PID; keep literal $$ for PL/pgSQL.
DO \$\$
BEGIN
	FOR _pass IN 1..40 LOOP
		PERFORM count(*) FROM ctx_heap_a WHERE id % 97 = 0;
		PERFORM sum(length(payload)) FROM ctx_heap_b WHERE id % 89 = 0;
		PERFORM avg(id::float8) FROM ctx_heap_a;
		PERFORM max(id) FROM ctx_heap_b;
	END LOOP;
END \$\$;

-- Writes re-encrypt through SMGR.
UPDATE ctx_heap_a SET payload = repeat('Z', 128) WHERE id % 1009 = 0;
UPDATE ctx_heap_b SET payload = repeat('Q', 128) WHERE id % 1013 = 0;

DELETE FROM ctx_heap_a WHERE id % 4001 = 0;
DELETE FROM ctx_heap_b WHERE id % 4003 = 0;

VACUUM ctx_heap_a, ctx_heap_b;
EOSQL

	log "Running extended scenarios (partitions, TOAST, CTAS/savepoints, TRUNCATE, REINDEX/CLUSTER, index scans)..."
	"$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<'EOSQL2'
-- Partitioned table: multiple encrypted heap forks / relation keys in one query tree
CREATE TABLE ctx_part (
	k int NOT NULL,
	v text NOT NULL,
	PRIMARY KEY (k)
) PARTITION BY RANGE (k) USING tde_heap;

CREATE TABLE ctx_part_p1 PARTITION OF ctx_part FOR VALUES FROM (MINVALUE) TO (5000) USING tde_heap;
CREATE TABLE ctx_part_p2 PARTITION OF ctx_part FOR VALUES FROM (5000) TO (10000) USING tde_heap;
CREATE TABLE ctx_part_p3 PARTITION OF ctx_part FOR VALUES FROM (10000) TO (MAXVALUE) USING tde_heap;

INSERT INTO ctx_part
SELECT i, repeat(md5(i::text), 6)
FROM generate_series(1, 12000) AS i;

UPDATE ctx_part SET v = repeat('P', 96) WHERE k % 1777 = 0;

-- Large values -> TOAST external storage on encrypted heap
CREATE TABLE ctx_toast (
	id int PRIMARY KEY,
	blob text NOT NULL
) USING tde_heap;

INSERT INTO ctx_toast
SELECT i, repeat(chr(65 + (i % 26)), 9500)
FROM generate_series(1, 250) AS i;

DO $$
BEGIN
	FOR _pass IN 1..15 LOOP
		PERFORM sum(length(blob)) FROM ctx_toast WHERE id % 11 <> 0;
		PERFORM count(*) FROM ctx_part WHERE k % 13 = 0;
	END LOOP;
END $$;

-- CTAS from encrypted heap; transaction + savepoint (abort partial rewrite)
CREATE TABLE ctx_ctas
USING tde_heap AS
SELECT id, payload FROM ctx_heap_a WHERE id <= 500;

ALTER TABLE ctx_ctas ADD PRIMARY KEY (id);

INSERT INTO ctx_ctas VALUES (999001, repeat('S', 128));

BEGIN;
SAVEPOINT sp_ctx_ctas;
UPDATE ctx_ctas SET payload = repeat('!', 128) WHERE id = 1;
ROLLBACK TO SAVEPOINT sp_ctx_ctas;
COMMIT;

-- TRUNCATE then refill (new storage / keys lifecycle)
CREATE TABLE ctx_trunc (
	n int PRIMARY KEY,
	note text NOT NULL
) USING tde_heap;

INSERT INTO ctx_trunc
SELECT g, repeat('n', 72)
FROM generate_series(1, 9000) AS g;

TRUNCATE ctx_trunc;

INSERT INTO ctx_trunc VALUES (7, 'trunc-reload');

-- Physical reorder / rebuild paths still decrypt correctly
REINDEX TABLE ctx_heap_b;
CLUSTER ctx_heap_b USING ctx_heap_b_pkey;

ANALYZE ctx_heap_a, ctx_heap_b, ctx_part, ctx_toast, ctx_ctas, ctx_trunc;

-- Prefer index scans for one subtree (heap pages still decrypted via lookups)
SET enable_seqscan = off;
SELECT count(*)::bigint, sum(id::bigint), max(length(payload))
FROM ctx_heap_a
WHERE id BETWEEN 50 AND 2500;
RESET enable_seqscan;

-- Heavy interleave across relations (executor + SMGR round-robin)
SELECT (
	SELECT coalesce(sum(cnt), 0)
	FROM (
		SELECT count(*) AS cnt FROM ctx_part WHERE k % 3 = 0
		UNION ALL
		SELECT count(*) FROM ctx_toast WHERE id % 5 = 0
		UNION ALL
		SELECT count(*) FROM ctx_ctas WHERE id % 7 = 0
		UNION ALL
		SELECT count(*) FROM ctx_trunc
		UNION ALL
		SELECT count(*) FROM ctx_heap_a WHERE id % 17 = 0
		UNION ALL
		SELECT count(*) FROM ctx_heap_b WHERE id % 19 = 0
	) q
) AS interleaved_scan_total;

VACUUM ctx_part, ctx_toast, ctx_ctas, ctx_trunc;
EOSQL2

	log "Running bulk I/O scenarios (wide rows, large seqscans, COPY, cold-cache-oriented passes)..."
	local bulk_statio_reset_sql=""
	# Per-table I/O stat reset is PG14+; keep bulk workload on older versions without it.
	if [[ "$(get_pg_major_version)" -ge 14 ]]; then
		bulk_statio_reset_sql="
SELECT pg_stat_reset_single_table_counters(c.oid)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('ctx_bulk_wide', 'ctx_bulk_seq', 'ctx_heap_a', 'ctx_heap_b');

CHECKPOINT;
"
	fi
	# shellcheck disable=SC2016 - ${bulk_statio_reset_sql} is intentional SQL injection from this script
	"$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<EOSQL_BULK
-- Wide payloads: more heap pages per row count (bulk SMGR encrypt on insert / decrypt on scan).
CREATE TABLE ctx_bulk_wide (
	id int PRIMARY KEY,
	payload text NOT NULL
) USING tde_heap;

INSERT INTO ctx_bulk_wide
SELECT i, repeat(md5(i::text), 32)
FROM generate_series(1, 20000) AS i;

-- Many narrower rows: sequential scan decrypt fan-out.
CREATE TABLE ctx_bulk_seq (
	id int PRIMARY KEY,
	payload text NOT NULL
) USING tde_heap;

INSERT INTO ctx_bulk_seq
SELECT i, repeat(chr(48 + (i % 10)), 120)
FROM generate_series(1, 45000) AS i;

CHECKPOINT;
${bulk_statio_reset_sql}
-- Full-table sequential scans with working set >> shared_buffers (pages miss cache, SMGR reads).
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_heap_a;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_bulk_seq;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_bulk_wide;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_heap_b;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_heap_a;

DO \$\$
BEGIN
	FOR _pass IN 1..8 LOOP
		PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_bulk_seq;
		PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_heap_a;
		PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_bulk_wide;
		PERFORM sum(id::bigint), sum(length(payload)::bigint) FROM ctx_heap_b;
	END LOOP;
END \$\$;

VACUUM ctx_bulk_wide, ctx_bulk_seq;
EOSQL_BULK

	# Server-side COPY into encrypted heap (bulk write / encrypt path).
	{
		echo "CREATE TABLE ctx_copy_load (id int PRIMARY KEY, payload text NOT NULL) USING tde_heap;"
		echo "COPY ctx_copy_load FROM STDIN;"
		for ((_i = 1; _i <= 4000; _i++)); do
			printf '%s\t%s\n' "$_i" "$(printf 'c%.0s' {1..128})"
		done
		printf '%s\n' '\.'
	} | "$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres

	if [[ "${SMGR_CIPHER_LOG_BULK_TIMING:-0}" == "1" ]]; then
		log "SMGR_CIPHER_LOG_BULK_TIMING: cold seqscan pass (wall-clock via psql \\timing)"
		if [[ "$(get_pg_major_version)" -ge 14 ]]; then
			"$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<'EOSQL_TIME'
\timing on
CHECKPOINT;
SELECT pg_stat_reset_single_table_counters('ctx_bulk_seq'::regclass);
CHECKPOINT;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_bulk_seq;
\timing off
EOSQL_TIME
		else
			"$INSTALL_DIR/bin/psql" -X -v ON_ERROR_STOP=1 -d postgres <<'EOSQL_TIME'
\timing on
CHECKPOINT;
SELECT sum(length(payload))::bigint, count(*)::bigint FROM ctx_bulk_seq;
\timing off
EOSQL_TIME
		fi
	fi

	# After reset + full seqscans, heap blocks should have been read from storage (not buffer-only).
	if [[ "$(get_pg_major_version)" -ge 14 ]]; then
		local io_chk
		io_chk="$("$INSTALL_DIR/bin/psql" -X -Atq -d postgres -v ON_ERROR_STOP=1 -c "
SELECT COALESCE(bool_and(s.heap_blks_read > 0), false)
FROM pg_statio_user_tables s
JOIN pg_class c ON c.oid = s.relid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname IN ('ctx_bulk_seq', 'ctx_heap_a');
")"
		if [[ "$io_chk" != "t" ]]; then
			echo "error: expected heap_blks_read > 0 after bulk cold-oriented scans ($label)" >&2
			"$INSTALL_DIR/bin/psql" -X -d postgres -c "
SELECT c.relname, s.heap_blks_read, s.heap_blks_hit
FROM pg_statio_user_tables s
JOIN pg_class c ON c.oid = s.relid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname IN ('ctx_bulk_seq', 'ctx_heap_a')
ORDER BY 1;
" >&2 || true
			return 1
		fi
	fi

	# --- Heap must be marked encrypted; row values must match (decrypt + logic OK). ---
	verify_encryption_and_data() {
		local got
		got="$("$INSTALL_DIR/bin/psql" -X -Atq -d postgres -v ON_ERROR_STOP=1 -c "
SELECT COALESCE(
	(SELECT bool_and(pg_tde_is_encrypted(relname::regclass))
	 FROM (VALUES ('ctx_heap_a'), ('ctx_heap_b'),
			('ctx_heap_a_pkey'), ('ctx_heap_b_pkey')) v (relname))
	AND (SELECT c.relam = (SELECT oid FROM pg_am WHERE amname = 'tde_heap')
		 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = 'public' AND c.relname = 'ctx_heap_a')
	AND (SELECT c.relam = (SELECT oid FROM pg_am WHERE amname = 'tde_heap')
		 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		 WHERE n.nspname = 'public' AND c.relname = 'ctx_heap_b')
	AND (SELECT (SELECT payload FROM ctx_heap_a WHERE id = 1) = repeat(md5(1::text), 8))
	AND (SELECT (SELECT payload FROM ctx_heap_b WHERE id = 1) = repeat(md5(100001::text), 8))
	AND (SELECT (SELECT payload FROM ctx_heap_a WHERE id = 1009) = repeat('Z', 128))
	AND (SELECT (SELECT payload FROM ctx_heap_b WHERE id = 1013) = repeat('Q', 128))
	AND (SELECT NOT EXISTS (SELECT 1 FROM ctx_heap_a WHERE id = 4001))
	AND (SELECT NOT EXISTS (SELECT 1 FROM ctx_heap_b WHERE id = 4003))
, false);
")"
		if [[ "$got" != "t" ]]; then
			echo "error: encryption or data content check failed for $label (expected t, got '${got:-<empty>}/NULL')" >&2
			"$INSTALL_DIR/bin/psql" -X -d postgres -c "
SELECT relname, pg_tde_is_encrypted(relname::regclass) AS is_enc
FROM (VALUES ('ctx_heap_a'), ('ctx_heap_b'),
	  ('ctx_heap_a_pkey'), ('ctx_heap_b_pkey')) v (relname);
SELECT relname, (SELECT amname FROM pg_am WHERE oid = c.relam) AS am
FROM pg_class c WHERE relname IN ('ctx_heap_a', 'ctx_heap_b') ORDER BY 1;
" >&2 || true
			return 1
		fi
		return 0
	}

	verify_extended_scenarios() {
		local got
		got="$("$INSTALL_DIR/bin/psql" -X -Atq -d postgres -v ON_ERROR_STOP=1 -c "
SELECT COALESCE(
	(SELECT bool_and(pg_tde_is_encrypted(relname::regclass))
	 FROM (VALUES
		('ctx_part'), ('ctx_part_p1'), ('ctx_part_p2'), ('ctx_part_p3'),
		('ctx_toast'), ('ctx_ctas'), ('ctx_trunc'),
		('ctx_bulk_wide'), ('ctx_bulk_seq'), ('ctx_copy_load'),
		('ctx_part_pkey'), ('ctx_toast_pkey'), ('ctx_ctas_pkey'), ('ctx_trunc_pkey'),
		('ctx_bulk_wide_pkey'), ('ctx_bulk_seq_pkey'), ('ctx_copy_load_pkey'),
		('ctx_part_p1_pkey'), ('ctx_part_p2_pkey'), ('ctx_part_p3_pkey')
	 ) v (relname))
	AND (SELECT count(*) = 12000 FROM ctx_part)
	AND (SELECT sum(k::bigint) = 72006000::bigint FROM ctx_part)
	AND (SELECT bool_and(length(v) = 96) FROM ctx_part WHERE k % 1777 = 0)
	AND (SELECT bool_and(length(v) = 192) FROM ctx_part WHERE k % 1777 <> 0)
	AND (SELECT count(*) = 250 AND min(length(blob)) = 9500 AND max(length(blob)) = 9500 FROM ctx_toast)
	AND (SELECT (SELECT payload FROM ctx_ctas WHERE id = 1) = repeat(md5(1::text), 8))
	AND (SELECT (SELECT payload FROM ctx_ctas WHERE id = 999001) = repeat('S', 128))
	AND (SELECT count(*) = 501 FROM ctx_ctas)
	AND (SELECT count(*) = 1 AND max(note) = 'trunc-reload' AND max(n) = 7 FROM ctx_trunc)
	AND (SELECT count(*) = 20000 AND sum(length(payload)::bigint) = 20480000::bigint FROM ctx_bulk_wide)
	AND (SELECT count(*) = 45000 AND sum(length(payload)::bigint) = 5400000::bigint FROM ctx_bulk_seq)
	AND (SELECT count(*) = 4000 AND min(length(payload)) = 128 AND max(length(payload)) = 128 FROM ctx_copy_load)
	AND (SELECT (SELECT payload FROM ctx_copy_load WHERE id = 1) = repeat('c', 128))
, false);
")"
		if [[ "$got" != "t" ]]; then
			echo "error: extended scenario verification failed for $label" >&2
			return 1
		fi
		return 0
	}

	if ! verify_encryption_and_data; then
		return 1
	fi
	if ! verify_extended_scenarios; then
		return 1
	fi
	log "Verified core + extended tables (partitions, TOAST, CTAS, TRUNCATE) and row payloads."

	# Aggregates from encrypted heaps (SMGR decrypt on sequential scan).
	read_heap_stats() {
		"$INSTALL_DIR/bin/psql" -X -Atq -F'|' -d postgres -v ON_ERROR_STOP=1 -c "
SELECT 'a', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_heap_a
UNION ALL
SELECT 'b', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_heap_b
UNION ALL
SELECT 'part', count(*)::text, sum(k::bigint)::text, sum(length(v))::text FROM ctx_part
UNION ALL
SELECT 'toast', count(*)::text, sum(id::bigint)::text, sum(length(blob))::text FROM ctx_toast
UNION ALL
SELECT 'ctas', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_ctas
UNION ALL
SELECT 'trunc', count(*)::text, sum(n::bigint)::text, sum(length(note))::text FROM ctx_trunc
UNION ALL
SELECT 'bulk_wide', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_bulk_wide
UNION ALL
SELECT 'bulk_seq', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_bulk_seq
UNION ALL
SELECT 'copy_load', count(*)::text, sum(id::bigint)::text, sum(length(payload))::text FROM ctx_copy_load
ORDER BY 1;
"
	}

	local expected
	expected="$(read_heap_stats)"
	if [[ -z "$expected" ]]; then
		echo "error: empty heap stats snapshot" >&2
		return 1
	fi

	log "Restarting server (reloads pg_tde / AesInit, reuses CBC contexts after restart)..."
	stop_cipher_suite_pg
	start_pg "$PGDATA" "$PORT"

	local after
	after="$(read_heap_stats)"

	if ! verify_encryption_and_data; then
		return 1
	fi
	if ! verify_extended_scenarios; then
		return 1
	fi

	if [[ "$expected" != "$after" ]]; then
		echo "error: heap aggregate mismatch after restart for $label" >&2
		echo "before restart:" >&2
		echo "$expected" >&2
		echo "after restart:" >&2
		echo "$after" >&2
		return 1
	fi

	stop_cipher_suite_pg
	log "Suite OK: $label"
}

old_server_cleanup "$PGDATA"
rm -f "$KEYFILE" || true

log "Using PGDATA=$PGDATA PORT=$PORT KEYFILE=$KEYFILE INSTALL_DIR=$INSTALL_DIR"
stop_cipher_suite_pg
run_cipher_suite "aes_128" "AES-128 CBC (ctx_cbc_128)"
run_cipher_suite "aes_256" "AES-256 CBC (ctx_cbc_256)"
log "All SMGR cipher context reuse checks passed."
