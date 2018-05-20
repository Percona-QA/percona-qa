#Checking MySQL Slow log rotation functionality
setup() {

  SLOW_LOG=$(sudo pmm-admin list| grep -m1 "slowlog")
}

@test "check that help has slow-log-rotation option [PMM-2432]" {
  run sudo pmm-admin add mysql --help
  echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "slow-log-rotation"
}

@test "check that help has retain-slow-logs option [PMM-2432]" {
  run sudo pmm-admin add mysql --help
  echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "retain-slow-logs"
}

@test "run pmm-admin add mysql with default values [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||') 
    run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK}  mysql_default
    echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[2]}" | grep "OK, now monitoring"
  fi
}

@test "check pmm-admin list has instance enabled slow log rotation [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    run sudo pmm-admin list
    echo "$output"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/mysql_default.*slow_log_rotation=true.*retain_slow_logs=1/'
    run sudo pmm-admin rm mysql mysql_default
  fi
}

@test "run pmm-admin add mysql with disabled slow log rotation option [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||')
    run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --slow-log-rotation=false mysql_disabled_slow_log
    echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[2]}" | grep "OK, now monitoring"
  fi
}

@test "check pmm-admin list has instance with disabled slow log rotation [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    run sudo pmm-admin list
    echo "$output"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/mysql_disabled_slow_log.*slow_log_rotation=false/'
    run sudo pmm-admin rm mysql mysql_disabled_slow_log
  fi
}

@test "run pmm-admin add mysql with retain-slow-logs option [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||')
    run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --retain-slow-logs=5 mysql_slow_log_5
    echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[2]}" | grep "OK, now monitoring"
  fi
}

@test "check added instance has slow_log_rotation=true and retain_slow_logs flags [PMM-2432]" {
  if [[ -z $SLOW_LOG ]]
  then
    skip "Instance should be added with slowlog query source"
  else
    run sudo pmm-admin list 
    echo "$output"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/mysql_slow_log_5.*slow_log_rotation=true.*retain_slow_logs=5/'
    run sudo pmm-admin rm mysql mysq_slow_log_5
  fi
}
