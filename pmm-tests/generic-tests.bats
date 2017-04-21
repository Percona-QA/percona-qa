## Generic bats tests

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
    [ "${lines[14]}" = "Consul API           OK           " ]
    [ "${lines[15]}" = "Prometheus API       OK           " ]
    [ "${lines[16]}" = "Query Analytics API  OK           "  ]
}

@test "run pmm-admin check-network datetime" {
run sudo pmm-admin check-network
echo "$output"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "PMM Network Status" ]
		NTP_SERVER=$(echo ${lines[7]} | awk -F '[|"+"]' '{print $2}')
		PMM_SERVER=$(echo ${lines[8]} | awk -F '[|"+"]' '{print $2}')
		PMM_CLIENT=$(echo ${lines[9]} | awk -F '[|"+"]' '{print $2}')
    echo ${NTP_SERVER}
		echo ${PMM_SERVER}
		echo ${PMM_CLIENT}
}


@test "run pmm-admin list to check for available services" {
run sudo pmm-admin list
echo "$output"
    [ "$status" -eq 0 ]
		#echo "$output"
    #echo "${output}" | grep "No services under monitoring."
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
	echo "$output" | grep "1.1"
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
