#!/usr/bin/env bats
PMM=$(sudo pmm-admin info| grep 'PMM Server'|awk '{print $4}')
USER=$(sudo pmm-admin show-passwords| grep 'User'|awk '{print $3}')
PASSWORD=$(sudo pmm-admin show-passwords| grep 'Password'|awk '{print $3}')
SSL=$(sudo pmm-admin info |grep 'SSL')
HTTP='http'
if [ -n "$SSL" ] ;  then
    HTTP='https'
  fi
if [ -n "$USER" ] ; then
  AUTH="-u '$USER:$PASSWORD'"
else
  AUTH=""
fi
readarray -t dashboards < $PWD'/dashboards'
@test "check all grafana dasboards exist" {
  for dash in "${dashboards[@]}" ; do
    echo "curl --insecure -s --head $AUTH  $HTTP://${PMM}/graph/api/dashboards/db/$dash| head -n 1"
    run bash -c "curl --insecure -s --head $AUTH  $HTTP://${PMM}/graph/api/dashboards/db/$dash| head -n 1"
    echo $dash;
    echo $output
    [ "$status" -eq 0 ]
    echo "${lines[0]}" | grep "200 OK"
done
}

@test "check specified dashboard is not exist" {
  run bash -c "curl --insecure -s --head $AUTH  $HTTP://${PMM}/graph/api/dashboards/db/non-exist-dashboard| head -n 1"
  [ "$status" -eq 0 ]
  echo $output
  echo "${lines[0]}" | grep "404 Not Found"
}
