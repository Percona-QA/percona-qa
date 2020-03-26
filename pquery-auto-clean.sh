# Use crontab to call this script. An example which can be modified and then used in /etc/crontab: (btw, note that cron is running by default on Centos 7)
#15 */1 * * * roel /home/roel/mariadb-qa/pquery-auto-clean.sh 235746 >> /sda/235746_pquery-auto-clean.out 2>&1
#30 */1 * * * roel /home/roel/mariadb-qa/pquery-auto-clean.sh 629181 >> /sda/629181_pquery-auto-clean.out 2>&1
#45 */1 * * * roel /home/roel/mariadb-qa/pquery-auto-clean.sh 663235 >> /sda/663235_pquery-auto-clean.out 2>&1
# The above would, every hour, at :15, :30 and :45 respectively, start a auto clean job for 3 various pquery-run.sh run directories (3 pquery-run.sh's running)
# Note that starting them all at the same time is twice a bad idea; 1) failures will occur as currently the pquery-prep-red.sh scripts expects it is the
# only one running, and it uses extract_query.gdb in mariadb-qa, which has a hard-coded filename being stored in /tmp (this can be improved later) and 2) since
# it would cause significant load at the time the jobs are executed, thereby maybe affecting existing pquery runs too negatively (reproducibility etc...)

# User variables
WORK_DIR="/sda" # The "master" location wherein the pquery-run.sh workdirs (6 number directories) are stored (/sda/814189/1996: /sda=WORK_DIR, /814189=PQUERY_DIR, i.e. the pquery-run.sh workdir, 1996=an individual trial directory, which is not used in this script)

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

if [ "" == "$1" ]; then
  echo "This script expects pquery rundir. eg ./pquery-auto-clean.sh 12345"
  exit 1
elif [ ! -d ${WORK_DIR}/$1 ]; then
  echo "Pquery run direcory (${WORK_DIR}/$1) not found!"
  exit 1
else
  PQUERY_DIR=$1
fi

# Download latest mariadb-qa revision
if [ -d ${SCRIPT_PWD} ]; then
  cd ${SCRIPT_PWD}
  git pull || true
else
  git clone https://github.com/Percona-QA/mariadb-qa.git
  cd ${SCRIPT_PWD}
fi

cd ${WORK_DIR}/${PQUERY_DIR}

# pquery-prep-red.sh needs 2x enter
echo -e "\n\n" | \
 ${SCRIPT_PWD}/pquery-prep-red.sh >> /${WORK_DIR}/${PQUERY_DIR}/pquery-red.log 2>&1
${SCRIPT_PWD}/pquery-results.sh >> /${WORK_DIR}/${PQUERY_DIR}/pquery-results.log 2>&1
${SCRIPT_PWD}/pquery-clean-known.sh >> /${WORK_DIR}/${PQUERY_DIR}/pquery-clean.log 2>&1

if [ -z $WORKSPACE ]; then
  echo "Assuming this is a local (i.e. non-Jenkins initiated) run."
else
  ASSERTION_COUNT=`grep "Seen[ \t1-9]\+times" ${WORKDIR}/${PQUERY_DIR}/pquery-results.log   | wc -l`
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/pquery_assertion.xml
  echo '<pquery>' >> $WORKSPACE/pquery_assertion.xml
  echo "  <ASSERTION_COUNT  type=\"result\">$ASSERTION_COUNT</ASSERTION_COUNT>"  >> $WORKSPACE/pquery_assertion.xml
  echo '</pquery>' >> $WORKSPACE/pquery_assertion.xml
  ## Permanent logging
  cp $WORKSPACE/pquery_assertion.xml $WORKSPACE/pquery_assertion_`date +"%F_%H%M"`.xml
fi

