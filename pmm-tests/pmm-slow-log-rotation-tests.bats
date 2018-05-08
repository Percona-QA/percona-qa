#Checking MySQL Slow log rotation functionality

@test "run pmm-admin add mysql --help" {
run sudo pmm-admin add mysql --help
echo "$output"
    [ "$status" -eq 0 ]
     echo "${output}" | grep "disable-slow-logs-rotation"
     echo "${output}" | grep "retain-slow-logs"
      
}

