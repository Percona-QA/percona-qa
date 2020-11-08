#!/bin/bash
# Created by Roel Van de Paar, MariaDB

./terminate_ds_memory.sh  # Terminate ~/ds and ~/memory if running (with 3 sec delay)

DIR=${PWD}
rm -Rf 5.5_opt 5.6_opt 5.7_opt 8.0_opt
cd ${DIR}/5.5 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/5.6 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/5.7 && ~/mariadb-qa/build_mdpsms_opt.sh &
cd ${DIR}/8.0 && ~/mariadb-qa/build_mdpsms_opt.sh &
