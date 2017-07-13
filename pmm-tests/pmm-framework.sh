#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Additions by Roel Van de Paar, Percona LLC

# PMM Framework
# This script enables one to quickly setup a Percona Monitoring and Management environment. One can setup a PMM server and qucikyl add multiple clients
# The intention of this script is to be robust from a quality assurance POV; it should handle many different server configurations accurately

# Internal variables
WORKDIR=${PWD}
SCRIPT_PWD=$(cd `dirname $0` && pwd)
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SERVER_START_TIMEOUT=100
SUSER="root"
SPASS=""
OUSER="admin"
OPASS="passw0rd"
ADDR="127.0.0.1"
download_link=0

# User configurable variables
IS_BATS_RUN=0

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --setup                          This will setup and configure a PMM server"
    echo " --addclient=ps,2                 Add Percona (ps), MySQL (ms), MariaDB (md), Percona XtraDB Cluster (pxc), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)"
    echo "                                  You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2 --addclient=pxc,3"
    echo " --download                       This will help us to download pmm client binary tar balls"
    echo " --ps-version                     Pass Percona Server version info"
    echo " --ms-version                     Pass MySQL Server version info"
    echo " --md-version                     Pass MariaDB Server version info"
    echo " --pxc-version                    Pass Percona XtraDB Cluster version info"
    echo " --mo-version                     Pass MongoDB Server version info"
    echo " --mongo-with-rocksdb             This will start mongodb with rocksdb engine"
	echo " --replcount                      You can configure multiple mongodb replica sets with this oprion"
	echo " --with-replica                   This will configure mongodb replica setup"
	echo " --with-shrading                  This will configure mongodb shrading setup"
    echo " --add-docker-client              Add docker pmm-clients with percona server to the currently live PMM server"
    echo " --list                           List all client information as obtained from pmm-admin"
    echo " --wipe-clients                   This will stop all client instances and remove all clients from pmm-admin"
    echo " --wipe-docker-clients            This will stop all docker client instances and remove all clients from docker container"
    echo " --wipe-server                    This will stop pmm-server container and remove all pmm containers"
    echo " --wipe                           This will wipe all pmm configuration"
    echo " --dev                            When this option is specified, PMM framework will use the latest PMM development version. Otherwise, the latest 1.0.x version is used"
    echo " --pmm-server-username            User name to access the PMM Server web interface"
    echo " --pmm-server-password            Password to access the PMM Server web interface"
	echo " --pmm-server=[docker|ami|ova]    Choose PMM server appliance, default pmm server appliance is docker"
	echo " --ami-image                      Pass PMM server ami image name"
    echo " --key-name                       Pass your aws access key file name"
	echo " --ova-image                      Pass PMM server ova image name"

}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=u: --longoptions=addclient:,replcount:,pmm-server:,ami-image:,key-name:,ova-image:,pmm-server-username:,pmm-server-password::,setup,with-replica,with-shrading,download,ps-version:,ms-version:,md-version:,pxc-version:,mo-version:,mongo-with-rocksdb,add-docker-client,list,wipe-clients,wipe-docker-clients,wipe-server,wipe,dev,with-proxysql,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    --addclient )
    ADDCLIENT+=("$2")
    shift 2
    ;;
    --with-replica )
    shift
    with_replica=1
    ;;
	--replcount )
	REPLCOUNT=$2
	shift 2
    ;;
    --with-shrading )
    shift
    with_shrading=1
    ;;
    --download )
    shift
    download_link=1
    ;;
    --pmm-server )
    pmm_server="$2"
	shift 2
    if [ "$pmm_server" != "docker" ] && [ "$pmm_server" != "ami" ] && [ "$pmm_server" != "ova" ]; then
      echo "ERROR: Invalid --pmm-server passed:"
      echo "  Please choose any of these pmm-server options: 'docker', 'ami', or ova"
      exit 1
    fi
    ;;
	--ami-image )
    ami_image="$2"
    shift 2
    ;;
	--key-name )
    key_name="$2"
    shift 2
    ;;
	--ova-image )
    ova_image="$2"
    shift 2
    ;;
    --ps-version )
    ps_version="$2"
    shift 2
    ;;
    --ms-version )
    ms_version="$2"
    shift 2
    ;;
    --md-version )
    md_version="$2"
    shift 2
    ;;
    --pxc-version )
    pxc_version="$2"
    shift 2
    ;;
    --mo-version )
    mo_version="$2"
    shift 2
    ;;
    --mongo-storage-engine )
    shift
    mongo_storage_engine="--storageEngine  $2"
    ;;
    --add-docker-client )
    shift
    add_docker_client=1
    ;;
    --setup )
    shift
    setup=1
    ;;
    --list )
    shift
    list=1
    ;;
    --wipe-clients )
    shift
    wipe_clients=1
    ;;
    --wipe-docker-clients )
    shift
    wipe_docker_clients=1
    ;;
    --wipe-server )
    shift
    wipe_server=1
    ;;
    --wipe )
    shift
    wipe=1
    ;;
    --dev )
    shift
    dev=1
    ;;
    --with-proxysql )
    shift
    with_proxysql=1
    ;;
    --pmm-server-username )
    pmm_server_username="$2"
    shift 2
    ;;
    --pmm-server-password )
    case "$2" in
      "")
      read -r -s -p  "Enter PMM Server web interface password:" INPUT_PASS
      if [ -z "$INPUT_PASS" ]; then
        pmm_server_password=""
        printf "\nConfiguring without PMM Server web interface password...\n";
      else
        pmm_server_password="$INPUT_PASS"
      fi
      printf "\n"
      ;;
      *)
      pmm_server_password="$2"
      ;;
    esac
    shift 2
    ;;
    --help )
    usage
    exit 0
    ;;
  esac
done

if [[ "$with_shrading" == "1" ]];then
  with_replica=1
fi
if [[ -z "$pmm_server_username" ]];then
  if [[ ! -z "$pmm_server_password" ]];then
    echo "ERROR! PMM Server web interface username is empty. Terminating"
    exit 1
  fi
fi

if [[ -z "$pmm_server" ]];then
  pmm_server="docker"
elif [[ "$pmm_server" == "ami" ]];then
  if [[ "$setup" == "1" ]];then
    if [[ -z "$ami_image" ]];then
      echo "ERROR! You have not given AMI image name. Please use --ami-image to pass image name. Terminating"
      exit 1
    fi
    if [[ -z "$key_name" ]];then
      echo "ERROR! You have not entered  aws key name. Please use --key-name to pass key name. Terminating"
      exit 1
    fi
  fi
elif [[ "$pmm_server" == "ova" ]];then
  if [[ "$setup" == "1" ]];then
    if [[ -z "$ova_image" ]];then
      echo "ERROR! You have not given OVA image name. Please use --ova-image to pass image name. Terminating"
      exit 1
    fi
  fi
fi
sanity_check(){
  if [[ "$pmm_server" == "docker" ]];then
    if ! sudo docker ps | grep 'pmm-server' > /dev/null ; then
      echo "ERROR! pmm-server docker container is not runnning. Terminating"
      exit 1
    fi
  elif [[ "$pmm_server" == "ami" ]];then
    if [ -f $WORKDIR/aws_instance_config.txt ]; then
      INSTANCE_ID=$(cat $WORKDIR/aws_instance_config.txt | grep "InstanceId"  | awk -F[\"\"] '{print $4}')
	else
	  echo "ERROR! Could not read aws instance id. $WORKDIR/aws_instance_config.txt does not exist. Terminating"
	  exit 1
	fi
    INSTANCE_ACTIVE=$(aws ec2 describe-instance-status --instance-ids  $INSTANCE_ID | grep "Code" | sed 's/[^0-9]//g')
	if [[ "$INSTANCE_ACTIVE" != "16" ]];then
      echo "ERROR! pmm-server ami instance is not runnning. Terminating"
      exit 1
	fi
  elif [[ "$pmm_server" == "ova" ]];then
    VMBOX=$(vboxmanage list runningvms | grep "PMM-Server" | awk -F[\"\"] '{print $2}')
	VMBOX_STATUS=$(vboxmanage showvminfo $VMBOX  | grep State | awk '{print $2}')
	if [[ "$VMBOX_STATUS" != "running" ]]; then
	  echo "ERROR! pmm-server ova instance is not runnning. Terminating"
      exit 1
	fi
  fi
}

if [[ -z "${ps_version}" ]]; then ps_version="5.7"; fi
if [[ -z "${pxc_version}" ]]; then pxc_version="5.7"; fi
if [[ -z "${ms_version}" ]]; then ms_version="5.7"; fi
if [[ -z "${md_version}" ]]; then md_version="10.1"; fi
if [[ -z "${mo_version}" ]]; then mo_version="3.4"; fi
if [[ -z "${REPLCOUNT}" ]]; then REPLCOUNT="1"; fi

setup(){
  if [ $IS_BATS_RUN -eq 0 ];then
    read -p "Would you like to enable SSL encryption to protect PMM from unauthorized access[y/n] ? " check_param
    case $check_param in
      y|Y)
        echo -e "\nGenerating SSL certificate files to protect PMM from unauthorized access"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt -subj '/CN=www.percona.com/O=Database Performance./C=US'
         IS_SSL="Yes"
      ;;
      n|N)
        echo ""
        IS_SSL="No"
      ;;
      *)
        echo "Please type [y/n]! Terminating."
        exit 1
      ;;
    esac
  else
    IS_SSL="No"
  fi

  if [[ ! -e $(which lynx 2> /dev/null) ]] ;then
    echo "ERROR! The program 'lynx' is currently not installed. Please install lynx. Terminating"
    exit 1
  fi
  IP_ADDRESS=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
  if [[ "$pmm_server" == "docker" ]];then
    #PMM configuration setup
    if [ -z $dev ]; then
      PMM_VERSION=$(lynx --dump https://hub.docker.com/r/percona/pmm-server/tags/ | grep '[0-9].[0-9].[0-9]' | sed 's|   ||' | head -n1)
    else
      PMM_VERSION=$(lynx --dump https://hub.docker.com/r/perconalab/pmm-server/tags/ | grep '[0-9].[0-9].[0-9]' | sed 's|   ||' | head -n1)
    fi
    #PMM sanity check
	aws ec2 describe-instance-status --instance-ids  $INSTANCE_ID | grep "Code" | sed 's/[^0-9]//g'
    if ! pgrep docker > /dev/null ; then
      echo "ERROR! docker service is not running. Terminating"
      exit 1
    fi
    if sudo docker ps | grep 'pmm-server' > /dev/null ; then
      echo "ERROR! pmm-server docker container is already runnning. Terminating"
      exit 1
    elif  sudo docker ps -a | grep 'pmm-server' > /dev/null ; then
      CONTAINER_NAME=$(sudo docker ps -a | grep 'pmm-server' | grep $PMM_VERSION | grep -v pmm-data | awk '{ print $1}')
      echo "ERROR! The name 'pmm-server' is already in use by container $CONTAINER_NAME"
      exit 1
    fi

    echo "Initiating PMM configuration"
    if [ -z $dev ]; then
      sudo docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" --name pmm-data percona/pmm-server:$PMM_VERSION /bin/true 2>/dev/null
    else
      sudo docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" --name pmm-data perconalab/pmm-server:$PMM_VERSION /bin/true 2>/dev/null
    fi
    if [ -z $dev ]; then
      if [ "$IS_SSL" == "Yes" ];then
        sudo docker run -d -p 443:443 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server -v $WORKDIR:/etc/nginx/ssl  --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null
      else
       sudo docker run -d -p 80:80 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null
      fi
    else
      if [ "$IS_SSL" == "Yes" ];then
       sudo docker run -d -p 443:443 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server -v $WORKDIR:/etc/nginx/ssl  --restart always perconalab/pmm-server:$PMM_VERSION 2>/dev/null
      else
       sudo docker run -d -p 80:80 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server --restart always perconalab/pmm-server:$PMM_VERSION 2>/dev/null
      fi
    fi
  elif [[ "$pmm_server" == "ami" ]] ; then
    if [[ ! -e $(which aws 2> /dev/null) ]] ;then
      echo "ERROR! AWS client program is currently not installed. Please install awscli. Terminating"
      exit 1
    fi
    if [ ! -f $HOME/.aws/credentials ]; then
      echo "ERROR! AWS access key is not configured. Terminating"
	  exit 1
	fi
	aws ec2 run-instances \
	--image-id $ami_image \
	--security-group-ids sg-3b6e5e46 \
	--instance-type t2.micro \
    --subnet-id subnet-4765a930 \
    --region us-east-1 \
    --key-name $key_name > $WORKDIR/aws_instance_config.txt 2> /dev/null

	INSTANCE_ID=$(cat $WORKDIR/aws_instance_config.txt | grep "InstanceId"  | awk -F[\"\"] '{print $4}')

	aws ec2 create-tags  \
    --resources $INSTANCE_ID \
    --region us-east-1 \
    --tags Key=Name,Value=PMM_test_image 2> /dev/null

	sleep 30

	AWS_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids  $INSTANCE_ID | grep "PublicIpAddress" | awk -F[\"\"] '{print $4}')
  elif [[ "$pmm_server" == "ova" ]] ; then
    if [[ ! -e $(which VBoxManage 2> /dev/null) ]] ;then
      echo "ERROR! VBoxManage client program is currently not installed. Please install VirtualBox. Terminating"
      exit 1
    fi
	ova_image_name=$(echo $ova_image | sed 's/.ova//')
    VMBOX=$(vboxmanage list runningvms | grep $ova_image_name | awk -F[\"\"] '{print $2}')
	VMBOX_STATUS=$(vboxmanage showvminfo $VMBOX  | grep State | awk '{print $2}')
	if [[ "$VMBOX_STATUS" == "running" ]]; then
	  echo "ERROR! pmm-server ova instance is already runnning. Terminating"
      exit 1
	fi
	# import image
	if [ ! -f $ova_image ] ;then
	  echo "Alert! ${ova_image} does not exist in $WORKDIR. Downloading ${ova_image} ..."
	  wget https://s3.amazonaws.com/percona-vm/$ova_image
	fi
    VBoxManage import $ova_image > $WORKDIR/ova_instance_config.txt 2> /dev/null
	NETWORK_INTERFACE=$(ip addr | grep $IP_ADDRESS |  awk 'NF>1{print $NF}')
	VBoxManage modifyvm $ova_image_name --nic1 bridged --bridgeadapter1 ${NETWORK_INTERFACE}
	VBoxManage modifyvm $ova_image_name --uart1 0x3F8 4 --uartmode1 file $WORKDIR/pmm-server-console.log
    # start instance
    VBoxManage startvm --type headless $ova_image_name > $WORKDIR/pmm-server-starup.log 2> /dev/null
	sleep 120
	OVA_PUBLIC_IP=$(grep 'Percona Monitoring and Management' $WORKDIR/pmm-server-console.log | awk -F[\/\/] '{print $3}')
  fi
  #PMM configuration setup
  PMM_VERSION=$(lynx --dump https://hub.docker.com/r/percona/pmm-server/tags/ | grep '[0-9].[0-9].[0-9]' | sed 's|   ||' | head -n1)

  echo "Initiating PMM client configuration"
  PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
  if [ -z $PMM_CLIENT_BASEDIR ]; then
    PMM_CLIENT_TAR=$(ls -1td pmm-client-* | grep ".tar" | head -n1)
    if [ ! -z $PMM_CLIENT_TAR ];then
      tar -xzf $PMM_CLIENT_TAR
      PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
      pushd $PMM_CLIENT_BASEDIR > /dev/null
      sudo ./install
      popd > /dev/null
    else
      if [ ! -z $dev ]; then
        PMM_CLIENT_TAR=$(lynx --dump https://www.percona.com/downloads/TESTING/pmm/ | grep -o pmm-client.*.tar.gz   | head -n1)
        wget https://www.percona.com/downloads/TESTING/pmm/$PMM_CLIENT_TAR
        tar -xzf $PMM_CLIENT_TAR
        PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
        pushd $PMM_CLIENT_BASEDIR > /dev/null
        sudo ./install
        popd > /dev/null
      else
        PMM_CLIENT_TAR=$(lynx --dump  https://www.percona.com/downloads/pmm-client/pmm-client-$PMM_VERSION/binary/tarball | grep -o pmm-client.*.tar.gz | head -n1)
        wget https://www.percona.com/downloads/pmm-client/pmm-client-$PMM_VERSION/binary/tarball/$PMM_CLIENT_TAR
        tar -xzf $PMM_CLIENT_TAR
        PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
        pushd $PMM_CLIENT_BASEDIR > /dev/null
        sudo ./install
        popd > /dev/null
      fi
    fi
  else
    pushd $PMM_CLIENT_BASEDIR > /dev/null
    sudo ./install
    popd > /dev/null
  fi
  if [ "$IS_SSL" == "Yes" ];then
    PMM_MYEXTRA="--server-insecure-ssl"
  else
    PMM_MYEXTRA=""
  fi
  if [[ ! -e $(which pmm-admin 2> /dev/null) ]] ;then
    echo "ERROR! The pmm-admin client binary was not found, please install the pmm-admin client package"
    exit 1
  else
    sleep 10
	#Cleaning existing PMM server configuration.
	sudo truncate -s0 /usr/local/percona/pmm-client/pmm.yml
    if [[ "$pmm_server" == "ami" ]]; then
	  sudo pmm-admin config --server $AWS_PUBLIC_IP --client-address $IP_ADDRESS $PMM_MYEXTRA
	  echo "Alert! Password protection is not enabled in ami image, Please configure it manually"
	  SERVER_IP=$AWS_PUBLIC_IP
    elif [[ "$pmm_server" == "ova" ]]; then
	  sudo pmm-admin config --server $OVA_PUBLIC_IP --client-address $IP_ADDRESS $PMM_MYEXTRA
	  echo "Alert! Password protection is not enabled in ova image, Please configure it manually"
	  SERVER_IP=$OVA_PUBLIC_IP
    else
      sudo pmm-admin config --server $IP_ADDRESS --server-user="$pmm_server_username" --server-password="$pmm_server_password" $PMM_MYEXTRA
	  SERVER_IP=$IP_ADDRESS
    fi
  fi
  echo -e "******************************************************************"
  if [[ "$pmm_server" == "docker" ]]; then
    echo -e "Please execute below command to access docker container"
    echo -e "docker exec -it pmm-server bash\n"
  fi
  if [ "$IS_SSL" == "Yes" ];then
    (
    printf "%s\t%s\n" "PMM landing page" "https://$SERVER_IP:443"
    if [ ! -z $pmm_server_username ];then
      printf "%s\t%s\n" "PMM landing page username" "$pmm_server_username"
    fi
    if [ ! -z $pmm_server_password ];then
      printf "%s\t%s\n" "PMM landing page password" "$pmm_server_password"
    fi
    printf "%s\t%s\n" "Query Analytics (QAN web app)" "https://$SERVER_IP:443/qan"
    printf "%s\t%s\n" "Metrics Monitor (Grafana)" "https://$SERVER_IP:443/graph"
    printf "%s\t%s\n" "Metrics Monitor username" "admin"
    printf "%s\t%s\n" "Metrics Monitor password" "admin"
    printf "%s\t%s\n" "Orchestrator" "https://$SERVER_IP:443/orchestrator"
    ) | column -t -s $'\t'
  else
    (
    printf "%s\t%s\n" "PMM landing page" "http://$SERVER_IP"
    if [ ! -z $pmm_server_username ];then
      printf "%s\t%s\n" "PMM landing page username" "$pmm_server_username"
    fi
    if [ ! -z $pmm_server_password ];then
      printf "%s\t%s\n" "PMM landing page password" "$pmm_server_password"
    fi
    printf "%s\t%s\n" "Query Analytics (QAN web app)" "http://$SERVER_IP/qan"
    printf "%s\t%s\n" "Metrics Monitor (Grafana)" "http://$SERVER_IP/graph"
    printf "%s\t%s\n" "Metrics Monitor username" "admin"
    printf "%s\t%s\n" "Metrics Monitor password" "admin"
    printf "%s\t%s\n" "Orchestrator" "http://$SERVER_IP/orchestrator"
    ) | column -t -s $'\t'
  fi
  echo -e "******************************************************************"
}

#Get PMM client basedir.
get_basedir(){
  PRODUCT_NAME=$1
  SERVER_STRING=$2
  CLIENT_MSG=$3
  VERSION=$4
  if cat /etc/os-release | grep rhel >/dev/null ; then
   DISTRUBUTION=centos
  fi
  if [ $download_link -eq 1 ]; then
    if [ -f $SCRIPT_PWD/../get_download_link.sh ]; then
      LINK=`$SCRIPT_PWD/../get_download_link.sh --product=${PRODUCT_NAME} --distribution=$DISTRUBUTION --version=$VERSION`
      echo "Downloading $CLIENT_MSG(Version : $VERSION)"
      wget $LINK 2>/dev/null
      BASEDIR=$(ls -1td $SERVER_STRING 2>/dev/null | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td $SERVER_STRING 2>/dev/null | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td $SERVER_STRING 2>/dev/null | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          rm -rf $BASEDIR/node*
        else
          echo "ERROR! $CLIENT_MSG(this script looked for '$SERVER_STRING') does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    else
      echo "ERROR! $SCRIPT_PWD/../get_download_link.sh does not exist. Terminating."
      exit 1
    fi
  else
    BASEDIR=$(ls -1td $SERVER_STRING 2>/dev/null | grep -v ".tar" | head -n1)
    if [ -z $BASEDIR ]; then
      BASE_TAR=$(ls -1td $SERVER_STRING 2>/dev/null | grep ".tar" | head -n1)
      if [ ! -z $BASE_TAR ];then
        tar -xzf $BASE_TAR
        BASEDIR=$(ls -1td $SERVER_STRING 2>/dev/null | grep -v ".tar" | head -n1)
        BASEDIR="$WORKDIR/$BASEDIR"
        if [[ "${CLIENT_NAME}" == "mo" ]]; then
          sudo rm -rf $BASEDIR/data
        else
          rm -rf $BASEDIR/node*
        fi
      else
        echo "ERROR! $CLIENT_MSG(this script looked for '$SERVER_STRING') does not exist. Terminating."
        exit 1
      fi
    else
      BASEDIR="$WORKDIR/$BASEDIR"
    fi
  fi
}

#Percona Server configuration.
add_clients(){
  mkdir -p $WORKDIR/logs
  for i in ${ADDCLIENT[@]};do
    CLIENT_NAME=$(echo $i | grep -o  '[[:alpha:]]*')
    if [[ "${CLIENT_NAME}" == "ps" ]]; then
      PORT_CHECK=101
      NODE_NAME="PS_NODE"
      get_basedir ps "[Pp]ercona-[Ss]erver-${ps_version}*" "Percona Server binary tar ball" ${ps_version}
      MYSQL_CONFIG="--log_output=file --slow_query_log=ON --long_query_time=0 --log_slow_rate_limit=100 --log_slow_rate_type=query --log_slow_verbosity=full --log_slow_admin_statements=ON --log_slow_slave_statements=ON --slow_query_log_always_write_time=1 --slow_query_log_use_global_control=all --innodb_monitor_enable=all --userstat=1"
    elif [[ "${CLIENT_NAME}" == "ms" ]]; then
      PORT_CHECK=201
      NODE_NAME="MS_NODE"
      get_basedir mysql "mysql-${ms_version}*" "MySQL Server binary tar ball" ${ms_version}
      MYSQL_CONFIG="--innodb_monitor_enable=all --performance_schema=ON"
    elif [[ "${CLIENT_NAME}" == "md" ]]; then
      PORT_CHECK=301
      NODE_NAME="MD_NODE"
      get_basedir mariadb "mariadb-${md_version}*" "MariaDB Server binary tar ball" ${md_version}
      MYSQL_CONFIG="--innodb_monitor_enable=all --performance_schema=ON"
    elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
      echo "[mysqld]" > my_pxc.cnf
      echo "innodb_autoinc_lock_mode=2" >> my_pxc.cnf
      echo "innodb_locks_unsafe_for_binlog=1" >> my_pxc.cnf
      echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> my_pxc.cnf
      echo "wsrep_node_incoming_address=$ADDR" >> my_pxc.cnf
      echo "wsrep_sst_method=rsync" >> my_pxc.cnf
      echo "wsrep_sst_auth=$SUSER:$SPASS" >> my_pxc.cnf
      echo "wsrep_node_address=$ADDR" >> my_pxc.cnf
      echo "server-id=1" >> my_pxc.cnf
      echo "wsrep_slave_threads=2" >> my_pxc.cnf
      PORT_CHECK=401
      NODE_NAME="PXC_NODE"
      get_basedir pxc "Percona-XtraDB-Cluster-${pxc_version}*" "Percona XtraDB Cluster binary tar ball" ${pxc_version}
      MYSQL_CONFIG="--log_output=file --slow_query_log=ON --long_query_time=0 --log_slow_rate_limit=100 --log_slow_rate_type=query --log_slow_verbosity=full --log_slow_admin_statements=ON --log_slow_slave_statements=ON --slow_query_log_always_write_time=1 --slow_query_log_use_global_control=all --innodb_monitor_enable=all --userstat=1"
    elif [[ "${CLIENT_NAME}" == "mo" ]]; then
      get_basedir psmdb "percona-server-mongodb-${mo_version}*" "Percona Server Mongodb binary tar ball" ${mo_version}
    fi
    if [[ "${CLIENT_NAME}" != "md"  && "${CLIENT_NAME}" != "mo" ]]; then
      if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
        MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
      else
        MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
      fi
    else
      if [[ "${CLIENT_NAME}" != "mo" ]]; then
        MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
      fi
    fi

    ADDCLIENTS_COUNT=$(echo "${i}" | sed 's|[^0-9]||g')
    if  [[ "${CLIENT_NAME}" == "mo" ]]; then
      rm -rf $BASEDIR/data
	  for k in `seq 1  ${REPLCOUNT}`;do
		PSMDB_PORT=$(( (RANDOM%21 + 10) * 1001 ))
		PSMDB_PORTS+=($PSMDB_PORT)
        for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
          PORT=$(( $PSMDB_PORT + $j - 1 ))
          mkdir -p ${BASEDIR}/data/rpldb${k}_${j}
          $BASEDIR/bin/mongod $mongo_storage_engine  --replSet r${k} --dbpath=$BASEDIR/data/rpldb${k}_${j} --logpath=$BASEDIR/data/rpldb${k}_${j}/mongod.log --port=$PORT --logappend --fork &
		  sleep 10
          sudo pmm-admin add mongodb --cluster mongodb_cluster  --uri localhost:$PORT mongodb_inst_rpl${k}_${j}
        done
      done
	  create_replset_js(){
	    REPLSET_COUNT=$(( ${ADDCLIENTS_COUNT} - 1 ))
	    rm -rf /tmp/config_replset.js
		echo "port=parseInt(db.adminCommand(\"getCmdLineOpts\").parsed.net.port)" >> /tmp/config_replset.js
		for i in `seq 1  ${REPLSET_COUNT}`;do
          echo "port${i}=port+${i};" >> /tmp/config_replset.js
		done
        echo "conf = {" >> /tmp/config_replset.js
        echo "_id : replSet," >> /tmp/config_replset.js
        echo "members: [" >> /tmp/config_replset.js
        echo "  { _id:0 , host:\"localhost:\"+port,priority:10}," >> /tmp/config_replset.js
		for i in `seq 1  ${REPLSET_COUNT}`;do
          echo "  { _id:${i} , host:\"localhost:\"+port${i}}," >> /tmp/config_replset.js
        done
        echo "  ]" >> /tmp/config_replset.js
        echo "};" >> /tmp/config_replset.js

        echo "printjson(conf)" >> /tmp/config_replset.js
        echo "printjson(rs.initiate(conf));" >> /tmp/config_replset.js

	  }
	  create_replset_js
      if [[ "$with_replica" == "1" ]]; then
        for k in `seq 1  ${REPLCOUNT}`;do
	      n=$(( $k - 1 ))
		  echo "Configuring replcaset"
          sudo $BASEDIR/bin/mongo --quiet --port ${PSMDB_PORTS[$n]} --eval "var replSet='r${k}'" "/tmp/config_replset.js"
          sleep 5
	    done
	  fi

      if [[ "$with_shrading" == "1" ]]; then
    	#config
	    CONFIG_MONGOD_PORT=$(( (RANDOM%21 + 10) * 1001 ))
		CONFIG_MONGOS_PORT=$(( (RANDOM%21 + 10) * 1001 ))
		for m in `seq 1 ${ADDCLIENTS_COUNT}`;do
		  PORT=$(( $CONFIG_MONGOD_PORT + $m - 1 ))
		  mkdir -p $BASEDIR/data/confdb${m}
          $BASEDIR/bin/mongod --fork --logpath $BASEDIR/data/confdb${m}/config_mongo.log --dbpath=$BASEDIR/data/confdb${m} --port $PORT --configsvr --replSet config &
		  sleep 10
		  sudo pmm-admin add mongodb --cluster mongodb_cluster  --uri localhost:$PORT mongodb_inst_config_rpl${m}
		  MONGOS_STARTUP_CMD="localhost:$PORT,$MONGOS_STARTUP_CMD"
		done

		echo "Configuring replcaset"
        $BASEDIR/bin/mongo --quiet --port ${CONFIG_MONGOD_PORT} --eval "var replSet='config'" "/tmp/config_replset.js"
        sleep 20

		MONGOS_STARTUP_CMD="${MONGOS_STARTUP_CMD::-1}"
		mkdir $BASEDIR/data/mongos
		#Removing default mongodb socket file
		sudo rm -rf /tmp/mongodb-27017.sock
		$BASEDIR/bin/mongos --fork --logpath $BASEDIR/data/mongos/mongos.log --configdb config/$MONGOS_STARTUP_CMD  &
		sleep 5
        sudo pmm-admin add mongodb --cluster mongodb_cluster --uri localhost:$CONFIG_MONGOD_PORT mongod_config_inst
	    sudo pmm-admin add mongodb --cluster mongodb_cluster --uri localhost:$CONFIG_MONGOS_PORT mongos_config_inst
        echo "Adding Shards"
		sleep 20
        for k in `seq 1  ${REPLCOUNT}`;do
          n=$(( $k - 1 ))
          $BASEDIR/bin/mongo --quiet --eval "printjson(db.getSisterDB('admin').runCommand({addShard: 'r${k}/localhost:${PSMDB_PORTS[$n]}'}))"
        done
	  fi
    else
      for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
        RBASE1="$(( RBASE + ( $PORT_CHECK * $j ) ))"
        LADDR1="$ADDR:$(( RBASE1 + 8 ))"
        node="${BASEDIR}/node$j"
        if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
          echo "WARNING! Another mysqld process using /tmp/${NODE_NAME}_${j}.sock"
          if ! sudo pmm-admin list | grep "/tmp/${NODE_NAME}_${j}.sock" > /dev/null ; then
            sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=/tmp/${NODE_NAME}_${j}.sock --user=root --query-source=perfschema
          fi
          continue
        fi
        if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
          mkdir -p $node
          ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
        else
          if [ ! -d $node ]; then
            ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
          fi
        fi
        if  [[ "${CLIENT_NAME}" == "pxc" ]]; then
          WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
          if [ $j -eq 1 ]; then
            WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
          else
            WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
          fi
          MYEXTRA="--no-defaults --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so $WSREP_CLUSTER_ADD --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 --wsrep_sst_method=rsync --wsrep_sst_auth=root: --max-connections=30000"
        else
          MYEXTRA="--no-defaults --max-connections=30000"
        fi
        ${BASEDIR}/bin/mysqld $MYEXTRA $MYSQL_CONFIG --basedir=${BASEDIR} --datadir=$node --log-error=$node/error.err \
          --socket=/tmp/${NODE_NAME}_${j}.sock --port=$RBASE1  > $node/error.err 2>&1 &
        function startup_chk(){
          for X in $(seq 0 ${SERVER_START_TIMEOUT}); do
            sleep 1
            if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
              check_user=`${BASEDIR}/bin/mysql  -uroot -S/tmp/${NODE_NAME}_${j}.sock -e "SELECT user,host FROM mysql.user where user='$OUSER' and host='%';"`
              if [[ -z "$check_user" ]]; then
                ${BASEDIR}/bin/mysql  -uroot -S/tmp/${NODE_NAME}_${j}.sock -e "CREATE USER '$OUSER'@'%' IDENTIFIED BY '$OPASS';GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO '$OUSER'@'%'"
                (
                printf "%s\t%s\n" "Orchestrator username :" "admin"
                printf "%s\t%s\n" "Orchestrator password :" "passw0rd"
                ) | column -t -s $'\t'
              else
                echo "User '$OUSER' is already present in MySQL server. Please create Orchestrator user manually."
              fi
              break
            fi
          done
        }
        startup_chk
        if ! ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
          if grep -q "TCP/IP port: Address already in use" $node/error.err; then
            echo "TCP/IP port: Address already in use, restarting ${NODE_NAME}_${j} mysqld daemon with different port"
            RBASE1="$(( RBASE1 - 1 ))"
            ${BASEDIR}/bin/mysqld $MYEXTRA --basedir=${BASEDIR} --datadir=$node --log-error=$node/error.err \
               --socket=/tmp/${NODE_NAME}_${j}.sock --port=$RBASE1  > $node/error.err 2>&1 &
            startup_chk
            if ! ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
              echo "ERROR! ${NODE_NAME} startup failed. Please check error log $node/error.err"
              exit 1
            fi
          else
            echo "ERROR! ${NODE_NAME} startup failed. Please check error log $node/error.err"
            exit 1
          fi
        fi
        sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=/tmp/${NODE_NAME}_${j}.sock --user=root --query-source=perfschema
      done
      pxc_proxysql_setup(){
        if  [[ "${CLIENT_NAME}" == "pxc" ]]; then
          if [[ ! -e $(which proxysql 2> /dev/null) ]] ;then
            echo "The program 'proxysql' is currently not installed. Installing proxysql from percona repository"
            if grep -iq "ubuntu"  /etc/os-release ; then
              sudo apt install -y proxysql
            fi
            if grep -iq "centos"  /etc/os-release ; then
              sudo yum install -y proxysql
            fi
            if [[ ! -e $(which proxysql 2> /dev/null) ]] ;then
              echo "ERROR! Could not install proxysql on CentOS/Ubuntu machine. Terminating"
              exit 1
            fi
          fi
          PXC_SOCKET=$(sudo pmm-admin list | grep "mysql:metrics[ \t]*PXC_NODE-1" | awk -F[\(\)] '{print $2}')
          PXC_BASE_PORT=$(${BASEDIR}/bin/mysql -uroot --socket=$PXC_SOCKET -Bse"select @@port")
          ${BASEDIR}/bin/mysql -uroot --socket=$PXC_SOCKET -e"grant all on *.* to admin@'%' identified by 'admin'"
          sudo sed -i "s/3306/${PXC_BASE_PORT}/" /etc/proxysql-admin.cnf
          sudo proxysql-admin -e > $WORKDIR/logs/proxysql-admin.log
          sudo pmm-admin add proxysql:metrics
        else
          echo "Could not find PXC nodes. Skipping proxysql setup"
        fi
      }
    fi
  done
}

pmm_docker_client_startup(){
  centos_docker_client(){
    rm -rf Dockerfile docker-compose.yml
    echo "FROM centos:centos6" >> Dockerfile
    echo "RUN yum install -y http://www.percona.com/downloads/percona-release/redhat/0.1-4/percona-release-0.1-4.noarch.rpm" >> Dockerfile
    echo "RUN yum install -y yum install Percona-Server-server-57 pmm-client" >> Dockerfile
    echo "RUN echo \"UNINSTALL PLUGIN validate_password;\" > init.sql " >> Dockerfile
    echo "RUN echo \"ALTER USER  root@localhost IDENTIFIED BY '';\" >> init.sql " >> Dockerfile
    echo "RUN echo \"CREATE USER root@'%';\" >> init.sql " >> Dockerfile
    echo "RUN echo \"GRANT ALL ON *.* TO root@'%';\" >> init.sql" >> Dockerfile
    echo "RUN service mysql start" >> Dockerfile
    echo "EXPOSE 3306 42000 42002 42003 42004" >> Dockerfile
    echo "centos_ps:" >> docker-compose.yml
    echo "   build: ." >> docker-compose.yml
    echo "   hostname: centos_ps1" >> docker-compose.yml
    echo "   command: sh -c \"mysqld --init-file=/init.sql --user=root\"" >> docker-compose.yml
    echo "   ports:" >> docker-compose.yml
    echo "      - \"3306\"" >> docker-compose.yml
    echo "      - \"42000\"" >> docker-compose.yml
    echo "      - \"42002\"" >> docker-compose.yml
    echo "      - \"42003\"" >> docker-compose.yml
    echo "      - \"42004\"" >> docker-compose.yml
    docker-compose up >/dev/null 2>&1 &
    BASE_DIR=$(basename "$PWD")
    BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
    while ! docker ps | grep ${BASE_DIR}_centos_ps_1 > /dev/null; do
      sleep 5 ;
    done
    DOCKER_CONTAINER_NAME=$(docker ps | grep ${BASE_DIR}_centos_ps | awk '{print $NF}')
    IP_ADD=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
    if [ ! -z $DOCKER_CONTAINER_NAME ]; then
      echo -e "\nAdding pmm-client instance from CentOS docker container to the currently live PMM server"
      IP_DOCKER_ADD=$(docker exec -it $DOCKER_CONTAINER_NAME ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin config --server $IP_ADD --bind-address $IP_DOCKER_ADD
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin add mysql
    fi
  }

  ubuntu_docker_client(){
    rm -rf Dockerfile docker-compose.yml
    echo "FROM ubuntu:16.04" >> Dockerfile
    echo "RUN apt-get update" >> Dockerfile
    echo "RUN apt-get install -y wget lsb-release net-tools vim iproute" >> Dockerfile
    echo "RUN wget http://repo.percona.com/apt/percona-release_0.1-4.\$(lsb_release -sc)_all.deb" >> Dockerfile
    echo "RUN dpkg -i percona-release_0.1-4.\$(lsb_release -sc)_all.deb" >> Dockerfile
    echo "RUN apt-get update" >> Dockerfile
    echo "RUN apt-get install -y percona-server-server-5.7 pmm-client" >> Dockerfile
    echo "RUN echo \"CREATE USER root@'%';\" > init.sql " >> Dockerfile
    echo "RUN echo \"GRANT ALL ON *.* TO root@'%';\" >> init.sql" >> Dockerfile
    echo "RUN service mysql start" >> Dockerfile
    echo "EXPOSE 3306 42000 42002 42003 42004" >> Dockerfile
    echo "ubuntu_ps:" >> docker-compose.yml
    echo "   build: ." >> docker-compose.yml
    echo "   hostname: ubuntu_ps1" >> docker-compose.yml
    echo "   command: sh -c \"mysqld --init-file=/init.sql\"" >> docker-compose.yml
    echo "   ports:" >> docker-compose.yml
    echo "      - 3306:3306" >> docker-compose.yml
    echo "      - 42000:42000" >> docker-compose.yml
    echo "      - 42002:42002" >> docker-compose.yml
    echo "      - 42003:42003" >> docker-compose.yml
    echo "      - 42004:42004" >> docker-compose.yml
    docker-compose up >/dev/null 2>&1 &
    BASE_DIR=$(basename "$PWD")
    BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
    while ! docker ps | grep ${BASE_DIR}_ubuntu_ps_1 > /dev/null; do
      sleep 5 ;
    done
    DOCKER_CONTAINER_NAME=$(docker ps | grep ${BASE_DIR}_ubuntu_ps | awk '{print $NF}')
    IP_ADD=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
    if [ ! -z $DOCKER_CONTAINER_NAME ]; then
      echo -e "\nAdding pmm-client instance from Ubuntu docker container to the currently live PMM server"
      IP_DOCKER_ADD=$(docker exec -it $DOCKER_CONTAINER_NAME ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin config --server $IP_ADD --bind-address $IP_DOCKER_ADD
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin add mysql
    fi
  }

  centos_docker_client
  ubuntu_docker_client
}
clean_clients(){
  if [[ ! -e $(which mysqladmin 2> /dev/null) ]] ;then
    MYSQLADMIN_CLIENT=$(find . -name mysqladmin | head -n1)
  else
    MYSQLADMIN_CLIENT=$(which mysqladmin)
  fi
  if [[ -z "$MYSQLADMIN_CLIENT" ]];then
   echo "ERROR! 'mysqladmin' is currently not installed. Please install mysqladmin. Terminating."
   exit 1
  fi
  #Shutdown all mysql client instances
  for i in $(sudo pmm-admin list | grep "mysql:metrics[ \t].*_NODE" | awk -F[\(\)] '{print $2}'  | sort -r) ; do
    echo -e "Shutting down mysql instance (--socket=${i})"
    ${MYSQLADMIN_CLIENT} -uroot --socket=${i} shutdown
    sleep 2
  done
  #Kills mongodb processes
  sudo killall mongod 2> /dev/null
  sudo killall mongos 2> /dev/null
  sleep 5
  if sudo pmm-admin list | grep -q 'No services under monitoring' ; then
    echo -e "No services under pmm monitoring"
  else
    #Remove all client instances
    echo -e "Removing all local pmm client instances"
    sudo pmm-admin remove --all 2&>/dev/null
  fi
}

clean_docker_clients(){
  #Remove docker pmm-clients
  BASE_DIR=$(basename "$PWD")
  BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
  echo -e "Removing pmm-client instances from docker containers"
  sudo docker exec -it ${BASE_DIR}_centos_ps_1  pmm-admin remove --all 2&> /dev/null
  sudo docker exec -it ${BASE_DIR}_ubuntu_ps_1  pmm-admin remove --all  2&> /dev/null
  echo -e "Removing pmm-client docker containers"
  sudo docker stop ${BASE_DIR}_ubuntu_ps_1 ${BASE_DIR}_centos_ps_1  2&> /dev/null
  sudo docker rm ${BASE_DIR}_ubuntu_ps_1 ${BASE_DIR}_centos_ps_1  2&> /dev/null
}

clean_server(){
  #Stop/Remove pmm-server docker/ami/ova instances
  if [[ "$pmm_server" == "docker" ]] ; then
    echo -e "Removing pmm-server docker containers"
    sudo docker stop pmm-server  2&> /dev/null
    sudo docker rm pmm-server pmm-data  2&> /dev/null
  elif [[ "$pmm_server" == "ova" ]] ; then
	VMBOX=$(vboxmanage list runningvms | grep "PMM-Server" | awk -F[\"\"] '{print $2}')
	echo "Shutting down ova instance"
	VBoxManage controlvm $VMBOX poweroff
	echo "Unregistering ova instance"
	VBoxManage unregistervm $VMBOX --delete
	 VM_DISKS=($(vboxmanage list hdds | grep -B4 $VMBOX | grep UUID | grep -v 'Parent UUID:' | awk '{ print $2}'))
	for i in ${VM_DISKS[@]}; do
	  VBoxManage closemedium disk $i --delete ;
	done
  elif [[ "$pmm_server" == "ami" ]] ; then
    if [ -f $WORKDIR/aws_instance_config.txt ]; then
      INSTANCE_ID=$(cat $WORKDIR/aws_instance_config.txt | grep "InstanceId"  | awk -F[\"\"] '{print $4}')
	else
	  echo "ERROR! Could not read aws instance id. $WORKDIR/aws_instance_config.txt does not exist. Terminating"
	  exit 1
	fi
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID > $WORKDIR/aws_remove_instance.log
  fi

}

if [ ! -z $wipe_clients ]; then
  clean_clients
fi

if [ ! -z $wipe_docker_clients ]; then
  clean_docker_clients
fi

if [ ! -z $wipe_server ]; then
  clean_server
fi

if [ ! -z $wipe ]; then
  clean_clients
  clean_docker_clients
  clean_server
fi

if [ ! -z $list ]; then
  sudo pmm-admin list
fi

if [ ! -z $setup ]; then
  setup
fi

if [ ${#ADDCLIENT[@]} -ne 0 ]; then
  sanity_check
  add_clients
fi

if [ ! -z $with_proxysql ]; then
  pxc_proxysql_setup
fi

if [ ! -z $add_docker_client ]; then
  sanity_check
  pmm_docker_client_startup
fi

exit 0
