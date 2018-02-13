#!/usr/bin/env bats

@test "Checking consul_exporter" {
  ip_addr=$(ip route get 1 | awk '{print $NF;exit}')
  run "curl -s http://${ip_addr}/metrics | grep '^consul_'"
  [ "$status" -eq 0 ]
  echo $output
  echo  "${lines[1]}" |grep  "consul_up"
}
