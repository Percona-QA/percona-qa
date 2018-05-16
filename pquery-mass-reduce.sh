#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script starts x (first option) new reducers based on the pquery-results.sh output (one reducer per issue seen - using the first failing trail for that issue)

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

if [ "$1" == "" ]; then
  echo "Assert: This script expects one option, namely how many reducers to start on pquery-results.sh output."
  echo "Additionally one can pass a second option to 'skip' a number of results. For example, ./pquery-mass-reduce.sh 10 5 will start to reduce items 6-16 of the pquery-results.sh output."
  echo "Note that it is likely not wise to start more then 10-15 reducers, unless you are using a very high-end server."
  echo "That last note is applicable when pquery-go-expert.sh was used. If not, then likely much less (2-4) reducers should be started, or they need to be monitored more closely. For the reason why, please see the extensive help text near the top of the pquery-go-expert.sh script"
  echo "Terminating."
  exit 1
elif [ "$(echo $1 | sed 's|^[0-9]\+||')" != "" ]; then
  echo "Assert: option passed is not numeric. If you do not know how to use this script, execute it without options to see more information"
  exit 1
fi

if [ "$2" == "" ]; then
  SKIP=0
elif [ "$(echo $2 | sed 's|^[0-9]\+||')" != "" ]; then
  echo "Assert: an option passed is not numeric. If you do not know how to use this script, execute it without options to see more information"
  exit 1
else
  SKIP=$2
fi
TOTAL=$[ $1 + $SKIP ]

RND=${RANDOM}
# For each issue, take the first trial number and sent it to a file
${SCRIPT_PWD}/pquery-results.sh | grep -o "reducers.*" | sed 's|reducers ||;s|[,)]\+.*||' > /tmp/${RND}.txt
# Now put the issues into an issue array
mapfile -t issues < /tmp/${RND}.txt; rm -f /tmp/${RND}.txt 2>/dev/null
# Check for existing reducers started in a similar way, to continue s<nr> name count (allows easy reconnect with `screen -d -r s<nr>`
COUNTER_LIVE=$(screen -d -r | sed 's|\t|=|g' | grep -o "\.s[0-9]\+=" | sed 's|[^0-9]||g' | sort -unr | head -n1)
# Now loop though the issues. When the counter reaches the amount passed to this scirpt, the loop will terminate
COUNTER=0
for TRIAL in "${issues[@]}"; do
  COUNTER=$[ $COUNTER + 1 ]
  COUNTER_LIVE=$[ $COUNTER_LIVE + 1 ]
  if [ $COUNTER -gt $SKIP ]; then
    screen -admS s${COUNTER_LIVE} bash -c "ulimit -u 4000;./reducer${TRIAL}.sh;bash"  # Start reducer, and when done give a usable bash prompt
    sleep 0.3  # Avoid a /dev/shm/<epoch> directory conflict (yes, it happened)
    echo "Started screen with name 's${COUNTER_LIVE}' and started ./reducer${TRIAL}.sh within it for issue: $(grep "   TEXT=" reducer${TRIAL}.sh | sed 's|   TEXT="||;s|"$||')"
  fi
  if [ $COUNTER -eq $TOTAL ]; then break; fi
done
echo "Done! started $[ $COUNTER - $SKIP ] screen sessions named s$[ ${SKIP} + 1 ]-${COUNTER}. To reconnect to any of them, use:  $ screen -d -r s<nr>  where <nr> matches the number listed above!"
