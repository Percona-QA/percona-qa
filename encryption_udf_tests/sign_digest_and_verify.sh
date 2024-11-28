#!/bin/bash

MYSQL_BIN=$HOME/PS-7044/bld_01apr_2022/install/bin

algo=('RSA' 'DSA')
dig_type=('MD5' 'SHA1' 'SHA224' 'SHA256' 'SHA384' 'SHA512' 'MD4' 'RIPEMD160' 'BLAKE2B512' 'BLAKE2S256' 'RIPEMD' 'RMD160' 'SHAKE128' 'SHAKE256' 'SM3' 'WHIRLPOOL' )

key_len=1024;

echo "====================================================================="
echo "Test UDFs with different combination of algorithm and digest types..."
echo "====================================================================="

for i in $(seq 0 $((${#algo[@]} - 1)))
do
  for j in $(seq 0 $((${#dig_type[@]} - 1)))
  do
    echo "Create private key using ${algo[i]}"
    priv=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT create_asymmetric_priv_key('${algo[i]}', $key_len)"`;

    echo "Creating public key using ${algo[i]}"
    pub=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT create_asymmetric_pub_key('${algo[i]}', '$priv')"`;

    echo "Generate digest string using ${dig_type[j]}"
    dig=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT HEX(create_digest('${dig_type[j]}', 'My text to digest'))"`;

    echo "Generate signature for digest using ${algo[i]} with ${dig_type[j]}"
    sig=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT HEX(asymmetric_sign('${algo[i]}', UNHEX('$dig'), '$priv', '${dig_type[j]}'))"`;

    echo "Verify signature against digest"
    verify=`$MYSQL_BIN/mysql --no-defaults -uroot -S/tmp/mysql_22000.sock -s -e "SELECT asymmetric_verify('${algo[i]}', UNHEX('$dig'), UNHEX('$sig'), '$pub', '${dig_type[j]}')"`;

    if [ "$verify" != "1" ]; then
      echo "You have found a bug. Please investigate, exiting...";
      echo $verify
      exit 1;
    else
      echo "Verification successful. Verify=$verify"
    fi
  done
done

echo "======================================="
echo "Test UDFs with external OpenSSL keys..."
echo "======================================="
$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "DROP DATABASE IF EXISTS udf_test; CREATE DATABASE udf_test";
$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "CREATE TABLE udf_test.rsa_key_holder (priv varchar(2000), pub varchar(2000))";
$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "CREATE TABLE udf_test.dsa_key_holder (priv varchar(2000), pub varchar(2000))";

for i in $(seq 0 $((${#algo[@]} - 1)))
do
  for j in $(seq 0 $((${#dig_type[@]} - 1)))
  do
    if [ "${algo[i]}" == "RSA" ]; then
      $MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "INSERT INTO udf_test.rsa_key_holder VALUES (LOAD_FILE('/home/mohit.joshi/PS-7044/bld_01apr_2022/install/rsa.private'), LOAD_FILE('/home/mohit.joshi/PS-7044/bld_01apr_2022/install/rsa.public'))";
      external_priv=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT priv FROM udf_test.rsa_key_holder"`
      external_pub=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT pub FROM udf_test.rsa_key_holder"`
    elif [ "${algo[i]}" == "DSA" ]; then
      $MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "INSERT INTO udf_test.dsa_key_holder VALUES (LOAD_FILE('/home/mohit.joshi/PS-7044/bld_01apr_2022/install/dsaprivkey.pem'), LOAD_FILE('/home/mohit.joshi/PS-7044/bld_01apr_2022/install/dsapubkey.pem'))";
      external_priv=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT priv FROM udf_test.dsa_key_holder"`
      external_pub=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT pub FROM udf_test.dsa_key_holder"`
    fi

    echo "Generate digest string using ${dig_type[j]}"
    dig=`$MYSQL_BIN/mysql -uroot -S/tmp/mysql_22000.sock -s -e "SELECT HEX(create_digest('${dig_type[j]}', 'My text to digest'))"`

    echo "Generate signature for digest using ${algo[i]} with ${dig_type[j]}"
    sig=`$MYSQL_BIN/mysql --no-defaults -uroot -S/tmp/mysql_22000.sock -s -e "SELECT HEX(asymmetric_sign('${algo[i]}','$dig','$external_priv','${dig_type[j]}'))"`

    echo "Verify signature against digest"
    verify=`$MYSQL_BIN/mysql --no-defaults -uroot -S/tmp/mysql_22000.sock -s -e "SELECT asymmetric_verify('${algo[i]}', UNHEX('$dig'), UNHEX('$sig'), '$external_pub', '${dig_type[j]}')"`;

    if [ "$verify" != "1" ]; then
      echo "You have found a bug. Please investigate, exiting...";
      echo $verify
      exit 1;
    else
      echo "Verification successful. Verify=$verify"
    fi
  done
done
