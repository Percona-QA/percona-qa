#!/bin/bash
set -e

build_dir=$HOME/mysql-8.0/bld_debug/install
socket=/tmp/mysql_22000.sock

# Validate the MySQL socket
if [ ! -S $socket ]; then
    echo "Socket file $socket not found. Is MySQL running?" >&2
    exit 1
fi

# Test with OAEP padding introduced from PS-8.0.39
$build_dir/bin/mysql -uroot -S$socket -e"SET GLOBAL encryption_udf.legacy_padding_scheme=OFF;"

echo "#################################################################################################"
echo "# Test 1: Perform encryption and decryption using asymmetric_encrypt and asymmetric_decrypt     #"
echo "#################################################################################################"

key_len=2048
length=10

# Generate a string of specified length
str=$(printf "%${length}s" | tr ' ' 'a')

# Generate RSA private key
priv=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT create_asymmetric_priv_key('RSA', $key_len);" )
if [ -z "$priv" ]; then
    echo "Failed to generate RSA private key." >&2
    exit 1
fi

# Generate RSA public key
pub=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT create_asymmetric_pub_key('RSA', '$priv');" )
if [ -z "$pub" ]; then
    echo "Failed to generate RSA public key." >&2
    exit 1
fi

# Encrypt the string. Default padding is OAEP when encryption_udf.legacy_padding_scheme=OFF
cipher_str=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub' ));" )
if [ -z "$cipher_str" ]; then
    echo "Failed to encrypt the string." >&2
    exit 1
fi

# Decrypt the string
decrypted=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT CAST(asymmetric_decrypt('RSA', FROM_BASE64('$cipher_str'), '$priv') AS CHAR);" )
echo "Decrypted string is : $decrypted"
if [ "$decrypted" != "$str" ]; then
    echo "Decryption failed: expected '$str', got '$decrypted'" >&2
    exit 1
fi

echo "Encryption and decryption succeeded."

#  Test Max string length that can be encrypted when RSA key_len=2048 for different padding.
#  For key_len=2048, maximum str length = 214 (when padding=oaep; str_len = key_len/8 - 42 )
#  For key_len=2048, maximum str length = 245 (when padding=pkcs1; str_len = key_len/8 - 11 )
key_len=2048
padding=pkcs1
max_length_pkcs1=$((key_len / 8 - 11))

echo "#################################################################################################"
echo "# Test 2: Test Max string that can be encrypted when RSA key_len=$key_len and padding=$padding"
echo "#################################################################################################"

# Enabling padding=pkcs1 as used in PS before 8.0.39
$build_dir/bin/mysql -uroot -S$socket -e"SET GLOBAL encryption_udf.legacy_padding_scheme=ON;"
str=$(printf "%${max_length_pkcs1}s" | tr ' ' 'a')
# Must be successful
cipher_str=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" )
if [ -z "$cipher_str" ]; then
    echo "Encryption failed for string of length $max_length_pkcs1."
    exit 1
else
    echo "Encryption succeeded for string of length $max_length_pkcs1."
fi

str=$(printf "%$((max_length_pkcs1 + 1))s" | tr ' ' 'a')
# Must fail
result=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" 2>&1 || true )
if [[ "$result" =~ "ERROR" ]]; then
    echo "Encryption correctly failed for string of length $((max_length_pkcs1 + 1)): $result"
else
    echo "Unexpected success for string of length $((max_length_pkcs1 + 1))!"
    exit 1
fi


padding=oaep
max_length_oaep=$((key_len / 8 - 42))

echo "#################################################################################################"
echo "# Test 3: Test Max string that can be encrypted when RSA key_len=$key_len and padding=$padding"
echo "#################################################################################################"
# Enabling padding=oaep as used PS from  8.0.39
$build_dir/bin/mysql -uroot -S$socket -e"SET GLOBAL encryption_udf.legacy_padding_scheme=OFF;"
str=$(printf "%${max_length_oaep}s" | tr ' ' 'a')
# Must be successful
cipher_str=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" )
if [ -z "$cipher_str" ]; then
    echo "Encryption failed for string of length $max_length_oaep."
    exit 1
else
    echo "Encryption succeeded for string of length $max_length_oaep."
fi

str=$(printf "%$((max_length_oaep + 1))s" | tr ' ' 'a')
# Must fail
result=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" 2>&1 || true )
if [[ "$result" =~ "ERROR" ]]; then
    echo "Encryption correctly failed for string of length $((max_length_oaep + 1)): $result"
else
    echo "Unexpected success for string of length $((max_length_oaep + 1))!"
    exit 1
fi

padding=no
key_len=2048
str_length=$((key_len / 8))
str=$(printf "%${str_length}s" | tr ' ' 'a')

echo "#################################################################################################"
echo "# Test 4: String length must be same as key length in bytes when padding=$padding"
echo "#################################################################################################"

cipher_str=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" )
if [ -z "$cipher_str" ]; then
    echo "Encryption failed for string of length $str_length"
    exit 1
else
    echo "Encryption succeeded for string of length $str_length"
fi

# If string length is less than or greater than the size of key in bytes, it must fail
str_length=200
str=$(printf "%${str_length}s" | tr ' ' 'a')
# Must fail
result=$( $build_dir/bin/mysql -uroot -S$socket -Nse"SELECT TO_BASE64(asymmetric_encrypt('RSA', '$str', '$pub', '$padding' ));" 2>&1 || true )
if [[ "$result" =~ "ERROR" ]]; then
    echo "Encryption correctly failed for string of length $str_length: $result"
else
    echo "Unexpected success for string of length $str_length"
    exit 1
fi
