#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

while (true); do ./generator.sh 200000; sed -i "s|RocksDB|InnoDB|;s|TokuDB|InnoDB|" out.sql; cp out.sql ~/ongoing.sql; sleep 600; done
