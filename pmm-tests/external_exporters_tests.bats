#!/usr/bin/env bats

@test "Checking consul_exporter is started" {
  IP_ADDRESS=$(ip route get 1 | awk '{print $NF;exit}')
  IP_ADDRESS=$(hostname -I | cut -d' ' -f1)
  run bash -c "curl -s "http://${IP_ADDRESS}:9107/metrics" | grep '^consul_'"
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "consul_up"
}

@test "Adding consul_exporter to monitoring" {
  run sudo pmm-admin add external:service consul-exporter --service-port=9107
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "External service added"
}

@test "Removing consul_exporter from monitoring" {
  run sudo pmm-admin rm external:service consul-exporter --service-port=9107
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "External service removed"
}

@test "Adding consul_exporter to monitoring with specified path and interval" {
  run sudo pmm-admin add external:service consul-exporter --service-port=9107 --path=blabla --interval=12s --force
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "External service added"
  run sudo pmm-admin list
  echo  ${output} | grep "blabla"
}



@test "Removing consul_exporter from monitoring" {
  run sudo pmm-admin rm external:service consul-exporter --service-port=9107
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "External service removed"
}

