#!/bin/bash

###################################################################################################
# Created By Manish Chawla, Percona LLC                                                           #
# Modified By Mohit Joshi, Percona LLC                                                            #
# This script runs PXB against Percona Server and MySQL server in a docker container              #
###################################################################################################

help() {
    echo "Usage: $0 pxb_version repo server [innovation]"
    echo "Accepted values of version: pxb24, pxb80, pxb-8x-innovation"
    echo "Accepted values of repo: main, testing"
    echo "Accepted value of server: ps, ms"
    echo "Accepted value of innovation: 8.1, 8.2"
    echo "Main repo is the percona docker image and testing repo is the perconalab docker image"
    exit 1
}

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    help
fi

pxb_version=$1
repo=$2
server=$3

if [ "$pxb_version" == "pxb-8x-innovation" ]; then
    # Check if the number of arguments is 3
    if [ "$#" -ne 4 ]; then
        echo "ERR: 'innovation' argument is required for pxb-8x-innovation. Accepted values: 8.1, 8.2"
        help
    fi
    innovation=$4
else
    innovation="" # Set innovation to an empty string for other cases
fi


if [ "$pxb_version" = "pxb-8x-innovation" ]; then
    if [ "$server" = "ms" ]; then
        container_name="mysql-$innovation"
        mysql_docker_image="mysql:$innovation"
    elif [ "$server" = "ps" ]; then
        container_name="percona-server-$innovation"
        mysql_docker_image="percona/percona-server:$innovation"
    else
        echo "Invalid product!"
        help
    fi
    if [ "$repo" = "main" ]; then
        pxb_docker_image="percona/percona-xtrabackup:$innovation"
    elif [ "$repo" = "testing" ]; then
        pxb_docker_image="perconalab/percona-xtrabackup:$innovation"
    fi
    pxb_backup_dir="pxb_backup_data:/backup_$innovation"
    target_backup_dir="/backup_$innovation"
    mount_dir="-v /tmp/mysql_data:/var/lib/mysql -v /var/run/mysqld:/var/run/mysqld"
elif [ "$pxb_version" = "pxb80" ]; then
    if [ "$server" = "ms" ]; then
        container_name="mysql-8.0"
        mysql_docker_image="mysql/mysql-server:latest"
    elif [ "$server" = "ps" ]; then
        container_name="percona-server-8.0"
        mysql_docker_image="percona/percona-server:8.0"
    else
        echo "Invalid product!"
        help
    fi
    if [ "$repo" = "main" ]; then
        pxb_docker_image="percona/percona-xtrabackup:8.0"
    elif [ "$repo" = "testing" ]; then
        pxb_docker_image="perconalab/percona-xtrabackup:8.0"
    fi
    pxb_backup_dir="pxb_backup_data:/backup_80"
    target_backup_dir="/backup_80"
    mount_dir="-v /tmp/mysql_data:/var/lib/mysql"
elif [ "$pxb_version" = "pxb24" ]; then
    if [ "$server" = "ms" ]; then
        container_name="mysql-5.7"
        mysql_docker_image="mysql/mysql-server:5.7"
    elif [ "$server" = "ps" ]; then
        container_name="percona-server-5.7"
        mysql_docker_image="percona/percona-server:5.7"
    else
        echo "Invalid product!"
        help
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
    help
fi


clean_setup() {
    # This function checks and cleans the setup

    if [ "$(sudo docker ps -a | grep $container_name)" ]; then
        sudo docker stop $container_name >/dev/null 2>&1
        sudo docker rm $container_name >/dev/null 2>&1
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
    start_mysql_container="sudo docker run --name $container_name $mount_dir -p 3306:3306 -e PERCONA_TELEMETRY_DISABLE=1 -e MYSQL_ROOT_HOST=% -e MYSQL_ROOT_PASSWORD=mysql -d $mysql_docker_image"

    mkdir /tmp/mysql_data
    sudo chmod -R 777 /tmp/mysql_data
    sudo chmod -R 777 /var/run/mysqld

    echo "Run $container_name docker container"
    if ! $start_mysql_container >>backup_log 2>&1; then
        echo "ERR: The docker command to start $container_name failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep $container_name | grep "Up" >/dev/null 2>&1; then
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
    sudo docker exec -it $container_name mysql -uroot -pmysql -Bse "SELECT @@version;" |grep -v "Using a password"

    echo "Add data in the database"
    sudo docker exec -it $container_name mysql -uroot -pmysql -e "CREATE DATABASE IF NOT EXISTS test;" >/dev/null 2>&1
    sudo docker exec -it $container_name mysql -uroot -pmysql -e "CREATE TABLE test.t1(i INT);" >/dev/null 2>&1
    sudo docker exec -it $container_name mysql -uroot -pmysql -e "INSERT INTO test.t1 VALUES (1), (2), (3), (4), (5);" >/dev/null 2>&1

    echo "Run pxb docker container, take backup and prepare it"
    echo "Using $repo repo docker image"
    sudo docker run --volumes-from $container_name -v $pxb_backup_dir -it --rm --user root $pxb_docker_image /bin/bash -c "xtrabackup --backup --datadir=/var/lib/mysql/ --target-dir=$target_backup_dir --user=root --password=mysql ; xtrabackup --prepare --target-dir=$target_backup_dir" >>backup_log 2>&1

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to run $pxb_version-$innovation failed"
        exit 1
    else
        echo "The backup and prepare was successful. Log available at: ${PWD}/backup_log"
    fi

    echo "Stop the $container_name docker container"
    sudo docker stop $container_name >>backup_log 2>&1

    sudo rm -r /tmp/mysql_data
    mkdir /tmp/mysql_data

    echo "Run pxb docker container to restore the backup"
    echo "Using $repo repo docker image"
    sudo docker run --volumes-from $container_name -v $pxb_backup_dir -it --rm --user root $pxb_docker_image /bin/bash -c "xtrabackup --copy-back --datadir=/var/lib/mysql/ --target-dir=$target_backup_dir" >>backup_log 2>&1

    if [ "$?" -ne 0 ]; then
        echo "ERR: The docker command to restore the data failed"
        exit 1
    else
        echo "The restore command was successful"
    fi

    sudo chmod -R 777 /tmp/mysql_data

    echo "Start the $container_name container with the restored data"
    if ! sudo docker start $container_name >>backup_log 2>&1; then
        echo "ERR: The docker command to start mysql 8.0 with the restored data failed"
        exit 1
    fi

    echo "Waiting for mysql to start..."
    for ((i=1; i<=180; i++)); do
        if ! sudo docker ps -a | grep $container_name >/dev/null 2>&1; then
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

    if [ "$(sudo docker exec -it $container_name mysql -uroot -pmysql -Bse 'SELECT * FROM test.t1;' | grep -v password | wc -l)" != "5" ]; then
        echo "ERR: Data could not be checked in the mysql container"
    else
        echo "Data was restored successfully"
    fi

    # Cleanup
    echo "Stopping and removing $container_name docker container"
    sudo docker stop $container_name >>backup_log 2>&1
    sudo docker rm $container_name >>backup_log 2>&1
}

# Check and clean existing installation
if [ -f backup_log ]; then
    rm backup_log
fi
clean_setup
test_pxb_docker | tee -a backup_log

# Clean up
clean_setup

echo "Logs for the tests are available at: $PWD/backup_log"
