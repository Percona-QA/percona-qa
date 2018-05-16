#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# ./lp-bug-add-file.py -b 1259034 -f test2 -d 'test2'

usage(){
  echo "Usage:"
  echo "This script uploads, for a given trial, all files in ./BUNDLE_<trialno>/* to a given Launchpad bug report. It expects two parameters;"
  echo "the trial number & the bug number. Example: to action trial 1000, and upload to bug report 1259034 use: $./lp-bug-logger.sh 1000 1259034"
  echo "Note: to generate a BUNDLE_<trialno> directory, use crash_bug_files.sh"
}

info(){
  echo "** Info"
  echo "   The first time you run this script, you will see something like this (after quite some time):"
  echo "   ---------------------------------------------------------------------------------------------------------"
  echo "   The authorization page:"
  echo "    (https://launchpad.net/+authorize-token?oauth_token=xxxxxxxxxxxxxx&allow_permission=DESKTOP_INTEGRATION)"
  echo "   should be opening in your browser. Use your browser to authorize this program to access LP on your behalf"
  echo "   Waiting to hear from Launchpad about your decision..."
  echo "   ---------------------------------------------------------------------------------------------------------"
  echo "   When you see this (and assuming you're working in a text-only ssh connection; otherwise a browser may"
  echo "   have already opened for you), copy and paste the URL shown into any browser and authorize the app (for"
  echo "   example, untill revoked) after logging into LP. This only has to be done once (if you chose an indefinite"
  echo "   /untill revoked authorization), and it can be done from any machine (provided you login to LP). If you"
  echo "   run into any issues, also review https://bugs.launchpad.net/launchpadlib/+bug/814595 if applicable. And,"
  echo -e "   authorized applications can be viewed/revoked at: https://launchpad.net/~<your_lp_user_id>/+oauth-tokens\n"
}

action_file(){
  if [ -r $(ls $GETFILE | head -n1) ]; then
    FILE=$(ls -1 $GETFILE | head -n1)
    if [ $(ls -1 $GETFILE | wc -l) -gt 1 ]; then
      echo "(!) Warning: there is more then one '$GETFILE' file. This is not normal. This script will use '$FILE' for uploading to the bug report ONLY ftm. Please check files and bug report for correctness"
    fi
    upload
  else
    echo "(!) Warning: '$GETFILE' file does not exist in '${BUNDLE_DIR}'. Note: this may be normal in some cases where limited issue info is available. Please doublecheck"
  fi
}

upload(){
  TIME=$(date +'%T')
  SIZE=$(stat -c %s $FILE)
  echo -ne "* Uploading since $TIME: $FILE ($DESC) [Size: $SIZE bytes]...\r"
  OUTCOME=$(${SCRIPT_PWD}/lp-bug-add-file.py -b $BUGNO -f $FILE -d "$DESC" 2>&1 | tail -n1 | sed 's/[ \t\r\n]*//')
  if [ "None" == "$OUTCOME" ]; then
    echo "* Uploading since $TIME: $FILE ($DESC) [Size: $SIZE bytes]... Success!"
  else
    echo "* Uploading since $TIME: $FILE ($DESC) [Size: $SIZE bytes]... ***Failed.***"
    echo "--> Reason: $OUTCOME"
    echo "--> Known issues: KeyError(<key>): this likely means you tried to upload to a non-existing bug. Verify bug number against <key>"
  fi
}

if [ "" == "$1" -o "" == "$2" ]; then
  usage
  exit 1
elif [ "" != "$(echo $1 | sed 's|[0-9]*||g')" -o "" != "$(echo $2 | sed 's|[0-9]*||g')" ]; then
  usage
  echo -e "\nError: trial number ($1) and bug number ($2) passed to script should be numeric only"
  exit 1
elif [ ! -d ./BUNDLE_$1 ]; then
  usage
  echo -e "\nError: ./BUNDLE_$1 not found. Did you forget to run crash_bug_files.sh ?"
  exit 1
else
  TRIAL=$1
  BUGNO=$2
fi

SCRIPT_PWD=$(cd `dirname $0` && pwd)
BUNDLE_DIR=./BUNDLE_$TRIAL
info

cd ${BUNDLE_DIR}
if [ "" == "$(pwd | grep 'BUNDLE_')" ]; then
  echo "(!) Assert: tried to create '${BUNDLE_DIR}' and changedir (cd) to it, but that failed"
  exit 1
fi

echo "** Uploading following files to Launchpad bug report $BUGNO for trial $TRIAL:"
GETFILE="gdb_${TRIAL}_*_STD.txt" ; DESC="Thread apply all bt"             ; action_file
GETFILE="gdb_${TRIAL}_*_FULL.txt"; DESC="Thread apply all bt FULL"        ; action_file
GETFILE="master_${TRIAL}_*.err"  ; DESC="Full error log"                  ; action_file
GETFILE="cmd${TRIAL}"            ; DESC="Command used"                    ; action_file
GETFILE="*.yy"                   ; DESC="Grammar used"                    ; action_file
GETFILE="versions.txt"           ; DESC="PS/RQG versions used"            ; action_file
GETFILE="trial${TRIAL}.log"      ; DESC="RQG trial log"                   ; action_file
GETFILE="core_${TRIAL}_*.tar.gz" ; DESC="Core file, mysqld, ldd dep files"; action_file
GETFILE="vardir1_${TRIAL}.tar.gz"; DESC="Vardir"                          ; action_file
echo "** All Done!"
