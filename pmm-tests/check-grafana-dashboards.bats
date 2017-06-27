#!/usr/bin/env bats
PMM=$(sudo pmm-admin info| grep 'PMM Server'|awk '{print $4}')

readarray -t dashboards < './dashboards'
@test "check all grafana dasboards exist" {
  for dash in "${dashboards[@]}" ; do
    run bash -c "curl --insecure -s --head ${PMM}/graph/api/dashboards/db/$dash| head -n 1"
    echo $dash;
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "HTTP/1.1 200 OK"
    done
}

@test "check specified dashboard is not exist" {
    run bash -c "curl --insecure -s --head ${PMM}/graph/api/dashboards/db/non-exist-dashboard| head -n 1"
    echo $dash;
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "HTTP/1.1 404 Not Found"
}
