#!/usr/bin/env bats

#remove_all_monitoring() {
#    run sudo pmm-admin list
#    echo "echo"
#}

DEFAULTS_FILE='/home/sh/sandboxes/msb_5_6_33/my.sandbox.cnf'
MYSQL_SOCK='/tmp/pmm_ps_data/mysql.sock'
MYSQL_USER='root'

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

@test "run pmm-admin without any arguments" {
run sudo pmm-admin
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage:" ]
}

@test "run pmm-admin help" {
run sudo pmm-admin help
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage:" ]
}

@test "run pmm-admin -h" {
run sudo pmm-admin -h
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "Usage:"
}

@test "run pmm-admin with wrong option" {
run sudo pmm-admin install
echo "$output"
    [ "$status" -eq 1 ]
}

#@test "run pmm-admin help" {
#run sudo pmm-admin install
#echo "$output"
#    [ "$status" -eq 1 ]
#}

@test "run pmm-admin ping" {
run sudo pmm-admin ping
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, PMM server is alive." ]
}

@test "run pmm-admin check-network" {
run sudo pmm-admin check-network
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "PMM Network Status" ]
    [ "${lines[11]}" = "Consul API           OK           " ]
    [ "${lines[12]}" = "Prometheus API       OK           " ]
    [ "${lines[13]}" = "Query Analytics API  OK           "  ]
}

@test "run pmm-admin list" {
run sudo pmm-admin list
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "No services under monitoring."
}

@test "run pmm-admin add linux:metrics" {
run sudo pmm-admin add linux:metrics
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, now monitoring this system." ]
}


@test "run pmm-admin add linux:metrics again" {
run sudo pmm-admin add linux:metrics
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "there could be only one instance"
}


@test "run pmm-admin remove linux:metrics" {
run sudo pmm-admin remove linux:metrics
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "OK, removed system"
}


@test "run pmm-admin remove linux:metrics again" {
run sudo pmm-admin remove linux:metrics
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}


@test "run pmm-admin add linux:metrics with given name" {
run sudo pmm-admin add linux:metrics mytest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, now monitoring this system." ]
}

@test "run pmm-admin add linux:metrics with given name again" {
run sudo pmm-admin add linux:metrics mytest1.os1
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "there could be only one instance"
}

@test "run pmm-admin remove linux:metrics with given name" {
run sudo pmm-admin remove linux:metrics mytest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, removed system mytest1.os1 from monitoring." ]
}


@test "run pmm-admin remove linux:metrics with given name again" {
run sudo pmm-admin remove linux:metrics mytest1.os1
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}


## mysql:metrics

@test "run pmm-admin add mysql:metrics" {
run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, now monitoring"
}


@test "run pmm-admin add mysql:metrics again" {
run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Error adding MySQL metrics: there is already one instance with this name under monitoring." ]
}


@test "run pmm-admin remove mysql:metrics" {
run sudo pmm-admin remove mysql:metrics
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "OK, removed MySQL metrics"
}


@test "run pmm-admin remove mysql:metrics again" {
run sudo pmm-admin remove mysql:metrics
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}

@test "run pmm-admin add mysql:metrics with given name" {
run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  mysqltest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, now monitoring MySQL metrics"
}

@test "run pmm-admin add mysql:metrics with given name again" {
run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  mysqltest1.os1
echo "$output"
    [ "$status" -eq 1 ]
		[ "${lines[0]}" = "Error adding MySQL metrics: there is already one instance with this name under monitoring." ]
}

@test "run pmm-admin remove mysql:metrics with given name" {
run sudo pmm-admin remove mysql:metrics mysqltest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql:metrics with given name again" {
run sudo pmm-admin remove mysql:metrics mysqltest1.os1
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}

## mysql:queries

@test "run pmm-admin add mysql:queries" {
run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, now monitoring"
}


@test "run pmm-admin add mysql:queries again" {
run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Error adding MySQL queries: there is already one instance with this name under monitoring." ]
}


@test "run pmm-admin remove mysql:queries" {
run sudo pmm-admin remove mysql:queries
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "OK, removed MySQL queries"
}


@test "run pmm-admin remove mysql:queries again" {
run sudo pmm-admin remove mysql:queries
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}

@test "run pmm-admin add mysql:queries with given name" {
run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  mysqltest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, now monitoring MySQL queries"
}

@test "run pmm-admin add mysql:queries with given name again" {
run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  mysqltest1.os1
echo "$output"
    [ "$status" -eq 1 ]
		[ "${lines[0]}" = "Error adding MySQL queries: there is already one instance with this name under monitoring." ]
}

@test "run pmm-admin remove mysql:queries with given name" {
run sudo pmm-admin remove mysql:queries mysqltest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql:queries with given name again" {
run sudo pmm-admin remove mysql:queries mysqltest1.os1
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "no service found"
}


## add mysql
@test "run pmm-admin add mysql(with hardcoded --defaults-file)[Subject to Change]" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, now"
	echo "${lines[1]}" | grep "OK, now"
	echo "${lines[2]}" | grep "OK, now"
}

@test "run pmm-admin add mysql(with hardcoded --defaults-file)[Subject to Change] again" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, already"
	echo "${lines[1]}" | grep "OK, already"
	echo "${lines[2]}" | grep "OK, already"
}

@test "run pmm-admin remove mysql[see above how it was added]" {
run sudo pmm-admin remove mysql
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, removed"
	echo "${lines[1]}" | grep "OK, removed"
	echo "${lines[2]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql[see above how it was added] again" {
run sudo pmm-admin remove mysql
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, no"
	echo "${lines[1]}" | grep "OK, no"
	echo "${lines[2]}" | grep "OK, no"
}

@test "run pmm-admin add mysql(with hardcoded --defaults-file) with given name[Subject to Change]" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, now"
	echo "${lines[1]}" | grep "OK, now"
	echo "${lines[2]}" | grep "OK, now"
}

@test "run pmm-admin add mysql(with hardcoded --defaults-file) with given name[Subject to Change] again" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, already"
	echo "${lines[1]}" | grep "OK, already"
	echo "${lines[2]}" | grep "OK, already"
}

@test "run pmm-admin remove mysql with given name[see above how it was added]" {
run sudo pmm-admin remove mysql msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, removed"
	echo "${lines[1]}" | grep "OK, removed"
	echo "${lines[2]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql with given name[see above how it was added] again" {
run sudo pmm-admin remove mysql msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, no"
	echo "${lines[1]}" | grep "OK, no"
	echo "${lines[2]}" | grep "OK, no"
}


@test "run pmm-admin list to check for available services" {
run sudo pmm-admin list
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "No services under monitoring."
}


@test "run pmm-admin info" {
run sudo pmm-admin info
echo $output
	[ "$status" -eq 0 ]
	echo "${output}" | grep "Go Version"
}


@test "run pmm-admin show-passwords" {
run sudo pmm-admin show-passwords
echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "HTTP basic authentication" ]
}


@test "run pmm-admin --version" {
run sudo pmm-admin --version
echo "$output"
	[ "$status" -eq 0 ]
	echo "$output" | grep "1.0"
}


@test "run pmm-admin start without service type" {
run sudo pmm-admin start
echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "No service type specified." ]
}


@test "run pmm-admin stop without service type" {
run sudo pmm-admin stop
echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "No service type specified." ]
}


@test "run pmm-admin restart without service type" {
run sudo pmm-admin restart
echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "No service type specified." ]
}


@test "run pmm-admin purge without service type" {
run sudo pmm-admin purge
echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "No service type specified." ]
}


@test "run pmm-admin config without parameters" {
run sudo pmm-admin config
echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "OK, PMM server is alive." ]
}
