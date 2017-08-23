#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

echo 'QA PMM Info Script v0.09'
echo '==================== uname -a'
uname -a 2>&1 | sed 's|^|  |'
echo '==================== /proc/version'
cat /proc/version 2>&1 | sed 's|^|  |'
echo '==================== OS Release (filtered cat /etc/*-release):'  # With thanks, http://www.cyberciti.biz/faq/find-linux-distribution-name-version-number/
cat /etc/*-release 2>&1 | grep -Ev '^$|^CENTOS_|^REDHAT_|^CPE_|^BUG_|^ANSI_' | sort -u | sed 's|^|  |'
echo '==================== Docker release (docker --version):'
docker --version 2>&1 | sed 's|^|  |'
echo '==================== SELinux status if present (sestatus):'
sestatus 2>&1 | sed 's|^|  |'
echo '==================== PMM server images (sudo docker images | grep pmm):'
sudo docker images 2>&1 | grep pmm | sed 's|^|  |'
echo '==================== PMM server state (sudo docker ps -a | grep pmm):'
sudo docker ps -a 2>&1 | grep pmm | sed 's|^|  |'
echo '==================== Exporter status (ps -ef | grep exporter):'
ps -ef | grep -v grep | grep exporter | sed 's|^|  |'
echo '==================== PMM info (sudo pmm-admin info):'
sudo pmm-admin info 2>&1 | grep -v '^$' | sed 's|^|  |'
echo '==================== PMM network check (sudo pmm-admin check-network):'
function version { echo "$@" | gawk -F. '{ printf("%03d%03d%03d\n", $1,$2,$3); }'; }
my_version=$(sudo pmm-admin --version)
emoji_version=1.0.6
if [ "$(version "$my_version")" -gt "$(version "$emoji_version")" ]; then
        sudo pmm-admin check-network 2>&1 | grep -v '^$' | sed 's|^|  |'
else
        sudo pmm-admin check-network --no-emoji 2>&1 | grep -v '^$' | sed 's|^|  |'
fi
echo '==================== PMM list (sudo pmm-admin list):'
sudo pmm-admin list 2>&1 | grep -v '^$' | sed 's|^|  |'

if [ "$1" != "" ]; then
  echo '==================== Extended info: cat /*/*VERSION inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') find / -name \*VERSION -exec echo {} \; -exec cat {} \; 2>&1 | grep -v '^$' | sed 's|^|  |'
  echo '==================== Extended info: cat /var/log/nginx/error.log inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') cat /var/log/nginx/error.log 2>&1 | grep -v '^$' | sed 's|^|  |'
  echo '==================== Extended info: cat /var/log/consul.log inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') cat /var/log/consul.log 2>&1 | grep -v '^$' | sed 's|^|  |'
  echo '==================== Extended info: cat /var/log/grafana.log inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') cat /var/log/grafana.log 2>&1 | grep -v '^$' | sed 's|^|  |'
  echo '==================== Extended info: cat /var/log/prometheus.log inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') cat /var/log/prometheus.log 2>&1 | grep -v '^$' | sed 's|^|  |'
  echo '==================== Extended info: cat /var/log/qan-api.log inside docker container:'
  sudo docker exec -it $(sudo docker ps -a | grep pmm | grep 'Up.*pmm-server' | sed 's|[ \t].*||') cat /var/log/qan-api.log 2>&1 | grep -v '^$' | sed 's|^|  |'
fi
