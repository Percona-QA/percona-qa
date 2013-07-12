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

SCRIPT_PWD=$(cd `dirname $0` && pwd)

if [ -d /randgen/conf ]; then RQG_DIR="/randgen/conf"
elif [ -d /ssd/randgen/conf ]; then RQG_DIR="/ssd/randgen/conf"
elif [ -d /ssd/qa/randgen/conf ]; then RQG_DIR="/ssd/qa/randgen/conf"
elif [ -d ../../conf ]; then RQG_DIR="../../conf"
elif [ "" == "$1" ]; then
  echo "This script is a very powerfull random grammar generator. It expects one parameter: the conf directory of randgen"
  echo "Note: this script already auto-searches several directories for randgen existence (for example in /randgen/conf)"
  echo "Example: $maxigen.sh '/randgen/conf'"
  exit 1
else 
  RQG_DIR=$1
fi

RND_DIR=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
NR_OF_GRAMMARS=200
LINES_PER_GRAM=20     # The number of queries (rules) to extract from each sub-grammar created from the existing RQG grammars by maxigen.pl
QUERIES=$[$NR_OF_GRAMMARS * $LINES_PER_GRAM]

mkdir /tmp/$RND_DIR

LOOP=0
for GRAMMAR in $(find $RQG_DIR -maxdepth 2 -name '*.yy'); do 
  LOOP=$[$LOOP +1]
done

FIN_GRAM_SIZE=$[$LINES_PER_GRAM * $LOOP]
echo "------------------------------------------------------------------------------"
echo "| Welcome to MaxiGen v0.20 - A Powerfull RQG Grammar Generator"
echo "------------------------------------------------------------------------------"
echo "| Number of original RQG grammars in $RQG_DIR: $LOOP"
echo "| Number of new random grammars requested: $NR_OF_GRAMMARS"
echo "| Number of lines taken from each original RQG grammar: $LINES_PER_GRAM"
echo "| So, we will generate $QUERIES rules per original RQG grammar,"
echo "| resulting in approx $FIN_GRAM_SIZE rules per generated new random grammar"
echo "------------------------------------------------------------------------------"

LOOP=0
echo "Stage 1: generating initial grammar files in: /tmp/$RND_DIR/"
for GRAMMAR in $(find $RQG_DIR -maxdepth 2 -name '*.yy'); do 
  LOOP=$[$LOOP +1]
  SEED=$[$RANDOM % 10000]
  if [ $SEED -lt 25000 ]; then MASK=$[$RANDOM % 10]
  elif [ $SEED -lt 50000 ]; then MASK=$[$RANDOM % 100]
  elif [ $SEED -lt 75000 ]; then MASK=$[$RANDOM % 1000]
  else MASK=$[$RANDOM % 10000]
  fi
  MASK_L=$[$RANDOM % 2]
  $SCRIPT_PWD/maxigen.pl --grammar=$GRAMMAR --queries=$QUERIES --seed=$SEED --mask=$MASK --mask-level=$MASK_L \
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
  egrep -v "^$|^[; \t]*$|SET SESSION debug|SET GLOBAL debug|Sentence is now longer" $GRAMMAR > ${GRAMMAR}.new
  rm ${GRAMMAR}
  mv ${GRAMMAR}.new ${GRAMMAR}
  echo -n "$LOOP..."
done
echo -e "\n"

LOOP=0
echo "Stage 3: Shuffle mix all queries generated from existing RQG grammars into $NR_OF_GRAMMARS new grammars"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  for ((i=1;i<=$NR_OF_GRAMMARS;i++)); do
    TOP=$[ $i * $LINES_PER_GRAM - $LINES_PER_GRAM + 1]
    END=$[ $i * $LINES_PER_GRAM ]
    sed -n "${TOP},${END}p" $GRAMMAR >> /tmp/$RND_DIR/_${i}.yy
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
rm /tmp/$RND_DIR/_[0-9]*.yy

#Setup scripts
sed "s|COMBINATIONS|/tmp/$RND_DIR/maxigen.cc|" ./maxirun.sh > /tmp/$RND_DIR/maxirun.sh
chmod +x /tmp/$RND_DIR/maxirun.sh
grep -v "GRAMMAR-GENDATA-DUMMY-TAG" ./maxigen.cc > /tmp/$RND_DIR/maxigen.cc

# Use random gendata's to augment new random yy grammars
for GENDATA in $(find $RQG_DIR -maxdepth 2 -name '*.zz'); do
  echo "   --gendata=$GENDATA'," >> /tmp/$RND_DIR/GENDATA.txt
done

# Insert new random yy grammars into cc template
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  echo "  '--grammar=$GRAMMAR" >> /tmp/$RND_DIR/maxigen.cc
  sort -uR /tmp/$RND_DIR/GENDATA.txt | head -n1 >> /tmp/$RND_DIR/maxigen.cc
done
  
echo -e " ]\n]" >> /tmp/$RND_DIR/maxigen.cc

# Finalize
echo "MaxiGen Done! Generated $NR_OF_GRAMMARS grammar files in: /tmp/$RND_DIR/"
echo -e "\nOnly thing left to do;"
echo "cd /tmp/$RND_DIR/; vi maxigen.cc"
echo " > Change 'PERCONA-DBG-SERVER' and 'PERCONA-VAL-SERVER' to normal debug/valgrind server location path names,"
echo "   for example; use /ssd/Percona-Server-5.6.11-rc60.3-383-debug.Linux.x86_64 instead of PERCONA-DBG-SERVER"
echo "./maxirun.sh"
