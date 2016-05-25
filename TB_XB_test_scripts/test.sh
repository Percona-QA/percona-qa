#!/bin/bash

echo "drop table if exists db1.sb1" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
echo "create table db1.sb1 as select id,c from db1.sbtest1 where id < 150000;"| mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
echo "alter table db1.sb1 encryption='Y'" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
#echo "create unique index ix on db1.sb1 (id)" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
sleep 1
echo "drop table if exists db2.sb1" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
echo "create table db2.sb1 as select id,c from db2.sbtest1 where id < 150000;" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
echo "alter table db2.sb1 encryption='Y'" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
#echo "create unique index ix on db2.sb1 (id)" | mysql -u root -pBaku12345# --socket=/var/lib/mysql/mysql.sock
