#!/bin/bash

MYSQL_DIR=$HOME/pxc_8.0/bld_8.0.35/install
SOCKET=/home/mohit.joshi/pxc_8.0/bld_8.0.35/install/pxc-node/dn1/mysqld.sock

create_table_and_load_data() {
  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "DROP DATABASE IF EXISTS test; CREATE DATABASE test"
  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "CREATE TABLE test.tt_5_p (ip_col INT AUTO_INCREMENT, ipkey INT, v1 VARCHAR(11), v2 VARCHAR(10),  PRIMARY KEY(ipkey, ip_col), INDEX tt_5_pi3(ip_col, v2 DESC, ipkey, v1)  ) ENCRYPTION='Y' ROW_FORMAT=REDUNDANT ENGINE=INNODB PARTITION BY KEY (ip_col) PARTITIONS 15"

  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "INSERT INTO tt_5_p (ip_col, ipkey, v1, v2) VALUES(NULL, 3542, 'jHuK6JzykX', 'JY0eyoSRB'), (NULL, 5405, 'V', 'U6WRSX'), (NULL, 223, 'o', 'rzB6SJtG'), (NULL, 3669, 'u', 'N'), (NULL, 8660, 'LvneJQD', 'cw'), (NULL, 1956, 'Uf', 'k8cl'), (NULL, 5016, 'TFatA', 'I2xGEOt6C'), (NULL, 4182, '', 'h8G'), (NULL, 7425, '3eZr', ''), (NULL, 168, '', 'iCT'), (NULL, 2468, 'TibZAX', 'AR'), (NULL, 3455, 'JHp', ''), (NULL, 4471, '', 'sZ'), (NULL, 3160, '1K5X3t7FYa', 'k'), (NULL, 2241, '8NRGk', '5WR0W'), (NULL, 1567, 'Zf', '8XR'), (NULL, 2138, 'ZnNE', ''), (NULL, 1190, 'x', '9EDRFhcnU'), (NULL, 6175, '', '3VJ5N'), (NULL, 3523, '0qmhAnFx39E', 'r')"
  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "INSERT INTO test.tt_5_p  ( ip_col ,ipkey ,v1 ,v2 ) VALUES( NULL, 7280, 'mf9EA9XkZuD', 'UN6' )"
}

run_alter_db() {
  queries=("ALTER DATABASE test ENCRYPTION 'Y';" "ALTER DATABASE test ENCRYPTION 'N';")
  random_index=$((RANDOM % 2))
  selected_query="${queries[$random_index]}"
  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "$selected_query"
}


run_optimize_partition() {
  random_partition=$((RANDOM % 16))
  optimize_queries=("ALTER TABLE tt_5_p OPTIMIZE PARTITION p$random_partition;" "OPTIMIZE TABLE tt_5_p;")
  random_index=$((RANDOM % 2))
  selected_query="${optimize_queries[$random_index]}"
  $MYSQL_DIR/bin/mysql -uroot --database=test -S$SOCKET -e "$selected_query"
}

# Start test
create_table_and_load_data

# Start time
start_time=$(date +%s)

# Run the loop for 60 seconds
while [ $(( $(date +%s) - start_time )) -lt 60 ]; do
    run_alter_db >/dev/null 2>&1 &
    run_optimize_partition >/dev/null 2>&1 &
    run_alter_db >/dev/null 2>&1 &
    run_optimize_partition >/dev/null 2>&1 &
    wait
    sleep 1  # Adjust the sleep duration as needed
done

