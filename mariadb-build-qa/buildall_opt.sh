#!/bin/bash
# Created by Roel Van de Paar, MariaDB

DIR=${PWD}
rm -Rf 10.1_opt 10.2_opt 10.3_opt 10.4_opt 10.5_opt 10.6_opt
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/10.6 && ~/mariadb-qa/build_mdpsms_opt.sh &
