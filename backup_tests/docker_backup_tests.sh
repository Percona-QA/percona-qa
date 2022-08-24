#!/bin/bash

##########################################################################
# Created By Manish Chawla, Percona LLC                                  #
# This script tests backup for docker containers                         #
# Usage:                                                                 #
# 1. Run the script as: ./docker_backup_tests.sh pxb24/pxb8 main/testing #
# 3. Logs are available in: $PWD/backup_log                              #
##########################################################################

if [ "$#" -ne 2 ]; then
    echo "Please run the script with parameters: <version as pxb24/pxb8> <repo as main/testing>"
    echo "Main repo is the percona docker image and testing repo is the perconalab docker image"
    exit 1
fi

clean_setup() {
    # This function checks and cleans the setup

    if [ "$1" = "pxb8" ]; then
        if [ "$(sudo docker ps -a | grep mysql-8.0)" ]; then
            sudo docker stop mysql-8.0 >/dev/null 2>&1
            sudo docker rm mysql-8.0 >/dev/null 2>&1
        fi
    else
        if [ "$(sudo docker ps -a | grep mysql-5.7)" ]; then
            sudo docker stop mysql-5.7 >/dev/null 2>&1
            sudo docker rm mysql-5.7 >/dev/null 2>&1
        fi
    fi

    if [ -d /tmp/mysql_data ]; then
        sudo rm -r /tmp/mysql_data
    fi

    echo "Removing all images and volumes not being used by any container" >>backup_log
    sudo docker image prune -a -f >>backup_log
    sudo docker volume prune -f >>backup_log
}

test_pxb8_docker() {
    # This function runs tests for pxb 8.0 and ms 8.0 docker image

    mkdir /tmp/mysql_data

    echo "Run mysql 8.0 docker container"
    if ! sudo docker run --name mysql-8.0 -v /tmp/mysql_data:/var/lib/mysql -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST='%' -e MYSQL_ROOT_PASSWORD='mysql' -d mysql/mysql-server:8.0 >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 8.0 failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a|grep mysql-8.0|grep healthy >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done

    echo -n "Mysql started with version: "
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1

    echo "Run pxb 8.0 docker container, take backup and prepare it"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from mysql-8.0 -v pxb_backup_data:/backup -it --rm --user root percona/percona-xtrabackup /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from mysql-8.0 -v pxb_backup_data:/backup -it --rm --user root perconalab/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run pxb 8.0 failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: ${PWD}/backup_log"
    fi

    echo "Stop the mysql-8.0 docker container"
    sudo docker stop mysql-8.0 >>backup_log 2>&1

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    echo "Run pxb 8.0 docker container to restore the backup"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from mysql-8.0 -v pxb_backup_data:/backup -it --rm --user root percona/percona-xtrabackup /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from mysql-8.0 -v pxb_backup_data:/backup -it --rm --user root perconalab/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to restore the data failed"
        exit 1
    else
        echo "The restore command was successful"
    fi

    sudo chmod -R 777 /tmp/mysql_data

    echo "Start the mysql 8.0 container with the restored data"
    if ! sudo docker start mysql-8.0 >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 8.0 with the restored data failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep mysql-8.0 | grep healthy >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start with the restored data in the docker container"
            exit 1
        fi
    done

    if [ "$(sudo docker exec -it mysql-8.0 mysql -uroot -pmysql -Bse 'SELECT * FROM test.t1;' | grep -v password | wc -l)" != "5" ]; then
        echo "ERR: Data could not be checked in the mysql container"
    else
        echo "Data was restored successfully"
    fi

    # Cleanup
    echo "Stopping and removing mysql-8.0 docker container"
    sudo docker stop mysql-8.0 >>backup_log 2>&1
    sudo docker rm mysql-8.0 >>backup_log 2>&1
}

test_pxb24_docker() {
    # This function runs tests for pxb 2.4 and ms 5.7 docker image

    mkdir /tmp/mysql_data

    echo "Run mysql 5.7 docker container"
    if ! sudo docker run --name mysql-5.7 -v /tmp/mysql_data:/var/lib/mysql -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST='%' -e MYSQL_ROOT_PASSWORD='mysql' -d mysql/mysql-server:5.7 >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 5.7 failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a|grep mysql-5.7|grep healthy >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done

    echo -n "Mysql started with version: "
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1
    
    echo "Run pxb 2.4 docker container, take backup and prepare it"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from mysql-5.7 -v pxb_backup_data:/backup -it --rm percona/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from mysql-5.7 -v pxb_backup_data:/backup -it --rm perconalab/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run pxb 5.7 failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: $HOME/backup_log"
    fi

    echo "Stop the mysql-5.7 docker container"
    sudo docker stop mysql-5.7 >>backup_log 2>&1

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    echo "Run pxb 5.7 docker container to restore the backup"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from mysql-5.7 -v pxb_backup_data:/backup -it --rm percona/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from mysql-5.7 -v pxb_backup_data:/backup -it --rm perconalab/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to restore the data failed"
        exit 1
    else
        echo "The restore command was successful"
    fi

    sudo chmod -R 777 /tmp/mysql_data

    echo "Start the mysql 5.7 container with the restored data"
    if ! sudo docker start mysql-5.7 >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 5.7 with the restored data failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep mysql-5.7 | grep healthy >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start with the restored data in the docker container"
            exit 1
        fi
    done

    if [ "$(sudo docker exec -it mysql-5.7 mysql -uroot -pmysql -Bse 'SELECT * FROM test.t1;' | grep -v password | wc -l)" != "5" ]; then
        echo "ERR: Data could not be checked in the mysql container"
    else
        echo "Data was restored successfully"
    fi

    # Cleanup
    echo "Stopping and removing mysql-5.7 docker container"
    sudo docker stop mysql-5.7 >>backup_log 2>&1
    sudo docker rm mysql-5.7 >>backup_log 2>&1
}

>backup_log
# Check and clean existing installation
clean_setup "$1"

if [ "$1" = "pxb8" ]; then
    test_pxb8_docker "$2" | tee -a backup_log
else
    test_pxb24_docker "$2" | tee -a backup_log
fi

# Clean up
clean_setup "$1"

echo "Logs for the tests are available at: $PWD/backup_log"
