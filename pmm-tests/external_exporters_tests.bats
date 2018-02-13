#!/usr/bin/env bats

@test "Checking consul_exporter" {
  IP_ADDRESS=$(ip route get 1 | awk '{print $NF;exit}')
  run "curl -s http://${IP_ADDRESS}/metrics | grep '^consul_'"
  [ "$status" -eq 0 ]
  echo $output
  echo ${IP_ADDRESS}
  echo  "${lines[1]}" | grep  "consul_up"
}
