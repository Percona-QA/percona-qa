#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Ideas
# - Keep it light and fast: 200 lines max.
# - Disable --views in runs, or at least make it very optional (seems to give lots of PERL errors on that)
# Power: many runs with many different grammars, so we somehow need to have this running
# Idea for options: a long file with all possible options (but turn all Percona options on maybe) and then grab a random set from that.
# Out of that, I still wonder if we should just use runall.pl or indeed cc files. Let's decide tomorrow
# Maybe we can copy in files while a master instance keeps running? FUN 
# No, the simple solution is just to let maxigen loop many times more and create heaps and heaps of yy file (1000 orso) :)

if [ "" == "$1" ]; then
  echo "This script is a very powerfull random grammar generator. It expects one parameter: the conf directory of randgen"
  echo "Example: $maxigen.sh '/randgen/conf'"
  exit 1
fi

SCRIPT_PWD=$(cd `dirname $0` && pwd)
RND_DIR=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')

mkdir /tmp/$RND_DIR

LOOP=0
echo "Stage 1: generating initial grammar files in: /tmp/$RND_DIR/"
for GRAMMAR in $(find $1 -maxdepth 2 -name '*.yy'); do 
  LOOP=$[$LOOP +1]
  SEED=$[$RANDOM % 10000]
  if [ $SEED -lt 25000 ]; then MASK=$[$RANDOM % 10]
  elif [ $SEED -lt 50000 ]; then MASK=$[$RANDOM % 100]
  elif [ $SEED -lt 75000 ]; then MASK=$[$RANDOM % 1000]
  else MASK=$[$RANDOM % 10000]
  fi
  MASK_L=$[$RANDOM % 2]
  $SCRIPT_PWD/maxigen.pl --grammar=$GRAMMAR --queries=200 --seed=$SEED --mask=$MASK --mask-level=$MASK_L \
  > /tmp/$RND_DIR/${LOOP}.yy 2>/dev/null
  echo -n "$LOOP..."
done
echo -e "\n"

LOOP=0
echo "Stage 2: looping through files and filtering faulty lines, failed grammars and unhandy Perl code"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  #egrep -v "^$|^[; \t]*$|Sentence is now longer|return undef|no strict|{|}" $GRAMMAR > ${GRAMMAR}.new
  # Maybe Perl is not so unhandy after all. Example:
  #  SELECT * FROM { if (scalar(@created_tables) > 0) { $prng->arrayElement(\@created_tables) } else { $prng->letter() } };
  # To be tested, may be ok for some, not ok for others
  egrep -v "^$|^[; \t]*$|Sentence is now longer" $GRAMMAR > ${GRAMMAR}.new
  rm ${GRAMMAR}
  mv ${GRAMMAR}.new ${GRAMMAR}
  echo -n "$LOOP..."
done
echo -e "\n"

LOOP=0
echo "Stage 3: Shuffle mix grammars"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  head -n10 $GRAMMAR >> /tmp/$RND_DIR/_1.yy
  for ((i=2;i<=20;i++)); do
    HEAD=$[$i * 10]
    head -n${HEAD} $GRAMMAR | tail -n10 >> /tmp/$RND_DIR/_${i}.yy
  done
  echo -n "$LOOP..."
done
echo -e "\n"

# Delete old grammars
rm /tmp/$RND_DIR/[0-9]*.yy

LOOP=0
echo "Stage 4: Setup grammars to be correctly formed"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  echo "query:" > /tmp/$RND_DIR/${LOOP}.yy
  cat $GRAMMAR | sed 's/;[ \t]*$/ |/' >> /tmp/$RND_DIR/${LOOP}.yy
  echo ";" >> /tmp/$RND_DIR/${LOOP}.yy
  echo -n "$LOOP..."
done
echo -e "\n"

# Delete old grammars
#rm /tmp/$RND_DIR/_[0-9]*.yy

#Setup scripts
       # NO short_column_names
       # Why not use a runall.pl on a server with all Percona options turned on
cp $1/percona_qa/percona_qa.sh /tmp/$RND_DIR/percona_qa.sh
cp $1/percona_qa/percona_qa.cc /tmp/$RND_DIR/percona_qa.cc

