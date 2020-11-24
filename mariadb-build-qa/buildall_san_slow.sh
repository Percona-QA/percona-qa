#!/bin/bash
# Created by Roel Van de Paar, MariaDB

./terminate_ds_memory.sh  # Terminate ~/ds and ~/memory if running (with 3 sec delay)

DIR=${PWD}
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_opt_asan.sh
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_opt_asan.sh
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR}
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_opt_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_opt_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_opt_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_asan 10.2_opt_asan 10.3_opt_asan 10.4_opt_asan 10.5_opt_asan 10.6_opt_asan
cd ${DIR}/10.6 && ~/mariadb-qa/build_mdpsms_opt_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
cd ${DIR}/10.6 && ~/mariadb-qa/build_mdpsms_dbg_asan.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_asan 10.2_dbg_asan 10.3_dbg_asan 10.4_dbg_asan 10.5_dbg_asan 10.6_dbg_asan
