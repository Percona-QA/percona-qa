#!/usr/bin/env bats

## postgresql:metrics


PGSQL_USER='psql'
PGSQL_HOST='localhost'
PGSQL_SOCK=5432

@test "run pmm-admin under regular(non-root) user privileges" {
if [[ $(id -u) -eq 0 ]] ; then
	skip "Skipping this test, because you are running under root"
fi
run pmm-admin
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "pmm-admin requires superuser privileges to manage system services." ]
}


@test "run pmm-admin under root privileges" {
if [[ $(id -u) -ne 0 ]] ; then
	skip "Skipping this test, because you are NOT running under root"
fi
run pmm-admin
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage:" ]
}


@test "run pmm-admin add postgresql:metrics based on running intsances" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "postgresql:metrics" | sed 's|.*(||;s|)||' | wc -l)
	for i in $(seq ${CURRENT_COUNT}); do
		let COUNTER=COUNTER+1
		run sudo pmm-admin add postgresql:metrics --port=${PGSQL_SOCK} --user=${PGSQL_USER} pgsql_metrics_$COUNTER
		echo "$output"
		[ "$status" -eq 0 ]
		echo "${lines[0]}" | grep "OK, now monitoring"
	done
}

@test "run pmm-admin add postgresql:metrics again based on running instances" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "pgsql_metrics_" | grep -Eo '\/.*\)' | sed 's/)$//' | wc -l)
	for i in $(seq ${CURRENT_COUNT}); do
		let COUNTER=COUNTER+1
		run sudo pmm-admin add postgresql:metrics --user=${PGSQL_USER} --port=${PGSQL_SOCK} pgsql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 1 ]
			[ "${lines[0]}" = "Error adding PostgreSQL metrics: there is already one instance with this name under monitoring." ]
	done
}


@test "run pmm-admin remove postgresql:metrics" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "pgsql_metrics_" | wc -l)
	for i in $(seq ${CURRENT_COUNT}) ; do
		let COUNTER=COUNTER+1
		run sudo pmm-admin remove postgresql:metrics pgsql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "OK, removed PostgreSQL metrics"
	done
}


@test "run pmm-admin remove postgresql:metrics again" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "pgsql_metrics_") ; do
		let COUNTER=COUNTER+1
		run sudo pmm-admin remove postgresql:metrics pgsql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "no service found"
	done
}

## add postgresql

@test "run pmm-admin add postgresql" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "postgresql:metrics" | sed 's|.*(||;s|).*||' | wc -l)
	for i in $(seq ${CURRENT_COUNT}) ; do
		let COUNTER=COUNTER+1
		run sudo pmm-admin add postgresql --user=${PGSQL_USER} --port=${PGSQL_SOCK} postgresql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, already"
			echo "${lines[1]}" | grep "OK, now"
	done
}

@test "run pmm-admin add postgresql again" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "postgresql:metrics" | grep "postgresql_" | sed 's|.*(||;s|).*||')
	for i in $(seq ${CURRENT_COUNT}); do
		let COUNTER=COUNTER+1
		run sudo pmm-admin add postgresql --user=${PGSQL_USER} --port=${PGSQL_SOCK} postgresql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, already"
			echo "${lines[1]}" | grep "OK, already"
	done
}

@test "run pmm-admin remove postgresql" {
	COUNTER=0
	CURRENT_COUNT=$(sudo pmm-admin list | grep "postgresql:metrics" | grep "postgresql_" | sed 's|.*(||;s|).*||')
	for i in $(seq ${CURRENT_COUNT}); do
		let COUNTER=COUNTER+1
		run sudo pmm-admin remove postgresql postgresql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, no system"
			echo "${lines[1]}" | grep "OK, removed"
	done

}

function teardown() {
	echo "$output"
}