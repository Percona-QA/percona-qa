#!/bin/bash

#######################################################################################
# Created By Manish Chawla, Percona LLC                                               #
# Modified By Mohit Joshi, Percona LLC                                                #
# This script tests backup for docker containers                                      #
# Usage:                                                                              #
# 1. Run the script as: ./docker_backup_tests.sh pxb24/pxb80/pxb81 main/testing ps/ms #
# 3. Logs are available in: $PWD/backup_log                                           #
#######################################################################################

if [ "$#" -ne 3 ]; then
    echo "Please run the script with parameters: <version as pxb24/pxb80/pxb81> <repo as main/testing> <product as ps/ms>"
    echo "Main repo is the percona docker image and testing repo is the perconalab docker image"
    exit 1
fi

version=$1
repo=$2
product=$3
if [ "$version" = "pxb81" ]; then
    if [ "$product" = "ms" ]; then
      server="mysql-8.1"
      mysql_docker_image="mysql:8.1.0"
    elif [ "$product" = "ps" ]; then
      server="percona-server-8.1"
      mysql_docker_image="percona/percona-server:8.1.0"
    else
      echo "Invalid product!"
      exit 1
    fi
    if [ "$repo" = "main" ]; then
        pxb_docker_image="percona/percona-xtrabackup:8.1"
    elif [ "$repo" = "testing" ]; then
        pxb_docker_image="perconalab/percona-xtrabackup:8.1"
    fi
    pxb_backup_dir="pxb_backup_data:/backup_81"
    target_backup_dir="/backup_81"
    mount_dir="-v /tmp/mysql_data:/var/lib/mysql -v /var/run/mysqld:/var/run/mysqld"
elif [ "$version" = "pxb80" ]; then
    if [ "$product" = "ms" ]; then
      server="mysql-8.0"
      mysql_docker_image="mysql/mysql-server:latest"
    elif [ "$product" = "ps" ]; then
      server="percona-server-8.0"
      mysql_docker_image="percona/percona-server:8.0"
    else
      echo "Invalid product!"
      exit 1
    fi
    if [ "$repo" = "main" ]; then
        pxb_docker_image="percona/percona-xtrabackup:8.0"
    elif [ "$repo" = "testing" ]; then
        pxb_docker_image="perconalab/percona-xtrabackup:8.0"
    fi
    pxb_backup_dir="pxb_backup_data:/backup_80"
    target_backup_dir="/backup_80"
    mount_dir="-v /tmp/mysql_data:/var/lib/mysql"
elif [ "$version" = "pxb24" ]; then
    if [ "$product" = "ms" ]; then
      server="mysql-5.7"
      mysql_docker_image="mysql/mysql-server:5.7"
    elif [ "$product" = "ps" ]; then
      server="percona-server-5.7"
      mysql_docker_image="percona/percona-server:5.7"
    else
      echo "Invalid product!"
      exit 1
    fi
    if [ "$repo" = "main" ]; then
        pxb_docker_image="percona/percona-xtrabackup:2.4"
    elif [ "$repo" = "testing" ]; then
        pxb_docker_image="perconalab/percona-xtrabackup:2.4"
    fi
    pxb_backup_dir="pxb_backup_data:/backup"
    target_backup_dir="/backup"
    mount_dir="-v /tmp/mysql_data:/var/lib/mysql"
else
    echo "Invalid version parameter. Exiting"
    exit 1
fi


clean_setup() {
    # This function checks and cleans the setup

    if [ "$(sudo docker ps -a | grep $server)" ]; then
        sudo docker stop $server >/dev/null 2>&1
        sudo docker rm $server >/dev/null 2>&1
    fi

    if [ -d /tmp/mysql_data ]; then
        sudo rm -r /tmp/mysql_data
    fi

    echo "Removing all images and volumes not being used by any container" >>backup_log
    sudo docker image prune -a -f >>backup_log
    sudo docker volume prune -f >>backup_log
}

test_pxb_docker() {
    # This function runs tests for pxb 8.0 and ms 8.0 docker image
    start_mysql_container="sudo docker run --name $server $mount_dir -p 3306:3306 -e PERCONA_TELEMETRY_DISABLE=1 -e MYSQL_ROOT_HOST=% -e MYSQL_ROOT_PASSWORD=mysql -d $mysql_docker_image"

    mkdir /tmp/mysql_data
    sudo chmod -R 777 /tmp/mysql_data
    sudo chmod -R 777 /var/run/mysqld

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

    echo "Run pxb docker container, take backup and prepare it"
    echo "Using $repo repo docker image"
    sudo docker run --volumes-from $server -v $pxb_backup_dir -it --rm --user root $pxb_docker_image /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=$target_backup_dir --user=root --password=mysql ; xtrabackup --prepare --target-dir=$target_backup_dir" >>backup_log 2>&1

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run $version failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: ${PWD}/backup_log"
    fi

    echo "Stop the $server docker container"
    sudo docker stop $server >>backup_log 2>&1

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    echo "Run pxb docker container to restore the backup"
    echo "Using $repo repo docker image"
    sudo docker run --volumes-from $server -v $pxb_backup_dir -it --rm --user root $pxb_docker_image /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=$target_backup_dir" >>backup_log 2>&1

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

# Check and clean existing installation
rm backup_log
clean_setup
test_pxb_docker | tee -a backup_log

# Clean up
clean_setup

echo "Logs for the tests are available at: $PWD/backup_log"
