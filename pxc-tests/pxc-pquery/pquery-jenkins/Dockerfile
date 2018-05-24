FROM pqueryjenkins
WORKDIR /
RUN mkdir mysql
RUN wget http://jenkins.percona.com/job/pxc56.build/BUILD_TYPE=release,label_exp=centos6-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
RUN unzip archive.zip
RUN tar -xzf archive/target/*.tar.gz -C /mysql --strip-components=1
RUN rm -Rf archive*
RUN groupadd -r mysql
RUN useradd -M -r -d /var/lib/mysql -s /bin/bash  -g mysql mysql
RUN /mysql/scripts/mysql_install_db --basedir=/mysql --user=mysql
EXPOSE 3306 4567 4568
