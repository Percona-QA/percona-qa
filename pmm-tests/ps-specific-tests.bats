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


@test "run pmm-admin add mysql:metrics based on running intsances" {
	  COUNTER=0
		for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
      let COUNTER=COUNTER+1
			MYSQL_SOCK=${i}
			run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_metrics_$COUNTER
			echo "$output"
	    	[ "$status" -eq 0 ]
	    	echo "${lines[0]}" | grep "OK, now monitoring"
		done
}


@test "run pmm-admin add mysql:metrics again based on running instances" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql_metrics_" | grep -Eo '\/.*\)' | sed 's/)$//') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin add mysql:metrics --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 1 ]
			[ "${lines[0]}" = "Error adding MySQL metrics: there is already one instance with this name under monitoring." ]
	done
}


@test "run pmm-admin remove mysql:metrics" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql_metrics_" | grep -Eo '\/.*\)' | sed 's/)$//') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin remove mysql:metrics mysql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "OK, removed MySQL metrics"
	done
}


@test "run pmm-admin remove mysql:metrics again" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql_metrics_" | grep -Eo '\/.*\)' | sed 's/)$//') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin remove mysql:metrics mysql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "no service found"
	done
}

@test "run pmm-admin purge mysql:metrics" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql_metrics_" | grep -Eo '\/.*\)' | sed 's/)$//') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin purge mysql:metrics mysql_metrics_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "OK, data purged"
	done
}

## mysql:queries

@test "run pmm-admin add mysql:queries based on running instances" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_queries_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, now monitoring"
	done
}


@test "run pmm-admin add mysql:queries again based on running instances" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_queries_" |sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin add mysql:queries --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_queries_$COUNTER
		echo "$output"
			[ "$status" -eq 1 ]
			[ "${lines[0]}" = "Error adding MySQL queries: there is already one instance with this name under monitoring." ]
	done
}


@test "run pmm-admin remove mysql:queries" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_queries_" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin remove mysql:queries  mysql_queries_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "OK, removed MySQL queries"
	done
}


@test "run pmm-admin remove mysql:queries again" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_queries_" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin remove mysql:queries mysql_queries_$COUNTER
		echo "$output"
			[ "$status" -eq 1 ]
			echo "${output}" | grep "no service found"
	done
}


## add mysql
@test "run pmm-admin add mysql" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, already"
			echo "${lines[1]}" | grep "OK, now"
			echo "${lines[2]}" | grep "OK, now"
	done
}

@test "run pmm-admin add mysql again" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin add mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} mysql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, already"
			echo "${lines[1]}" | grep "OK, already"
			echo "${lines[2]}" | grep "OK, already"
	done
}

@test "run pmm-admin remove mysql" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin remove mysql mysql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${lines[0]}" | grep "OK, no system"
			echo "${lines[1]}" | grep "OK, removed"
			echo "${lines[2]}" | grep "OK, removed"
	done

}

@test "run pmm-admin purge mysql:metrics" {
	COUNTER=0
	for i in $(sudo pmm-admin list | grep "mysql:queries" | grep "mysql_" | sed 's|.*(||;s|).*||') ; do
		let COUNTER=COUNTER+1
		MYSQL_SOCK=${i}
		run sudo pmm-admin purge mysql mysql_$COUNTER
		echo "$output"
			[ "$status" -eq 0 ]
			echo "${output}" | grep "OK, data purged"
	done

}
