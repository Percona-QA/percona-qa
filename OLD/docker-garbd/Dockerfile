FROM centos:centos7
MAINTAINER Roel Van de Paar roel.vandepaar@percona.com
RUN yum install -y which wget
ADD node.cnf /etc/my.cnf
RUN yum install -y http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm
RUN yum install -y Percona-XtraDB-Cluster-56
RUN curl -s http://jenkins.percona.com/yum-repo/percona-dev.repo > /etc/yum.repos.d/percona-dev.repo
RUN yum install -y http://epel.check-update.co.uk/7/x86_64/e/epel-release-7-5.noarch.rpm
RUN yum install -y which lsof libaio compat-readline5 socat percona-xtrabackup perl-DBD-MySQL perl-DBI rsync openssl098e eatmydata pv qpress gzip openssl
RUN yum install -y bzr automake gcc  make  libtool autoconf pkgconfig gettext git scons    boost_req boost-devel libaio openssl-devel  check-devel gdb perf
RUN yum install -y gcc-c++ gperf ncurses-devel perl readline-devel time zlib-devel libaio-devel bison cmake
RUN yum install -y coreutils grep procps
WORKDIR /
RUN git clone --depth=1 https://github.com/percona/galera
WORKDIR /galera
RUN scons -j47 --config=force  libgalera_smm.so garb/garbd
RUN install libgalera_smm.so /usr/lib64/
ADD node.cnf /etc/my.cnf
EXPOSE 3306 4567 4568

