LIB_PATH=/sda/mysql-5.6.20-linux-glibc2.5-x86_64/lib
LIB_NAME=mysqlclient_r
INC_PATH=/sda/mysql-5.6.20-linux-glibc2.5-x86_64/include

g++ -L${LIB_PATH} -l${LIB_NAME} -I${INC_PATH} -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb pquery.cpp -o pquery-ms
