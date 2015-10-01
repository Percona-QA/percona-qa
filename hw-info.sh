#!/bin/bash
# Get HW info
# "./hw-info.sh short" will give output in sigle line.
RELEASE=`cat /etc/redhat-release`
KERNEL=`uname -r`
UPTIME=`uptime | sed 's|  | |g'`
MEM=`free -g | grep "Mem:" | awk '{print "Total:"$2"GB  Used:"$3"GB  Free:"$4"GB" }'`
if [ "$1" == "short" ];then
  echo "$RELEASE$KERNEL|${UPTIME:1}|$MEM"
else
  printf "OS\t: $RELEASE\n"
  printf "Kernel\t: $KERNEL\n"
  printf "Uptime\t: ${UPTIME:1}\n"
  printf "Memory\t: $MEM\n"
fi
