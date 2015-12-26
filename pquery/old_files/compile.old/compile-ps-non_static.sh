LIB_PATH=/sda/Percona-Server-5.6.21-rel70.0-693.Linux.x86_64/lib
LIB_NAME=perconaserverclient_r
INC_PATH=/sda/Percona-Server-5.6.21-rel70.0-693.Linux.x86_64/include

g++ -L${LIB_PATH} -l${LIB_NAME} -I${INC_PATH} -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb pquery.cpp -o pquery
