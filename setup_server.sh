# Screen Script
touch ~/.screenrc
if [ -z "$(cat ~/.screenrc|grep 'termcapinfo xterm')" ]; then cat << EOF > ~/.screenrc
# General settings
vbell on
vbell_msg '!Bell!'
autodetach on
startup_message off
defscrollback 10000

# Termcapinfo for xterm
termcapinfo xterm* Z0=\E[?3h:Z1=\E[?3l:is=\E[r\E[m\E[2J\E[H\E[?7h\E[?1;4;6l   # Do not resize window
termcapinfo xterm* OL=1000                                                    # Increase output buffer for speed

# Remove various keyboard bindings
bind x    # Do not lock screen
bind ^x   # Idem
bind h    # Do not write out copy of screen to disk
bind ^h   # Idem
bind ^\   # Do not kill all windows/exit screen
bind .    # Disable dumptermcap

# Add keyboard bindings
bind } history
bind k kill
EOF
fi
if [ "$(grep -m1 'kernel.core_pattern=core.%p.%u.%g.%s.%t.%e' /etc/sysctl.conf)" != 'kernel.core_pattern=core.%p.%u.%g.%s.%t.%e' ]; then
  sudo sh -c 'echo "kernel.core_pattern=core.%p.%u.%g.%s.%t.%e" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 'suid_dumpable=1' /etc/sysctl.conf)" != 'fs.suid_dumpable=1' ]; then
  sudo sh -c 'echo "fs.suid_dumpable=1" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 'fs.aio-max-nr=300000' /etc/sysctl.conf)" != 'fs.aio-max-nr=300000' ]; then
  sudo sh -c 'echo "fs.aio-max-nr=300000" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 'kern.maxprocperuid=100000' /etc/sysctl.conf)" != 'kern.maxprocperuid=100000' ]; then
  sudo sh -c 'echo "kern.maxprocperuid=100000" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 'kern.maxproc=1000000' /etc/sysctl.conf)" != 'kern.maxproc=1000000' ]; then
  sudo sh -c 'echo "kern.maxproc=1000000" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '* soft core unlimited' /etc/security/limits.conf)" != '* soft core unlimited' ]; then
  sudo sh -c 'echo "* soft core unlimited" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* hard core unlimited' /etc/security/limits.conf)" != '* hard core unlimited' ]; then
  sudo sh -c 'echo "* hard core unlimited" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* hard nofile 1048576' /etc/security/limits.conf)" != '* hard nofile 1048576' ]; then
  sudo sh -c 'echo "* hard nofile 1048576" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* soft stack 20480' /etc/security/limits.conf)" != '* soft stack 20480' ]; then
  sudo sh -c 'echo "* soft stack 20480" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* hard stack 20480' /etc/security/limits.conf)" != '* hard stack 20480' ]; then
  sudo sh -c 'echo "* hard stack 20480" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* soft nproc 300000' /etc/security/limits.conf)" != '* soft nproc 300000' ]; then  # Previously; 1048576. May cause system hangs on Centos7? Was then reduced to 20480. Readjusted to 300000 as it seems that (in Bionic) the number of processes allowed accross various opened shells is cumulative. 
  sudo sh -c 'echo "* soft nproc 300000" >> /etc/security/limits.conf'
fi
if [ "$(grep -m1 '* hard nproc 300000' /etc/security/limits.conf)" != '* hard nproc 300000' ]; then  # Previously; 1048576. May cause system hangs on Centos7? Was then reduced to 20480. Readjusted to 300000 as it seems that (in Bionic) the number of processes allowed accross various opened shells is cumulative. 
  sudo sh -c 'echo "* hard nproc 300000" >> /etc/security/limits.conf'
fi

# Ensuring nproc limiter is gone or not present
if [ -r /etc/security/limits.d/90-nproc.conf ]; then
  sudo rm -f /etc/security/limits.d/90-nproc.conf
  if [ -r /etc/security/limits.d/90-nproc.conf ]; then
    echo "Tried to remove the file /etc/security/limits.d/90-nproc.conf (to enable raising of nproc) without succes. Exiting prematurely."
    exit 1
  fi
fi

sudo apt-get install -y build-essential man-db wget patch make cmake automake autoconf bzr git htop lsof gdb gcc libtool bison valgrind strace screen hdparm openssl tree vim yum-utils lshw iotop bats lzma lzma-dev git linux-headers-generic g++ libncurses5-dev libaio1 libaio-dev libjemalloc1 libjemalloc-dev libdbd-mysql libssl-dev subversion libgtest-dev zlib1g zlib1g-dbg zlib1g-dev libreadline-dev libreadline7-dbg debhelper devscripts pkg-config dpkg-dev lsb-release terminator libpam0g-dev libcurl4-openssl-dev libssh-dev fail2ban libz-dev libgcrypt20 libgcrypt20-dev libssl-dev libboost-all-dev valgrind python-mysqldb mdm clang libasan5 clang-format libbz2-dev gnutls-dev sysbench
