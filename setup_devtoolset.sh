#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

echo "This script does not work, leaving here for future work or future deletion"
exit 0

# Setup newer versions of various tools
sudo yum install policycoreutils-python scl-utils gmp-devel mpfr-devel
sudo yum remove gcc gdb valgrind
echo "Checking if various devtoolset-2 packages are present"
mkdir -p /tmp/devtoolset-2
cd /tmp/devtoolset-2
yum list | grep 'devtoolset-2' > /tmp/yum_list_dts2
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-runtime.noarch')" ]; then
  if [ ! -f devtoolset-2-runtime-2.0-19.el6.1.noarch.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-runtime-2.0-19.el6.1.noarch.rpm
  fi
  sudo rpm -ivh devtoolset-2-runtime-2.0-19.el6.1.noarch.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-valgrind.x86_64')" ]; then
  if [ ! -f devtoolset-2-valgrind-3.8.1-14.2.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-valgrind-3.8.1-14.2.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-valgrind-3.8.1-14.2.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-valgrind-debuginfo.x86_64')" ]; then
  if [ ! -f devtoolset-2-valgrind-debuginfo-3.8.1-14.2.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-valgrind-debuginfo-3.8.1-14.2.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-valgrind-debuginfo-3.8.1-14.2.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-valgrind-devel.x86_64')" ]; then
  if [ ! -f devtoolset-2-valgrind-devel-3.8.1-14.2.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-valgrind-devel-3.8.1-14.2.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-valgrind-devel-3.8.1-14.2.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-valgrind-openmpi.x86_64')" ]; then
  if [ ! -f devtoolset-2-valgrind-openmpi-3.8.1-14.2.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-valgrind-openmpi-3.8.1-14.2.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-valgrind-openmpi-3.8.1-14.2.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gdb.x86_64')" ]; then
  if [ ! -f devtoolset-2-gdb-7.6-34.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gdb-7.6-34.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gdb-7.6-34.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gdb-debuginfo.x86_64')" ]; then
  if [ ! -f devtoolset-2-gdb-debuginfo-7.6-34.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gdb-debuginfo-7.6-34.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gdb-debuginfo-7.6-34.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gdb-doc.noarch')" ]; then
  if [ ! -f devtoolset-2-gdb-doc-7.6-34.el6.noarch.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gdb-doc-7.6-34.el6.noarch.rpm
  fi
  sudo rpm -ivh devtoolset-2-gdb-doc-7.6-34.el6.noarch.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gdb-gdbserver.x86_64')" ]; then
  if [ ! -f devtoolset-2-gdb-gdbserver-7.6-34.el6.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gdb-gdbserver-7.6-34.el6.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gdb-gdbserver-7.6-34.el6.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gcc.x86_64')" ]; then
  if [ ! -f devtoolset-2-gcc-4.8.1-4.el6.1.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gcc-4.8.1-4.el6.1.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gcc-4.8.1-4.el6.1.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-libstdc++-devel.x86_64')" ]; then
  if [ ! -f devtoolset-2-libstdc++-devel-4.8.1-4.el6.1.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-libstdc++-devel-4.8.1-4.el6.1.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-libstdc++-devel-4.8.1-4.el6.1.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gcc-c++.x86_64')" ]; then
  if [ ! -f devtoolset-2-gcc-c++-4.8.1-4.el6.1.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gcc-c++-4.8.1-4.el6.1.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gcc-c++-4.8.1-4.el6.1.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gcc-debuginfo.x86_64')" ]; then
  if [ ! -f devtoolset-2-gcc-debuginfo-4.8.1-4.el6.1.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gcc-debuginfo-4.8.1-4.el6.1.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gcc-debuginfo-4.8.1-4.el6.1.x86_64.rpm
fi
if [ -z "$(cat /tmp/yum_list_dts2 | grep '2-gcc-plugin-devel.x86_64')" ]; then
  if [ ! -f devtoolset-2-gcc-plugin-devel-4.8.1-4.el6.1.x86_64.rpm ]; then
    wget http://puias.princeton.edu/data/puias/DevToolset/6/x86_64/devtoolset-2-gcc-plugin-devel-4.8.1-4.el6.1.x86_64.rpm
  fi
  sudo rpm -ivh devtoolset-2-gcc-plugin-devel-4.8.1-4.el6.1.x86_64.rpm
fi

# Bash Profile
if ! egrep -qi "export CC=" ~/.bash_profile; then
  echo "export CC=/opt/rh/devtoolset-2/root/usr/bin/gcc" >> ~/.bash_profile
fi
if ! egrep -qi "export CPP=" ~/.bash_profile; then
  echo "export CPP=/opt/rh/devtoolset-2/root/usr/bin/cpp" >> ~/.bash_profile
fi
if ! egrep -qi "export CXX=" ~/.bash_profile; then
  echo "export CXX=/opt/rh/devtoolset-2/root/usr/bin/c++" >> ~/.bash_profile
fi
if ! egrep -qi "alias gcc" ~/.bash_profile; then
  echo "alias gcc=/opt/rh/devtoolset-2/root/usr/bin/gcc" >> ~/.bash_profile
fi
if ! egrep -qi "alias gcc-c" ~/.bash_profile; then
  echo "alias gcc-c++=/opt/rh/devtoolset-2/root/usr/bin/c++" >> ~/.bash_profile
fi
if ! egrep -qi "alias gdb" ~/.bash_profile; then
  echo "alias gdb=/opt/rh/devtoolset-2/root/usr/bin/gdb" >> ~/.bash_profile
fi
if ! egrep -qi "alias valgrind" ~/.bash_profile; then
  echo "alias valgrind=/opt/rh/devtoolset-2/root/usr/bin/valgrind" >> ~/.bash_profile
fi

