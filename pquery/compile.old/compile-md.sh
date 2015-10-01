# Compile pquery from installed mariadb-devel package
# If you get an error like this:

# Then try this:
#   $ sudo vi /usr/include/mysql/my_config_x86_64.h
# Comment out the following lines (almost at the end of the file):
#   #ifdef __GLIBC__
#   #error <my_config.h> MUST be included first!
#   #endif
# Like so:
#   /*#ifdef __GLIBC__
#   #error <my_config.h> MUST be included first!
#   #endif*/
# Then try re-compile. Not sure what this does, but it works.

sudo yum install mariadb-devel
g++ -o pquery-md pquery.cpp `mysql_config --libs` `mysql_config --cflags` -Werror -Wextra -Werror -O3 -pipe -march=native -mtune=generic -std=gnu++11 -ggdb
echo "Done! You may now want to uninstall the mariadb-devel package. To do so, execute;"
echo "$ sudo yum remove mariadb-devel"
