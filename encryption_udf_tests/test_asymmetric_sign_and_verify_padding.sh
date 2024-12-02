#!/bin/bash

################################################################################
# Created by Mohit Joshi, Percona LLC                                          #
# Creation Date: 02-Dec-2024                                                   #
#                                                                              #
# PS-7044 - Provide Enterprise Encryption UDFs for OpenSSL                     #
# PS-8389 - Align PS Encryption UDFs functionality with new features from      # 
#           MySQL 8.0.30 Enterprise Encryption Component                       #
# PS-9137 - Parity with Oracle Enterprise Encryption                           #
#                                                                              #
################################################################################
set -e

build_dir=$HOME/mysql-8.0/bld_debug/install
socket=/tmp/mysql_22000.sock

# Validate the MySQL socket
if [ ! -S $socket ]; then
    echo "Socket file $socket not found. Is MySQL running?" >&2
    exit 1
fi

padding_schemes=("OFF" "ON")
for padding_scheme in "${padding_schemes[@]}"
do
    echo "#######################################################################"
    echo "# Testing with encryption_udf.legacy_padding_scheme=$padding_scheme   #"
    echo "#######################################################################"
    $build_dir/bin/mysql -uroot -S$socket -e"SET GLOBAL encryption_udf.legacy_padding_scheme=$padding_scheme;"

    algo=('RSA' 'DSA')
    key_len=('1042' '2048' '4096')
    str_len=(10 50 100 200 300 500 1000 2000 2048 4096)
    dig_type=('SHA224'  'SHA256'  'SHA384'  'SHA512')
    for j in $(seq 0 $((${#algo[@]} - 1)))
    do
        for i in $(seq 0 $((${#dig_type[@]} - 1)))
        do
            for k in $(seq 0 $((${#str_len[@]} - 1)))
            do
                # Generate a string of specified length
                str=$(printf "%${str_len[k]}s" | tr ' ' 'a')
                dig=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT HEX(create_digest('${dig_type[i]}', '$str'));" )

                # Generate RSA private key
                priv=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT create_asymmetric_priv_key('${algo[j]}', $key_len);" )

                # Generate RSA public key
                pub=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT create_asymmetric_pub_key('${algo[j]}', '$priv');" )

                # Generate signature for digest 
                sign=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT HEX(asymmetric_sign('${algo[j]}', UNHEX('$dig'), '$priv', '${dig_type[i]}'));" )

                # Verify signature against digest
                verify=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT asymmetric_verify('${algo[j]}', UNHEX('$dig'), UNHEX('$sign'), '$pub', '${dig_type[i]}');")
                if [ $verify -eq 1 ]; then
                    echo "Verification against digest_type ${dig_type[i]} and algo ${algo[j]} for string length ${str_len[k]} is successful"
                else
                    echo "Verification against digest_type ${dig_type[i]} and algo ${algo[j]} for string length ${str_len[k]} is un-successful"
                    exit 1
                fi
            done
        done
    done
done

