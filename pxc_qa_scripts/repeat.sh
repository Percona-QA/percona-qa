#!/bin/bash

for X in $(seq 1 5); do
rm -rf $HOME/nbo/756282/1/node1 
rm -rf $HOME/nbo/756282/1/node2
rm -rf $HOME/nbo/756282/1/node3

cp -r $HOME/nbo/756282/1/node1_bk $HOME/nbo/756282/1/node1 
cp -r $HOME/nbo/756282/1/node2_bk $HOME/nbo/756282/1/node2
cp -r $HOME/nbo/756282/1/node3_bk $HOME/nbo/756282/1/node3 

./start_3node_pxc80.sh ~/pxc_8.0/bld_8.0/install
sudo pkill -9 mysqld
sleep 5
done
