FROM ubuntu:bionic

RUN apt update && apt install -y git wget default-jre subunit make

ADD https://github.com/brianfrankcooper/YCSB/releases/download/0.15.0/ycsb-mongodb-binding-0.15.0.tar.gz /
ADD https://github.com/feliixx/mgodatagen/releases/download/0.7.5/mgodatagen_linux_x86_64.tar.gz /
RUN tar -xf /ycsb-mongodb-binding-0.15.0.tar.gz && rm -f /ycsb-mongodb-binding-0.15.0.tar.gz
RUN mkdir -p /mgodatagen && tar -xf /mgodatagen_linux_x86_64.tar.gz -C /mgodatagen && rm -f /mgodatagen_linux_x86_64.tar.gz
ADD https://dl.google.com/go/go1.12.7.linux-amd64.tar.gz /
RUN tar -C /usr/local -xzf /go1.12.7.linux-amd64.tar.gz && rm -f /go1.12.7.linux-amd64.tar.gz

COPY docker-run.sh .

ENTRYPOINT ["/docker-run.sh"]
CMD []
