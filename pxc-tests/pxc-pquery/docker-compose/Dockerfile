FROM centos:centos7
MAINTAINER Roel Van de Paar roel.vandepaar@percona.com
RUN yum install -y which wget
ADD node.cnf /etc/my.cnf
ADD ldd_files.sh /usr/bin/ldd_files.sh
RUN chmod 755 /usr/bin/ldd_files.sh
RUN sh -c 'echo "kernel.core_pattern=core.%p.%u.%g.%s.%t.%e.DOCKER" >> /etc/sysctl.conf'
RUN sh -c 'echo "fs.suid_dumpable=1" >> /etc/sysctl.conf'
RUN sh -c 'echo "fs.aio-max-nr=300000" >> /etc/sysctl.conf'
RUN sh -c 'echo "* soft core unlimited" >> /etc/security/limits.conf'
RUN sh -c 'echo "* hard core unlimited" >> /etc/security/limits.conf'
RUN yum install -y http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm
RUN yum install -y Percona-XtraDB-Cluster-56
EXPOSE 3306 4567 4568
