#!/bin/bash
# Created by Roel Van de Paar, MariaDB

./terminate_ds_memory.sh  # Terminate ~/ds and ~/memory if running (with 3 sec delay)

DIR=${PWD}
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_opt_san.sh
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_opt_san.sh
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR}
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_opt_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_opt_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_opt_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_opt_san 10.2_opt_san 10.3_opt_san 10.4_opt_san 10.5_opt_san 10.6_opt_san
cd ${DIR}/10.6 && ~/mariadb-qa/build_mdpsms_opt_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.1 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.2 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.3 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.4 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.5 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
cd ${DIR}/10.6 && ~/mariadb-qa/build_mdpsms_dbg_san.sh 
if [ -d /data/TARS ]; then mv ${DIR}/*.tar.gz /data/TARS; sync; fi
cd ${DIR} && rm -Rf 10.1_dbg_san 10.2_dbg_san 10.3_dbg_san 10.4_dbg_san 10.5_dbg_san 10.6_dbg_san
