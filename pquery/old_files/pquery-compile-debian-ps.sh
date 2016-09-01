# For some (as yet unknown) reason, in PS, we do not need to specify a .a client library like with MS and MD. TODO: Research why.
echo "============ pquery-debian-ps (Percona Server client libs) compiler (static client libs) (This script veried to work on Debian x64)"
echo "Press enter twice to confirm this is not a production server (you do not want to run this on a production machine!) or press CTRL+C to abort..."
echo "(The reason being that this script makes many packaging changes, including removing all installed [Pp]ercona*, [Mm]aria*, mysql* packages)"
read -p "1x..."
read -p "2x..."
echo -e "\nOK, proceeding...\n"
echo "============ Removing all mysql-related packages"
sudo apt-get remove Percona* percona* maria* Maria* mysql*
echo "============ Installing Percona Repo"
echo "deb http://repo.percona.com/apt "$(lsb_release -sc)" main" | sudo tee /etc/apt/sources.list.d/percona.list
echo "deb-src http://repo.percona.com/apt "$(lsb_release -sc)" main" | sudo tee -a /etc/apt/sources.list.d/percona.list
echo "============ Installing required PS 5.6 packages"
sudo apt-get install percona-server-server-5.6
sudo apt-get install libmysqlclient-dev
echo "============ Compiling pquery-ps"
g++ -o pquery-debian-ps pquery.cpp `mysql_config --cflags` `mysql_config --libs | sed 's|lib64|lib64/mysql|'` -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb
echo "Done!"
echo "============ Cleaning up packages"
sudo apt-get remove Percona* percona* maria* Maria* mysql*
