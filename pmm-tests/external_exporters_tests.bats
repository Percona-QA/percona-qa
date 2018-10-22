#!/usr/bin/env bats

@test "Checking consul_exporter is started" {
  IP_ADDRESS=$(hostname -I | head -n1 |cut -d' ' -f1)
  run bash -c "curl -s "http://${IP_ADDRESS}:9107/metrics" | grep '^consul_'"
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "consul_up"
}

@test "Checking external_service wrong Interval Error Message" {
  run sudo pmm-admin add external:service consul_exporter --service-port=9107 --interval 10 
  echo "$output"
  [ "$status" -eq 1 ]
  echo  ${output} | grep "Invalid duration scrape interval, missing unit in duration, for example 10s"
}

@test "Checking external_service Usage Instructions for Interval Duration" {
  run sudo pmm-admin add external:service --help
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep 'interval duration' | grep "A positive number with the unit symbol - 's', 'm', 'h'"
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

@test "Verifying external exporters info not exist on pmm-admin list" {
  run sudo pmm-admin list
  echo "$output"
  [ "$status" -eq 0 ]
  echo  ${output} | grep  "Job name  Scrape interval  Scrape timeout  Metrics path  Scheme  Target  Labels  Health"
}