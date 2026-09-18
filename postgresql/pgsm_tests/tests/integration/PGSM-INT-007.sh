#!/usr/bin/env bash

TEST_ID="PGSM-INT-007"
TEST_NAME="Verify temporary table operations are tracked"
TEST_SUITE="integration"

test_body()
{
    local result

    pgsm_reset || return 1

    if ! execute_sql_session >/dev/null <<'EOF'
CREATE TEMP TABLE pgsm_int_007_temp (
    id integer,
    value text
);

INSERT INTO pgsm_int_007_temp
VALUES (1, 'pgsm_int_007');

SELECT id
FROM pgsm_int_007_temp
WHERE value = 'pgsm_int_007';

DROP TABLE pgsm_int_007_temp;
EOF
    then
        log_error "Unable to execute temporary table workload"
        return 1
    fi

    result="$(
        pgsm_query \
            "SELECT query
               FROM pg_stat_monitor
              WHERE query LIKE '%pgsm_int_007%'
              LIMIT 20"
    )" || {
        log_error "Unable to query pg_stat_monitor"
        return 1
    }

    assert_not_empty \
        "Temporary table workload is tracked" \
        "${result}" || return 1

    return 0
}
