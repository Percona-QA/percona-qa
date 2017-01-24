#!/usr/bin/env bats

#remove_all_monitoring() {
#    run sudo pmm-admin list
#    echo "echo"
#}

@test "run pmm-admin without root privileges" {
run pmm-admin
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "pmm-admin requires superuser privileges to manage system services." ]
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
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Usage:" ]
}

@test "run pmm-admin -h" {
run sudo pmm-admin -h
echo "$output"
    [ "$status" -eq 1 ]
    echo "${output}" | grep "Usage:"
}

@test "run pmm-admin with wrong option" {
run sudo pmm-admin install
echo "$output"
    [ "$status" -eq 1 ]
}

@test "run pmm-admin help" {
run sudo pmm-admin install
echo "$output"
    [ "$status" -eq 1 ]
}

@test "run pmm-admin ping" {
run sudo pmm-admin ping
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK" ]
}

@test "run pmm-admin check-network" {
run sudo pmm-admin check-network --no-emoji
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "PMM Network Status" ]
    [ "${lines[7]}" = "Consul API      OK           " ]
    [ "${lines[8]}" = "QAN API         OK           " ]
    [ "${lines[9]}" = "Prometheus API  OK           " ]
}

@test "run pmm-admin list" {
run sudo pmm-admin list
echo "$output"
    [ "$status" -eq 0 ]
    echo "${output}" | grep "No monitoring registered"
}

@test "run pmm-admin add os" {
run sudo pmm-admin add os
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, now monitoring this OS." ]
}

@test "run pmm-admin remove os" {
run sudo pmm-admin remove os bm-dell02-qanqa01
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, removed this OS from monitoring." ]
}

@test "run pmm-admin remove os again" {
run sudo pmm-admin remove os test
echo "$output"
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = "Error removing OS: no service found." ]
}

@test "run pmm-admin add os with name" {
run sudo pmm-admin add os mytest1.os1
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OK, now monitoring this OS." ]
}

@test "run pmm-admin list to check os monitoring" {
run sudo pmm-admin list
echo "$output"
    [ "$status" -eq 0 ]
}
