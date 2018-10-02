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

@test "run pmm-admin add proxysql:metrics" {
  run sudo pmm-admin add proxysql:metrics
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, now monitoring"
}

@test "run pmm-admin add proxysql:metrics again" {
  run sudo pmm-admin add proxysql:metrics
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Error adding proxysql metrics: there is already one instance with this name under monitoring." ]
}


@test "run pmm-admin add proxysql:metrics named" {
  run sudo pmm-admin add proxysql:metrics 0x0
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, now monitoring"
}

@test "run pmm-admin add proxysql:metrics named again" {
  run sudo pmm-admin add proxysql:metrics 0x0
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "Error adding proxysql metrics: there is already one instance with this name under monitoring." ]
}

@test "run pmm-admin rm proxysql:metrics" {
  run sudo pmm-admin rm proxysql:metrics
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, removed"
}

@test "run pmm-admin purge proxysql:metrics" {
  run sudo pmm-admin purge proxysql:metrics
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, data purged"
}

@test "run pmm-admin purge proxysql:queries" {
  run sudo pmm-admin purge proxysql:queries
  [ "$status" -eq 1 ]
  echo "${lines[0]}" | grep "Error purging"
}

@test "run pmm-admin rm proxysql:metrics 0x0" {
  run sudo pmm-admin rm proxysql:metrics 0x0
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, removed"
}
