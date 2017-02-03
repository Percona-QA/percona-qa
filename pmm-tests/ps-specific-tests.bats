#!/usr/bin/env bats

## mysql:metrics


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




	@test "run pmm-admin add mysql:metrics" {
		for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
			MYSQL_SOCK=${i}
			run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
			echo "$output"
	    	[ "$status" -eq 0 ]
	    	echo "${lines[0]}" | grep "OK, now monitoring"
		done
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
@test "run pmm-admin add mysql" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, now"
	echo "${lines[1]}" | grep "OK, now"
	echo "${lines[2]}" | grep "OK, now"
}

@test "run pmm-admin add mysql again" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, already"
	echo "${lines[1]}" | grep "OK, already"
	echo "${lines[2]}" | grep "OK, already"
}

@test "run pmm-admin remove mysql" {
run sudo pmm-admin remove mysql
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, removed"
	echo "${lines[1]}" | grep "OK, removed"
	echo "${lines[2]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql again" {
run sudo pmm-admin remove mysql
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, no"
	echo "${lines[1]}" | grep "OK, no"
	echo "${lines[2]}" | grep "OK, no"
}

@test "run pmm-admin add mysql with given name" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, now"
	echo "${lines[1]}" | grep "OK, now"
	echo "${lines[2]}" | grep "OK, now"
}

@test "run pmm-admin add mysql with given name again" {
run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK}  msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, already"
	echo "${lines[1]}" | grep "OK, already"
	echo "${lines[2]}" | grep "OK, already"
}

@test "run pmm-admin remove mysql with given name" {
run sudo pmm-admin remove mysql msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, removed"
	echo "${lines[1]}" | grep "OK, removed"
	echo "${lines[2]}" | grep "OK, removed"
}


@test "run pmm-admin remove mysql with given name again" {
run sudo pmm-admin remove mysql msb_5_6_33
echo "$output"
	[ "$status" -eq 0 ]
	echo "${lines[0]}" | grep "OK, no"
	echo "${lines[1]}" | grep "OK, no"
	echo "${lines[2]}" | grep "OK, no"
}
