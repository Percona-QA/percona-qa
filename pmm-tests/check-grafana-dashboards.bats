#!/usr/bin/env bats
PMM='http://10.10.11.50:8888/graph/api/dashboards/db/'
readarray -t dashboards < './dashboards'
@test "check all grafana dasboards exist" {
  for dash in "${dashboards[@]}" ; do
    run bash -c "curl --insecure -s --head ${PMM}$dash| head -n 1"
    echo $dash;
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "HTTP/1.1 200 OK"
    done
}

@test "check specified dashboard is not exist" {
    run bash -c "curl --insecure -s --head ${PMM}non-exists-dashboard| head -n 1"
    echo $dash;
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "HTTP/1.1 404 Not Found"
}
