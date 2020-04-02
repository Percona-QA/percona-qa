#!/bin/bash
# Created by Roel Van de Paar, MariaDB

rm -Rf 10.1
rm -Rf 10.2
rm -Rf 10.3
rm -Rf 10.4
rm -Rf 10.5
./clone.sh 10.1
./clone.sh 10.2
./clone.sh 10.3
./clone.sh 10.4
./clone.sh 10.5

