#Checking MySQL Slow log rotation functionality

@test "check that help has slow-log-rotation option" {
  run sudo pmm-admin add mysql --help
  echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "slow-log-rotation"
}

@test "check that help has retain-slow-logs  option" {
  run sudo pmm-admin add mysql --help
  echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "retain-slow-logs"
}

@test "run pmm-admin add mysql with default values" {
  MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||') 
  run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK}  mysql_default
  echo "$output"
  [ "$status" -eq 0 ]
  echo "${lines[2]}" | grep "OK, now monitoring"
}

@test "check pmm-admin list has instance enabled slow log rotation" {
  run sudo pmm-admin list
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" |grep mysql_default |grep "slow_log_rotation=true"
  echo "$output" |grep mysql_default |grep "retain_slow_logs=1"
  run sudo pmm-admin rm mysql mysql_default
}

@test "run pmm-admin add mysql with disabled slow log rotation option" {
  MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||')
    run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --slow-log-rotation=false mysql_disabled_slow_log
    echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[2]}" | grep "OK, now monitoring"
}

@test "check pmm-admin list has instance with disabled slow log rotation" {
  run sudo pmm-admin list
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" |grep "slow_log_rotation=false"
  run sudo pmm-admin rm mysql mysql_disabled_slow_log
}

@test "run pmm-admin add mysql with retain-slow-logs option" {
  MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||')
  run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --retain-slow-logs=5 mysql_slow_log_5
  echo "$output"
  [ "$status" -eq 0 ]
  echo "${lines[2]}" | grep "OK, now monitoring"
}

@test "check added instance has slow_log_rotation=true and retain_slow_logs flags" {
  run sudo pmm-admin list 
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" |grep mysql_slow_log_5| grep "slow_log_rotation=true"
  echo "$output" |grep mysql_slow_log_5| grep "retain_slow_logs=5"
}
