#!/bin/bash

# Handy command to see per-user pid max settings, and current status;
# cat /sys/fs/cgroup/pids/user.slice/user-${UID}.slice/pids.max  # or use ${EUID}, change pids.max to others
# cat /sys/fs/cgroup/pids/user.slice/user-${UID}.slice/pids.current

# References
# https://www.ibm.com/support/knowledgecenter/SSEPGG_11.1.0/com.ibm.db2.luw.qb.server.doc/doc/t0008238.html
# https://www.serverwatch.com/server-tutorials/set-user-limits-with-pamlimits-and-limits.conf.html

echo "Substantial changes will be made to the system configuration of this machine. Press CTRL+C within the next 7 seconds to abort if you are not sure if that is a wise idea."
echo "Script assumes that this machine is a Ubuntu 18.04 server!"
echo "Script assumes current user is sudo-enabled."
sleep 7

sudo snap install shellcheck
sudo snap install shfmt

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
echo "These settings are for a 128GB Memory server (google cloud instance of that size or similar)"
if [ "$(grep -m1 '^kernel.core_pattern=core.%p.%u.%g.%s.%t.%e' /etc/sysctl.conf)" != 'kernel.core_pattern=core.%p.%u.%g.%s.%t.%e' ]; then
  sudo sh -c 'echo "kernel.core_pattern=core.%p.%u.%g.%s.%t.%e" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^suid_dumpable=1' /etc/sysctl.conf)" != 'fs.suid_dumpable=1' ]; then
  sudo sh -c 'echo "fs.suid_dumpable=1" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^fs.aio-max-nr=99999999' /etc/sysctl.conf)" != 'fs.aio-max-nr=99999999' ]; then
  sudo sh -c 'echo "fs.aio-max-nr=99999999" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^fs.file-max=99999999' /etc/sysctl.conf)" != 'fs.file-max=99999999' ]; then
  sudo sh -c 'echo "fs.file-max=99999999" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^kernel.pid_max=4194304' /etc/sysctl.conf)" != 'kernel.pid_max=4194304' ]; then
  sudo sh -c 'echo "kernel.pid_max=4194304" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^kernel.threads-max=99999999' /etc/sysctl.conf)" != 'kernel.threads-max=99999999' ]; then
  sudo sh -c 'echo "kernel.threads-max=99999999" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^kernel.sem = 32768 1073741824 2000 32768' /etc/sysctl.conf)" != 'kernel.sem = 32768 1073741824 2000 32768' ]; then
  sudo sh -c 'echo "kernel.sem = 32768 1073741824 2000 32768" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^kernel.shmmni=32768' /etc/sysctl.conf)" != 'kernel.shmmni=32768' ]; then
  sudo sh -c 'echo "kernel.shmmni=32768" >> /etc/sysctl.conf'  # 32768 is the effective max value
fi
if [ "$(grep -m1 '^kernel.msgmax=65536' /etc/sysctl.conf)" != 'kernel.msgmax=65536' ]; then
  sudo sh -c 'echo "kernel.msgmax=65536" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^kernel.msgmni=32768' /etc/sysctl.conf)" != 'kernel.msgmni=32768' ]; then
  sudo sh -c 'echo "kernel.msgmni=32768" >> /etc/sysctl.conf'  # 32768 is the effective max value
fi
if [ "$(grep -m1 '^kernel.msgmnb=65536' /etc/sysctl.conf)" != 'kernel.msgmnb=65536' ]; then
  sudo sh -c 'echo "kernel.msgmnb=65536" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^m.max_map_count=1048576' /etc/sysctl.conf)" != 'vm.max_map_count=1048576' ]; then
  sudo sh -c 'echo "vm.max_map_count=1048576" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^vm.swappiness=5' /etc/sysctl.conf)" != 'vm.swappiness=5' ]; then
  sudo sh -c 'echo "vm.swappiness=5" >> /etc/sysctl.conf'
fi
# Attemt to improve memory management for testing servers, with thanks:
# https://superuser.com/a/1150229/457699
# https://serverfault.com/a/142003/129146
# https://sysctl-explorer.net/vm/oom_dump_tasks/
# https://www.kernel.org/doc/Documentation/sysctl/vm.txt
if [ "$(grep -m1 '^vm.overcommit_memory=1' /etc/sysctl.conf)" != 'vm.overcommit_memory=1' ]; then
  sudo sh -c 'echo "vm.overcommit_memory=1" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^vm.oom_dump_tasks=0' /etc/sysctl.conf)" != 'vm.oom_dump_tasks=0' ]; then
  sudo sh -c 'echo "vm.oom_dump_tasks=0" >> /etc/sysctl.conf'
fi
if [ "$(grep -m1 '^vm.panic_on_oom=0' /etc/sysctl.conf)" != 'vm.panic_on_oom=0' ]; then
  sudo sh -c 'echo "vm.panic_on_oom=0" >> /etc/sysctl.conf'
fi

# Note that a high number (>20480) for soft+hard nproc may cause system instability/hang on Centos7
sudo bash -c "cat << EOF > /etc/security/limits.conf
* soft core unlimited
* hard core unlimited
* soft data unlimited
* hard data unlimited
* soft fsize unlimited
* hard fsize unlimited
* soft memlock unlimited
* hard memlock unlimited
* soft nofile 1048576
* hard nofile 1048576
* soft rss unlimited
* hard rss unlimited
* soft stack unlimited
* hard stack unlimited
* soft cpu unlimited
* hard cpu unlimited
* soft nproc unlimited
* hard nproc unlimited
* soft as unlimited
* hard as unlimited
* soft maxlogins unlimited
* hard maxlogins unlimited
* soft maxsyslogins unlimited
* hard maxsyslogins unlimited
* soft locks unlimited
* hard locks unlimited
* soft sigpending unlimited
* hard sigpending unlimited
* soft msgqueue unlimited
* hard msgqueue unlimited
EOF"

if [ "$(grep -m1 '^UserTasksMax=infinity' /etc/systemd/logind.conf)" != 'UserTasksMax=infinity' ]; then
  sudo sh -c 'echo "UserTasksMax=infinity" >> /etc/systemd/logind.conf'
fi

# Ensuring nproc limiter is gone or not present
if [ -r /etc/security/limits.d/90-nproc.conf ]; then
  sudo rm -f /etc/security/limits.d/90-nproc.conf
  if [ -r /etc/security/limits.d/90-nproc.conf ]; then
    echo "Tried to remove the file /etc/security/limits.d/90-nproc.conf (to enable raising of nproc) without succes. Exiting prematurely."
    exit 1
  fi
fi

sudo apt-get install -y build-essential man-db wget patch make cmake automake autoconf bzr git htop lsof gdb gcc libtool bison valgrind strace screen hdparm openssl tree vim yum-utils lshw iotop bats lzma lzma-dev git linux-headers-generic g++ libncurses5-dev libaio1 libaio-dev libjemalloc1 libjemalloc-dev libdbd-mysql libssl-dev subversion libgtest-dev zlib1g zlib1g-dbg zlib1g-dev libreadline-dev libreadline7-dbg debhelper devscripts pkg-config dpkg-dev lsb-release terminator libpam0g-dev libcurl4-openssl-dev libssh-dev fail2ban libz-dev libgcrypt20 libgcrypt20-dev libssl-dev libboost-all-dev valgrind python-mysqldb mdm clang libasan5 clang-format libbz2-dev gnutls-dev sysbench bbe

echo "An example for /etc/fstab:"
echo "---------------------------------------------------------------------------------------"
echo "LABEL=cloudimg-rootfs                     /         ext4  defaults 0 0"
echo "LABEL=UEFI                                /boot/efi vfat  defaults 0 0"
echo "UUID=someuuid-uuid-uuid-uuid-uuidsomeuuid /data     ext4  discard,defaults,nofail 0 2"
echo "tmpfs                                     /dev/shm  tmpfs defaults,rw,nosuid,nodev,noatime,nofail,size=90G 0 0"
echo "/swapfile swap swap defaults,nofail 0 0"
echo "---------------------------------------------------------------------------------------"
echo "Create swapfile like this:"
echo "  sudo fallocate -l 16G /swapfile"
echo "  sudo chmod 600 /swapfile"
echo "  sudo mkswap /swapfile"
echo "  sudo swapon /swapfile"
echo "Then add the /swapfile line to the /etc/fstab file as shown above"

