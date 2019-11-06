pipeline {
  agent any
  parameters {
    choice(name: 'TEST_CASE', choices: ['all','master_slave_test','master_multi_slave_test','master_master_test','msr_test','mtr_test','mgr_test','xb_master_slave_test'], description: 'Test case to run.')
    string(name: 'GIT_REPO', defaultValue: 'https://github.com/percona/percona-server.git', description: 'PS repo for build.')
    string(name: 'BRANCH', defaultValue: '8.0', description: 'Target branch')
    string(name: 'PT_BIN', defaultValue: 'https://www.percona.com/downloads/percona-toolkit/2.2.20/tarball/percona-toolkit-2.2.20.tar.gz', description: 'PT binary tarball')
    string(name: 'PXB_BIN', defaultValue: 'https://www.percona.com/downloads/Percona-XtraBackup-LATEST/Percona-XtraBackup-8.0-7/binary/tarball/percona-xtrabackup-8.0.7-Linux-x86_64.libgcrypt20.tar.gz', description: 'PXB binary tarball')
  }
  environment {
    DOCKER_OS = "ubuntu:bionic"
    TEST_DIR="repl-test"
  }
  stages {
    stage('Build PS binary') {
      steps {
        script {
          currentBuild.description = "${BRANCH}-${TEST_CASE}"
          def setupResult = build job: 'percona-server-8.0-pipeline', parameters: [
            string(name: 'GIT_REPO', value: "${GIT_REPO}"),
            string(name: 'BRANCH', value: "${BRANCH}"),
            string(name: 'DOCKER_OS', value: "${DOCKER_OS}"),
            string(name: 'CMAKE_BUILD_TYPE', value: "Debug"),
            string(name: 'WITH_TOKUDB', value: "ON"),
            string(name: 'WITH_ROCKSDB', value: "ON"),
            string(name: 'WITH_ROUTER', value: "ON"),
            string(name: 'WITH_MYSQLX', value: "ON"),
            string(name: 'DEFAULT_TESTING', value: "no"),
            string(name: 'HOTBACKUP_TESTING', value: "no"),
            string(name: 'TOKUDB_ENGINES_MTR', value: "no")
          ], propagate: false, wait: true
          // Navigate to jenkins > Manage jenkins > In-process Script Approval
          // staticMethod org.codehaus.groovy.runtime.DefaultGroovyMethods putAt java.lang.Object java.lang.String java.lang.Object
          env['PIPELINE_BUILD_NUMBER'] = setupResult.getNumber()
        }
        sh '''
          echo "${PIPELINE_BUILD_NUMBER}" > PIPELINE_BUILD_NUMBER
        '''
        archiveArtifacts artifacts: 'PIPELINE_BUILD_NUMBER', fingerprint: true
        
        copyArtifacts filter: 'public_url', fingerprintArtifacts: true, projectName: 'percona-server-8.0-pipeline', selector: specific("${PIPELINE_BUILD_NUMBER}")
        script {
          env['PS_BIN'] = sh(script: 'cat public_url|grep binary|grep -o "https://.*"', returnStdout: true)
        }
      }
    }
    stage('Run tests') {
      parallel {
        stage('Test InnoDB') {
          agent {
            label "min-bionic-x64"
          }
          environment {
            TEST_DESCRIPTION="-innodb-${TEST_CASE}"
          }
          steps {
            script {
              try {
                sh '''
                # prepare
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
                sudo percona-release enable original
                sudo apt update
                UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive sudo -E apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qq -y install openssl
                sudo apt install -y sysbench libasan5 libaio1 libdbi-perl libdbd-mysql-perl unzip libevent-2.1-6 libevent-core-2.1-6
                #
                rm -rf percona-qa
                rm -rf ${TEST_DIR}
                rm -f *.tar.gz
                mkdir -p ${TEST_DIR}
                cd ${TEST_DIR}
                wget -q ${PS_BIN}
                wget -q ${PT_BIN}
                wget -q ${PXB_BIN}
                PS_TARBALL="$(tar -ztf binary.tar.gz|head -n1|sed 's:/$::').tar.gz"
                mv binary.tar.gz ${PS_TARBALL}
                cd -
                git clone https://github.com/Percona-QA/percona-qa.git --depth 1
                ${WORKSPACE}/percona-qa/ps-async-repl-test.sh --workdir=${WORKSPACE}/${TEST_DIR} --build-number=${BUILD_NUMBER} --testcase=${TEST_CASE} --storage-engine=innodb
                '''
              }
              catch (err) {
                error "Test failed please check results in the logs..."
              }
              finally {
                archiveArtifacts artifacts: "${TEST_DIR}/results-${BUILD_NUMBER}*.tar.gz", fingerprint: true
              }
            } //End script
          } //End steps
        } //End stage Test InnoDB
        stage('Test RocksDB') {
          agent {
            label "min-bionic-x64"
          }
          environment {
            TEST_DESCRIPTION="-rocksdb-${TEST_CASE}"
          }
          steps {
            script {
              try {
                sh '''
                # prepare
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
                sudo percona-release enable original
                sudo apt update
                UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive sudo -E apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qq -y install openssl
                sudo apt install -y sysbench libasan5 libaio1 libdbi-perl libdbd-mysql-perl unzip libevent-2.1-6 libevent-core-2.1-6
                #
                rm -rf percona-qa
                rm -rf ${TEST_DIR}
                rm -f *.tar.gz
                mkdir -p ${TEST_DIR}
                cd ${TEST_DIR}
                wget -q ${PS_BIN}
                wget -q ${PT_BIN}
                wget -q ${PXB_BIN}
                PS_TARBALL="$(tar -ztf binary.tar.gz|head -n1|sed 's:/$::').tar.gz"
                mv binary.tar.gz ${PS_TARBALL}
                cd -
                git clone https://github.com/Percona-QA/percona-qa.git --depth 1
                ${WORKSPACE}/percona-qa/ps-async-repl-test.sh --workdir=${WORKSPACE}/${TEST_DIR} --build-number=${BUILD_NUMBER} --testcase=${TEST_CASE} --storage-engine=rocksdb
                '''
              }
              catch (err) {
                error "Test failed please check results in the logs..."
              }
              finally {
                archiveArtifacts artifacts: "${TEST_DIR}/results-${BUILD_NUMBER}*.tar.gz", fingerprint: true
              }
            } //End script
          } //End steps
        } //End stage Test RocksDB
        stage('Test TokuDB') {
          agent {
            label "min-bionic-x64"
          }
          environment {
            TEST_DESCRIPTION="-tokudb-${TEST_CASE}"
          }
          steps {
            script {
              try {
                sh '''
                # prepare
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
                sudo percona-release enable original
                sudo apt update
                UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive sudo -E apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qq -y install openssl
                sudo apt install -y sysbench libasan5 libaio1 libdbi-perl libdbd-mysql-perl unzip libevent-2.1-6 libevent-core-2.1-6
                #
                rm -rf percona-qa
                rm -rf ${TEST_DIR}
                rm -f *.tar.gz
                mkdir -p ${TEST_DIR}
                cd ${TEST_DIR}
                wget -q ${PS_BIN}
                wget -q ${PT_BIN}
                wget -q ${PXB_BIN}
                PS_TARBALL="$(tar -ztf binary.tar.gz|head -n1|sed 's:/$::').tar.gz"
                mv binary.tar.gz ${PS_TARBALL}
                cd -
                git clone https://github.com/Percona-QA/percona-qa.git --depth 1
                ${WORKSPACE}/percona-qa/ps-async-repl-test.sh --workdir=${WORKSPACE}/${TEST_DIR} --build-number=${BUILD_NUMBER} --testcase=${TEST_CASE} --storage-engine=tokudb
                '''
              }
              catch (err) {
                error "Test failed please check results in the logs..."
              }
              finally {
                archiveArtifacts artifacts: "${TEST_DIR}/results-${BUILD_NUMBER}*.tar.gz", fingerprint: true
              }
            } //End script
          } //End steps
        } //End stage Test TokuDB
        stage('Test encryption with keyring file') {
          agent {
            label "min-bionic-x64"
          }
          environment {
            TEST_DESCRIPTION="-enc_keyring_file-${TEST_CASE}"
          }
          steps {
            script {
              try {
                sh '''
                # prepare
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
                sudo percona-release enable original
                sudo apt update
                UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive sudo -E apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qq -y install openssl
                sudo apt install -y sysbench libasan5 libaio1 libdbi-perl libdbd-mysql-perl unzip libevent-2.1-6 libevent-core-2.1-6
                #
                rm -rf percona-qa
                rm -rf ${TEST_DIR}
                rm -f *.tar.gz
                mkdir -p ${TEST_DIR}
                cd ${TEST_DIR}
                wget -q ${PS_BIN}
                wget -q ${PT_BIN}
                wget -q ${PXB_BIN}
                PS_TARBALL="$(tar -ztf binary.tar.gz|head -n1|sed 's:/$::').tar.gz"
                mv binary.tar.gz ${PS_TARBALL}
                cd -
                git clone https://github.com/Percona-QA/percona-qa.git --depth 1
                ${WORKSPACE}/percona-qa/ps-async-repl-test.sh --workdir=${WORKSPACE}/${TEST_DIR} --build-number=${BUILD_NUMBER} --testcase=${TEST_CASE} --with-encryption --keyring-plugin=file
                '''
              }
              catch (err) {
                error "Test failed please check results in the logs..."
              }
              finally {
                archiveArtifacts artifacts: "${TEST_DIR}/results-${BUILD_NUMBER}*.tar.gz", fingerprint: true
              }
            } //End script
          } //End steps
        } //End stage Test encryption with keyring file
        stage('Test encryption with keyring vault') {
          agent {
            label "min-bionic-x64"
          }
          environment {
            TEST_DESCRIPTION="-enc_keyring_vault-${TEST_CASE}"
          }
          steps {
            script {
              try {
                sh '''
                # prepare
                wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
                sudo dpkg -i percona-release_latest.generic_all.deb
                sudo percona-release enable original
                sudo apt update
                UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive sudo -E apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qq -y install openssl
                sudo apt install -y sysbench libasan5 libaio1 libdbi-perl libdbd-mysql-perl unzip libevent-2.1-6 libevent-core-2.1-6
                #
                rm -rf percona-qa
                rm -rf ${TEST_DIR}
                rm -f *.tar.gz
                mkdir -p ${TEST_DIR}
                cd ${TEST_DIR}
                wget -q ${PS_BIN}
                wget -q ${PT_BIN}
                wget -q ${PXB_BIN}
                PS_TARBALL="$(tar -ztf binary.tar.gz|head -n1|sed 's:/$::').tar.gz"
                mv binary.tar.gz ${PS_TARBALL}
                cd -
                git clone https://github.com/Percona-QA/percona-qa.git --depth 1
                ${WORKSPACE}/percona-qa/ps-async-repl-test.sh --workdir=${WORKSPACE}/${TEST_DIR} --build-number=${BUILD_NUMBER} --testcase=${TEST_CASE} --with-encryption --keyring-plugin=vault
                '''
              }
              catch (err) {
                error "Test failed please check results in the logs..."
              }
              finally {
                archiveArtifacts artifacts: "${TEST_DIR}/results-${BUILD_NUMBER}*.tar.gz", fingerprint: true
              }
            } //End script
          } //End steps
        } //End stage Test encryption with keyring vault
      } //End parallel
    } //End stage Run tests
  } //End stages
} //End pipeline
