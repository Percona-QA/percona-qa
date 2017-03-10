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

@test "run pmm-admin add mongodb" {
  run sudo pmm-admin add mongodb
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, already"
  echo "${lines[1]}" | grep "OK, now monitoring"
}

@test "run pmm-admin add mongodb again" {
  run sudo pmm-admin add mongodb
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, already"
  echo "${lines[1]}" | grep "OK, already"
}

@test "run pmm-admin add mongodb named" {
  run sudo pmm-admin add mongodb mymongo1
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, already"
  echo "${lines[1]}" | grep "OK, now monitoring"
}

@test "run pmm-admin add mongodb name again" {
  run sudo pmm-admin add mongodb mymongo1
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, already"
  echo "${lines[1]}" | grep "OK, already"
}

@test "run pmm-admin rm mongodb" {
  run sudo pmm-admin rm mongodb
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, no system"
  echo "${lines[1]}" | grep "OK, removed"
}

@test "run pmm-admin rm mongodb named" {
  run sudo pmm-admin rm mongodb mymongo1
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep "OK, no system"
  echo "${lines[1]}" | grep "OK, removed"
}
