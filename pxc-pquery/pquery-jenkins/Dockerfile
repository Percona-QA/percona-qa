FROM centos:centos7
MAINTAINER Roel Van de Paar roel.vandepaar@percona.com
RUN yum install -y which wget zip unzip lsof libaio compat-readline5 socat percona-xtrabackup perl-DBD-MySQL perl-DBI rsync openssl098e eatmydata pv qpress gzip openssl
RUN yum install -y bzr automake gcc  make  libtool autoconf pkgconfig gettext git scons    boost_req boost-devel libaio openssl-devel  check-devel gdb perf
RUN yum install -y gcc-c++ gperf ncurses-devel perl readline-devel time zlib-devel libaio-devel bison cmake wget
RUN yum install -y coreutils grep procps
ADD node.cnf /etc/my.cnf
ADD ldd_files.sh /usr/bin/ldd_files.sh
RUN chmod 755 /usr/bin/ldd_files.sh
RUN sh -c 'echo "kernel.core_pattern=core.%p.%u.%g.%s.%t.%e.DOCKER" >> /etc/sysctl.conf'
RUN sh -c 'echo "fs.suid_dumpable=1" >> /etc/sysctl.conf'
RUN sh -c 'echo "fs.aio-max-nr=300000" >> /etc/sysctl.conf'
RUN sh -c 'echo "* soft core unlimited" >> /etc/security/limits.conf'
RUN sh -c 'echo "* hard core unlimited" >> /etc/security/limits.conf'
WORKDIR /
RUN mkdir mysql
RUN wget http://jenkins.percona.com/job/build-xtradb-cluster-binaries-56/BUILD_TYPE=debug,label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
RUN unzip archive.zip
RUN tar -xzf archive/target/*.tar.gz -C /mysql --strip-components=1
RUN rm -Rf archive*
RUN groupadd -r mysql
RUN useradd -M -r -d /var/lib/mysql -s /bin/bash  -g mysql mysql
RUN /mysql/scripts/mysql_install_db --basedir=/mysql --user=mysql
EXPOSE 3306 4567 4568
