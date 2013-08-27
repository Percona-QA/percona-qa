#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Ideas
# - Keep it light and fast: 200 lines max?
# - Be very avoisive of '--views' as this generates plenty of errors
# - Many grammars contain things like 'col_int_nokey' which is not present unless default (i.e. no) data grammar is used?
#   - Maybe we can do some runs without a data grammar, or another option is to s|col_int_nokey|_field| etc. may also
#     consider changing _field_indexed to _field since the former fails (in combination with --views, allowing better --view runs)

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
NR_OF_GRAMMARS=300
LINES_PER_GRAM=7     # The number of queries (rules) to extract from each sub-grammar created from the existing RQG grammars by maxigen.pl
QUERIES=$[$NR_OF_GRAMMARS * $LINES_PER_GRAM]

mkdir /tmp/$RND_DIR

LOOP=0
for GRAMMAR in $(find $RQG_DIR -maxdepth 2 -name '*.yy'); do 
  LOOP=$[$LOOP +1]
done
ORIG_GRAMMARS=$LOOP

FIN_GRAM_SIZE=$[$LINES_PER_GRAM * $LOOP]
echo "----------------------------------------------------------------------------------------"
echo "| Welcome to MaxiGen v0.41 - A Powerfull RQG Random Grammar Generator"
echo "----------------------------------------------------------------------------------------"
echo "| IMPORTANT: by default a Percona-Server-only compatible cc file is used (maxigen.cc)"
echo "| If you would like to use the MySQL-Server compatible cc file maxigenMS.cc (and thus"
echo "| avoid a failed RQG run, due to all trials ending in STATUS_ENVIRONMENT_FAILURE), then"
echo "| please rename maxigenMS.cc to maxigen.cc, to let maxigen.sh use this file instead!"
echo "----------------------------------------------------------------------------------------"
echo "| Number of original RQG grammars in $RQG_DIR: $LOOP"
echo "| Number of new random grammars requested: $NR_OF_GRAMMARS"
echo "| Number of lines taken from each original RQG grammar: $LINES_PER_GRAM"
echo "| So, we will generate $QUERIES rules per original RQG grammar,"
echo "| resulting in approx $FIN_GRAM_SIZE rules per generated new random grammar"
echo "----------------------------------------------------------------------------------------"

LOOP=0
echo -e "\nStage 1 ($ORIG_GRAMMARS): Generating initial grammar files in: /tmp/$RND_DIR/"
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

LOOP=0
echo -e "\n\nStage 2 ($ORIG_GRAMMARS): Looping through files; filtering faulty lines, grammar failures, and unhandy Perl code"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  #egrep -v "^$|^[; \t]*$|Sentence is now longer|return undef|no strict|{|}" $GRAMMAR > ${GRAMMAR}.new
  # Maybe Perl is not so unhandy after all. Example:
  #  SELECT * FROM { if (scalar(@created_tables) > 0) { $prng->arrayElement(\@created_tables) } else { $prng->letter() } };
  # To be tested, may be ok for some, not ok for others. Example: filtering " table1 " as queries with this string create all trials to fail.
  egrep -v "^$|^[; \t]*$|SET SESSION debug|SET GLOBAL debug| table1 |Sentence is now longer" $GRAMMAR > ${GRAMMAR}.new
  rm ${GRAMMAR}
  mv ${GRAMMAR}.new ${GRAMMAR}
  echo -n "$LOOP..."
done

LOOP=0
echo -e "\n\nStage 3 ($ORIG_GRAMMARS): Random sort all lines in each file"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  while read i; do echo "`printf '%05d' $RANDOM`$i"; done < ${GRAMMAR} | sort | sed 's/^.\{5\}//' > ${GRAMMAR}.new
  rm ${GRAMMAR}
  mv ${GRAMMAR}.new ${GRAMMAR}
  echo -n "$LOOP..."
done

LOOP=0
echo -e "\n\nStage 4 ($ORIG_GRAMMARS): Shuffle mix all queries generated from existing RQG grammars into $NR_OF_GRAMMARS new grammars"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  for ((i=1;i<=$NR_OF_GRAMMARS;i++)); do
    TOP=$[ $i * $LINES_PER_GRAM - $LINES_PER_GRAM + 1]
    END=$[ $i * $LINES_PER_GRAM ]
    # This sed will *not* duplicate end-of-file lines if there aren't sufficient lines; output will simply be blank when addressing past EOF
    sed -n "${TOP},${END}p" $GRAMMAR >> /tmp/$RND_DIR/_${i}.yy
  done
  echo -n "$LOOP..."
done

# Delete old grammars
rm /tmp/$RND_DIR/[0-9]*.yy

LOOP=0
echo -e "\n\nStage 5 ($NR_OF_GRAMMARS): Setup grammars to be correctly formed"
for GRAMMAR in $(find /tmp/$RND_DIR/ -name '*.yy'); do
  LOOP=$[$LOOP +1]
  echo "query:" > /tmp/$RND_DIR/${LOOP}.yy
  cat $GRAMMAR | sed 's/;[ \t]*$/ |/' >> /tmp/$RND_DIR/${LOOP}.yy
  echo "SELECT 1 ;" >> /tmp/$RND_DIR/${LOOP}.yy
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
  INT_GD_RAND=$[$RANDOM % 5]
  if [ $INT_GD_RAND -lt 1 ]; then # Use built-in gendata (-lt 1 = ~20% of runs)
    echo "   '," >> /tmp/$RND_DIR/maxigen.cc
  else
    sort -uR /tmp/$RND_DIR/GENDATA.txt | head -n1 >> /tmp/$RND_DIR/maxigen.cc
  fi
done
echo -e " ]\n]" >> /tmp/$RND_DIR/maxigen.cc
rm /tmp/$RND_DIR/GENDATA.txt

# Finalize
echo "MaxiGen Done! Generated $NR_OF_GRAMMARS grammar files in: /tmp/$RND_DIR/"

# Check if we can assume Percona-Server being present in /ssd, and replace DUMMY strings if so
if [ $(ls -1d /ssd/Percona-Server*-debug* | grep -v '.tar.gz' | wc -l) -eq 2 ]; then 
  mv /tmp/$RND_DIR/maxigen.cc /tmp/$RND_DIR/maxigen.cc.tmp
  DEBUG=$(ls -1d /ssd/Percona-Server*-debug.Linux* | grep -v 'tar.gz')
  VALGR=$(ls -1d /ssd/Percona-Server*-debug-valgrind* | grep -v 'tar.gz')
  sed "s|PERCONA-DBG-SERVER|$DEBUG|" /tmp/$RND_DIR/maxigen.cc.tmp | \
    sed "s|PERCONA-VAL-SERVER|$VALGR|" > /tmp/$RND_DIR/maxigen.cc
  rm /tmp/$RND_DIR/maxigen.cc.tmp
  echo "=====> To start: cd /tmp/$RND_DIR/; ./maxirun.sh <====="
  echo "(As there were only 2x Percona Debug Server dirs in /ssd - the cc file already contains the correct run diretories)"
  echo "(Debug   : $DEBUG)"
  echo "(Valgrind: $VALGR)"
else 
  echo -e "\nOnly thing left to do;"
  echo "=====> cd /tmp/$RND_DIR/; vi maxirun.sh; vi maxigen.cc <====="
  echo " > Change the WORKDIR variable (default: /ssd) in maxirun.sh to the location you prefer as workdir"
  echo " > Change 'PERCONA-DBG-SERVER' and 'PERCONA-VAL-SERVER' to normal debug/valgrind server location path names, for example use"
  echo "   /ssd/Percona-Server-5.6.11-rc60.3-383-debug.Linux.x86_64 instead of PERCONA-DBG-SERVER. Make these changes in maxigen.cc"
  echo "====> ./maxirun.sh <====="
fi

