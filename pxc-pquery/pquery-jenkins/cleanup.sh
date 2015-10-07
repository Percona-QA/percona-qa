#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Kill and delete/remove all new_pxc<nr> containers
sudo docker kill $(docker ps -a | grep "pqueryjenkins_pxc" | awk '{print $1}' | tr '\n' ' ') 2>/dev/null
sleep 1
sync
sudo docker rm $(docker ps -a | grep "pqueryjenkins_pxc" | awk '{print $1}' | tr '\n' ' ') 2>/dev/null
sync

echo "Done!"
