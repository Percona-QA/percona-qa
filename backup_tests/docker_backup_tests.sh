#!/bin/bash

#################################################################################
# Created By Manish Chawla, Percona LLC                                         #
# Modified By Mohit Joshi, Percona LLC                                          #
# This script tests backup for docker containers                                #
# Usage:                                                                        #
# 1. Run the script as: ./docker_backup_tests.sh pxb24/pxb80/pxb81 main/testing #
# 3. Logs are available in: $PWD/backup_log                                     #
#################################################################################

if [ "$#" -ne 2 ]; then
    echo "Please run the script with parameters: <version as pxb24/pxb80/pxb81> <repo as main/testing>"
    echo "Main repo is the percona docker image and testing repo is the perconalab docker image"
    exit 1
fi

if [ "$1" = "pxb81" ]; then
    version=pxb81
    server="mysql-8.1"
    repo="$2"
elif [ "$1" = "pxb80" ]; then
    version=pxb80
    server="mysql-8.0"
    repo="$2"
elif [ "$1" = "pxb24" ]; then
    version=pxb24
    server="mysql-5.7"
    repo="$2"
else
    echo "Invalid version parameter. Exiting"
    exit 1
fi


clean_setup() {
    # This function checks and cleans the setup

    if [ "$1" = "pxb80" ]; then
        if [ "$(sudo docker ps -a | grep $server)" ]; then
            sudo docker stop $server >/dev/null 2>&1
            sudo docker rm $server >/dev/null 2>&1
        fi
    elif [ "$1" = "pxb81" ]; then
        if [ "$(sudo docker ps -a | grep $server)" ]; then
            sudo docker stop $server >/dev/null 2>&1
            sudo docker rm $server >/dev/null 2>&1
        fi
    else
        if [ "$(sudo docker ps -a | grep $server)" ]; then
            sudo docker stop $server >/dev/null 2>&1
            sudo docker rm $server >/dev/null 2>&1
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
    if [ "$version" = "pxb80" ]; then
        start_mysql_container="sudo docker run --name $server -v /tmp/mysql_data:/var/lib/mysql -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST=% -e MYSQL_ROOT_PASSWORD=mysql -d mysql/mysql-server:latest"
    elif [ "$version" = "pxb81" ]; then
        start_mysql_container="sudo docker run --name $server -v /tmp/mysql_data:/var/lib/mysql -v /var/run/mysqld:/var/run/mysqld -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST=% -e MYSQL_ROOT_PASSWORD=mysql -d mysql:8.1.0"
    fi

    mkdir /tmp/mysql_data

    echo "Run $server docker container"
    if ! $start_mysql_container >>backup_log 2>&1; then
        echo "ERR: The docker command to start $server failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep $server | grep "Up" >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done

    # Sleep for sometime for the server to fully come up
    sleep 20

    echo -n "Mysql started with version: "
    sudo docker exec -it $server mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it $server mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it $server mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it $server mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1

    if [ "$version" = "pxb80" ]; then
        echo "Run pxb 8.0 docker container, take backup and prepare it"
        if [[ "$1" = "main" ]]; then
          echo "Using main repo docker image"
          sudo docker run --volumes-from $server -v pxb_backup_data:/backup_80 -it --rm --user root percona/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup_80 --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup_80" >>backup_log 2>&1
        else
            echo "Using testing repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup_80 -it --rm --user root perconalab/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup_80 --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup_80" >>backup_log 2>&1
        fi
    elif [ "$version" = "pxb81" ]; then
        echo "Run pxb 8.1 docker container, take backup and prepare it"
        if [[ "$1" = "main" ]]; then
            echo "Using main repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup_81 -it --rm --user root percona/percona-xtrabackup:8.1 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup_81 --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup_81" >>backup_log 2>&1
        else
            echo "Using testing repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup_81 -it --rm --user root perconalab/percona-xtrabackup:8.1 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup_81 --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup_81" >>backup_log 2>&1
        fi
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run $version failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: ${PWD}/backup_log"
    fi

    if [ "$version" = "pxb80" ]; then
        echo "Stop the $server docker container"
        sudo docker stop $server >>backup_log 2>&1
    elif [ "$version" = "pxb81" ]; then
        echo "Stop the $server docker container"
        sudo docker stop $server >>backup_log 2>&1
    fi

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    if [ "$version" = "pxb80" ]; then
        echo "Run pxb 8.0 docker container to restore the backup"
        if [[ "$1" = "main" ]]; then
            echo "Using main repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm --user root percona/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
        else
            echo "Using testing repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm --user root perconalab/percona-xtrabackup:8.0 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
        fi
    elif [ "$version" = "pxb81" ]; then
        echo "Run pxb 8.1 docker container to restore the backup"
        if [[ "$1" = "main" ]]; then
            echo "Using main repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm --user root percona/percona-xtrabackup:8.1 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
        else
            echo "Using testing repo docker image"
            sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm --user root perconalab/percona-xtrabackup:8.1 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
        fi
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to restore the data failed"
        exit 1
    else
        echo "The restore command was successful"
    fi

    sudo chmod -R 777 /tmp/mysql_data

    echo "Start the $server container with the restored data"
    if ! sudo docker start $server >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 8.0 with the restored data failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep $server >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start with the restored data in the docker container"
            exit 1
        fi
    done

    # Sleep for sometime for the server to fully come-up
    sleep 20

    if [ "$(sudo docker exec -it $server mysql -uroot -pmysql -Bse 'SELECT * FROM test.t1;' | grep -v password | wc -l)" != "5" ]; then
        echo "ERR: Data could not be checked in the mysql container"
    else
        echo "Data was restored successfully"
    fi

    # Cleanup
    echo "Stopping and removing $server docker container"
    sudo docker stop $server >>backup_log 2>&1
    sudo docker rm $server >>backup_log 2>&1
}

test_pxb24_docker() {
    # This function runs tests for pxb 2.4 and ms 5.7 docker image

    mkdir /tmp/mysql_data

    echo "Run $server docker container"
    if ! sudo docker run --name $server -v /tmp/mysql_data:/var/lib/mysql -p 3306:3306 -p 3060:3060 -e MYSQL_ROOT_HOST='%' -e MYSQL_ROOT_PASSWORD='mysql' -d mysql/mysql-server:5.7 >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 5.7 failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a|grep $server >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start in docker container"
            exit 1
        fi
    done

    # Sleep for sometime for the server to fully come up
    sleep 20

    echo -n "Mysql started with version: "
    sudo docker exec -it $server mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it $server mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it $server mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it $server mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1
    
    echo "Run pxb 2.4 docker container, take backup and prepare it"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm percona/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm perconalab/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=/backup --user=root --password=mysql ; xtrabackup --prepare --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run pxb 5.7 failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: $HOME/backup_log"
    fi

    echo "Stop the $server docker container"
    sudo docker stop $server >>backup_log 2>&1

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    echo "Run pxb 5.7 docker container to restore the backup"
    if [[ "$1" = "main" ]]; then
        echo "Using main repo docker image"
        sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm percona/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    else
        echo "Using testing repo docker image"
        sudo docker run --volumes-from $server -v pxb_backup_data:/backup -it --rm perconalab/percona-xtrabackup:2.4 /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=/backup" >>backup_log 2>&1
    fi

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to restore the data failed"
        exit 1
    else
        echo "The restore command was successful"
    fi

    sudo chmod -R 777 /tmp/mysql_data

    echo "Start the $server container with the restored data"
    if ! sudo docker start $server >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 5.7 with the restored data failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep $server >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ $i -eq 180 ]]; then
            echo "ERR: The mysql server failed to start with the restored data in the docker container"
            exit 1
        fi
    done

    sleep 20
    if [ "$(sudo docker exec -it $server mysql -uroot -pmysql -Bse 'SELECT * FROM test.t1;' | grep -v password | wc -l)" != "5" ]; then
        echo "ERR: Data could not be checked in the mysql container"
    else
        echo "Data was restored successfully"
    fi

    # Cleanup
    echo "Stopping and removing $server docker container"
    sudo docker stop $server >>backup_log 2>&1
    sudo docker rm $server >>backup_log 2>&1
}

>backup_log

# Check and clean existing installation
clean_setup "$version"

if [ "$version" = "pxb81" ]; then
    test_pxb8_docker "$repo" | tee -a backup_log
elif [ "$version" = "pxb80" ]; then
    test_pxb8_docker "$repo" | tee -a backup_log
elif [ "$version" = "pxb24" ]; then
    test_pxb24_docker "$repo" | tee -a backup_log
fi

# Clean up
clean_setup "$1"

echo "Logs for the tests are available at: $PWD/backup_log"
