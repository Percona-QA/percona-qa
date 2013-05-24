# Quick reducer status output (number of lines processed by each mysqld) 
# Compare this with the number of original input lines, and you can workout how far along things are
ps -ef | grep mysqld | grep subreducer | \
  sed "s/.*:[0-9][0-9] //;s/d .*--socket/ --socket/;s/\.sock .*/.sock -uroot -e\"show global status like 'Queries'\" | grep Queries/" > /tmp/_qstat1.sh; 
chmod +x /tmp/_qstat1.sh
/tmp/qstat1.sh
rm -f /tmp/qstat1.sh
