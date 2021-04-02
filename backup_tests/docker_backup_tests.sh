#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for docker containers                       #
# Usage:                                                               #
# 1. Run the script as: ./docker_backup_tests.sh pxb24/pxb8            #
# 3. Logs are available in: $HOME/backup_log                           #
########################################################################

if [ "$#" -ne 1 ]; then
    echo "Please run the script with parameter: pxb24 or pxb8"
    exit 1
fi

test_pxb8_docker() {
    # This function runs tests for pxb 8.0 and ms 8.0 docker image

    echo "Run mysql 8.0 docker container"
    if ! sudo docker run --name mysql-8.0 -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST='%' -e MYSQL_ROOT_PASSWORD='mysql' -d mysql/mysql-server:latest ; then
        echo "ERR: The docker command to start mysql 8.0 failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        sudo docker exec -it mysql-8.0 mysqladmin ping --user=root -pmysql >/dev/null 2>&1
        if [ "$?" -ne 0 ]; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done
    sleep 20

    echo -n "Mysql started with version: "
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1

    echo "Run pxb 8.0 docker container, take backup and prepare it"
    if ! sudo docker run --volumes-from mysql-8.0 -it --rm percona/percona-xtrabackup /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >backup_log 2>&1; then
        echo "ERR: The docker command to run pxb 8.0 failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: $HOME/backup_log"
    fi

    # Cleanup
    echo "Stopping and removing mysql-8.0 docker container"
    sudo docker stop mysql-8.0
    sudo docker rm mysql-8.0
}

test_pxb24_docker() {
    # This function runs tests for pxb 2.4 and ms 5.7 docker image

    echo "Run mysql 5.7 docker container"
    if ! sudo docker run --name mysql-5.7 -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST='%' -e MYSQL_ROOT_PASSWORD='mysql' -d mysql/mysql-server:5.7 ; then
        echo "ERR: The docker command to start mysql 5.7 failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        sudo docker exec -it mysql-5.7 mysqladmin ping --user=root -pmysql >/dev/null 2>&1
        if [ "$?" -ne 0 ]; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done
    sleep 20

    echo -n "Mysql started with version: "
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1
    
    echo "Run pxb 2.4 docker container, take backup and prepare it"
    if ! sudo docker run --volumes-from mysql-5.7 -it --rm percona/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >backup_log 2>&1; then
        echo "ERR: The docker command to run pxb 5.7 failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: $HOME/backup_log"
    fi

    # Cleanup
    echo "Stopping and removing mysql-5.7 docker container"
    sudo docker stop mysql-5.7
    sudo docker rm mysql-5.7

    echo "Removing all images and volumes not being used by any container"
    sudo docker image prune -a -f
    sudo docker volume prune -f
}

echo "Removing all images and volumes not being used by any container"
sudo docker image prune -a -f
sudo docker volume prune -f

if [ "$1" = "pxb8" ]; then
    test_pxb8_docker
else
    test_pxb24_docker
fi
