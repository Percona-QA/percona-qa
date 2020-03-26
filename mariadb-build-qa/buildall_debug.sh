DIR=${PWD}
rm -Rf 10.1_dbg 10.2_dbg 10.3_dbg 10.4_dbg 10.5_dbg
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_debug.sh &
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_debug.sh &
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_debug.sh &
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_debug.sh &
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_debug.sh &

