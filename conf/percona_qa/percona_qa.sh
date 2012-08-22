# User settings
WORKDIR=/ssd
RQG_DIR=/randgen

# Internal settings
MTR_BT=$[$RANDOM % 300 + 1]
RAND=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')

# Check if random directory already exists & start run if not
if [ -d $WORKDIR/$RAND ]; then
  echo "Directory already exists. Retry.";
else
  mkdir $WORKDIR/$RAND
  cd $RQG_DIR
  MTR_BUILD_THREAD=$MTR_BT; perl ./combinations.pl \
  --parallel=8 \
  --run-all-combinations-once \
  --force \
  --workdir=$WORKDIR/$RAND \
  --config=$RQG_DIR/conf/percona_qa/percona_qa.cc
fi
