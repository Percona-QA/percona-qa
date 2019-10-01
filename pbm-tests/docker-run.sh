#!/usr/bin/env bash

docker run --name=pbm-test --network="host" \
-e MINIO_ACCESS_KEY_ID=$MINIO_ACCESS_KEY_ID \
-e MINIO_SECRET_ACCESS_KEY=$MINIO_SECRET_ACCESS_KEY \
perconalab/pbm-test:latest https://github.com/percona/percona-backup-mongodb.git master t https://www.percona.com/downloads/percona-server-mongodb-4.2/percona-server-mongodb-4.2.0-1/binary/tarball/percona-server-mongodb-4.2.0-1-bionic-x86_64.tar.gz

