#!/bin/bash
# Created by Roel Van de Paar, MariaDB

DIR=${PWD}
rm -Rf 5.5_dbg 5.6_dbg 5.7_dbg 8.0_dbg
cd ${DIR}/5.5 && ~/mariadb-qa/build_mdpsms_dbg.sh &
cd ${DIR}/5.6 && ~/mariadb-qa/build_mdpsms_dbg.sh &
cd ${DIR}/5.7 && ~/mariadb-qa/build_mdpsms_dbg.sh &
cd ${DIR}/8.0 && ~/mariadb-qa/build_mdpsms_dbg.sh &
