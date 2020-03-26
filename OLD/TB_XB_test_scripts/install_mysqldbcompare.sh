#!/usr/bin/bash

wget https://dev.mysql.com/get/mysql57-community-release-el7-7.noarch.rpm
yum localinstall mysql57-community-release-el7-7.noarch.rpm
yum install mysql-utilities