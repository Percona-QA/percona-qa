#!/usr/bin/env bash

docker run --name=pbm-test --network="host" \
-e MINIO_ACCESS_KEY_ID=$MINIO_ACCESS_KEY_ID \
-e MINIO_SECRET_ACCESS_KEY=$MINIO_SECRET_ACCESS_KEY \
perconalab/pbm-test:latest https://github.com/percona/percona-backup-mongodb.git development t https://www.percona.com/downloads/percona-server-mongodb-LATEST/percona-server-mongodb-4.0.10-5/binary/tarball/percona-server-mongodb-4.0.10-5-bionic-x86_64.tar.gz

