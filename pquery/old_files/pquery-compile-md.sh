# MariaDB client library (make sure that version matches the mariadb-devel and mariadb-libs packages installed through the OS. To get this .a library, use:
# wget https://downloads.mariadb.org/interstitial/mariadb-5.5.42/bintar-linux-x86_64/mariadb-5.5.42-linux-x86_64.tar.gz
CLIENT_A_LIB=/bzr/mariadb-5.5.42-linux-x86_64/lib/libmysqlclient.a

if [ ! -r "${CLIENT_A_LIB}" ]; then
  echo "Assert: MariaDB client library (set to ${CLIENT_A_LIB}) was not found! Terminating."
  exit 1
fi

echo "============ pquery-md (MariaDB client libs) compiler (static client libs) (This script veried to work on Centos 7 x64)"
echo -e "MariaDB client lib: ${CLIENT_A_LIB} (correct if necessary)\n"
echo "Press enter twice to confirm this is not a production server (you do not want to run this on a production machine!) or press CTRL+C to abort..."
echo "(The reason being that this script makes many packaging changes, including removing all installed [Pp]ercona*, [Mm]aria*, mysql* packages)"
read -p "1x..."
read -p "2x..."
echo -e "\nOK, proceeding..."
echo "============ Removing all mysql-related packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
#echo "============ Installing MariaDB Repo"
#sudo yum -y install https://dev.mysql.com/get/mysql-community-release-el7-5.noarch.rpm
echo "============ Installing required MD packages"
sudo yum -y install mariadb-devel mariadb-libs
echo "============ Compiling pquery-md"
g++ -o pquery-md pquery.cpp `mysql_config --cflags` `mysql_config --libs | sed "s|\-L/usr/lib64/mysql||;s|\-lmysqlclient|${CLIENT_A_LIB}|"` -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb
echo "Done!"
echo "============ Cleaning up packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
