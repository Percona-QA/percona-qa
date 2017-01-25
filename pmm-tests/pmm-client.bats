#!/usr/bin/env bats

#remove_all_monitoring() {
#    run sudo pmm-admin list
#    echo "echo"
#}


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

@test "run pmm-admin remove linux:metrics with given name" {
run sudo pmm-admin remove linux:metrics mytest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, removed system mytest1.os1 from monitoring." ]
}

@test "run pmm-admin list to check os monitoring" {
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
