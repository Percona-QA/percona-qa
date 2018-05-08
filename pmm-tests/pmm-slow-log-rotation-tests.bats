#Checking MySQL Slow log rotation functionality

@test "run pmm-admin add mysql --help" {
run sudo pmm-admin add mysql --help
echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "disable-slow-logs-rotation"
     echo "${output}" | grep "retain-slow-logs"
}

@test "run pmm-admin add mysql with disabled slow log rotation option" {
    COUNTER=0
    for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
      let COUNTER=COUNTER+1
      MYSQL_SOCK=${i}
      run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --disable-slow-logs-rotation mysql_$COUNTER
      echo "$output"
      [ "$status" -eq 0 ]
      echo "${lines[1]}" | grep "OK, now monitoring"
    done
}

@test "run pmm-admin add mysql with retain-slow-logs option" {
    COUNTER=0
    MYSQL_SOCK=$(sudo pmm-admin list | grep -m1 "mysql:metrics" | sed 's|.*(||;s|)||')
    run sudo pmm-admin add mysql  --socket=${MYSQL_SOCK} --retain-slow-logs=5 mysql_slow_log_5
    echo "$output"
    [ "$status" -eq 0 ]
    echo "${lines[1]}" | grep "OK, now monitoring"
}
