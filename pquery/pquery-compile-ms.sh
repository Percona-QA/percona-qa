echo "============ pquery-ms (MySQL Server client libs) compiler (static client libs) (This script veried to work on Centos 7 x64)"
echo "Press enter twice to confirm this is not a production server (you do not want to run this on a production machine!) or press CTRL+C to abort..."
echo "(The reason being that this script makes many packaging changes, including removing all installed [Pp]ercona*, [Mm]aria*, mysql* packages)"
read -p "1x..."
read -p "2x..."
echo -e "\nOK, proceeding..."
echo "============ Removing all mysql-related packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
echo "============ Installing MySQL Repo"
sudo yum -y install https://dev.mysql.com/get/mysql-community-release-el7-5.noarch.rpm
echo "============ Installing required MS packages"
sudo yum -y install mysql-community-libs mysql-community-devel mysql-community-client mysql-community-common
echo "============ Compiling pquery-ms"
g++ -o pquery-ms pquery.cpp `mysql_config --cflags` `mysql_config --libs | sed "s|-L/usr/lib64/mysql||;s|-lmysqlclient|/usr/lib64/mysql/libmysqlclient.a|"` -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb
echo "Done!"
echo "============ Cleaning up packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
