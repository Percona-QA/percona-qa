#!/usr/bin/env bats

@test "Checking consul_exporter" {
  IP_ADDRESS=$(ip route get 1 | awk '{print $NF;exit}')
  run curl -s "http://${IP_ADDRESS}:9107/metrics" | grep '^consul_'
  echo ${output}
  echo  "${lines[1]}" | grep  "consul_up"
}
