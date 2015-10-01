LIB_PATH=/sda/Percona-Server-5.6.21-rel69.0-670.Linux.x86_64-debug-valgrind/lib
#/bzr/Percona-Server-5.6.20-rel68.0-654-debug-valgrind.Linux.x86_64/lib/
LIB_NAME=perconaserverclient_r
INC_PATH=/sda/Percona-Server-5.6.21-rel69.0-670.Linux.x86_64-debug-valgrind/include
#/bzr/Percona-Server-5.6.20-rel68.0-654-debug-valgrind.Linux.x86_64/include

# non-static
g++ -L${LIB_PATH} -l${LIB_NAME} -I${INC_PATH} -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb pquery.cpp -o pquery

# static, only as an example atm
g++ -std=gnu++11 pquery.cpp ../../percona-server/libmysql/libperconaserverclient.a -o pquery -I../../percona-server/include -lpthread -ldl
