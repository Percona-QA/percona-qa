# For some (as yet unknown) reason, in PS, we do not need to specify a .a client library like with MS and MD. TODO: Research why.
echo "============ pquery-ps (Percona Server client libs) compiler (static client libs) (This script veried to work on Centos 7 x64)"
echo "Press enter twice to confirm this is not a production server (you do not want to run this on a production machine!) or press CTRL+C to abort..."
echo "(The reason being that this script makes many packaging changes, including removing all installed [Pp]ercona*, [Mm]aria*, mysql* packages)"
read -p "1x..."
read -p "2x..."
echo -e "\nOK, proceeding...\n"
echo "============ Removing all mysql-related packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
echo "============ Installing Percona Repo"
sudo yum -y install http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm
echo "============ Installing required PS 5.6 packages"
sudo yum -y install Percona-Server-devel-56 Percona-Server-client-56 Percona-Server-shared-56
echo "============ Compiling pquery-ps"
g++ -o pquery-ps pquery.cpp `mysql_config --cflags` `mysql_config --libs | sed 's|lib64|lib64/mysql|'` -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb
echo "Done!"
echo "============ Linking pquery"
if [ ! -r "./pquery" ]; then
  ln -s ./pquery-ps ./pquery
fi
echo "Done!"
echo "============ Cleaning up packages"
sudo yum remove Percona* percona* maria* Maria* mysql*
