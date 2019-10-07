#!/bin/bash
LOG_LOC=$1
cd ${LOG_LOC}
if [ -z ${BIG_DIR} ]; then
  export BIG_DIR=${PWD}
fi
RS_ARRAY=($(ls *perf_result_set.txt))
echo " <html>"  >  ${BIG_DIR}/multibench_perf_result.html 
echo "   <head>"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "     <script type="text/javascript""  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "           src=\"https://www.google.com/jsapi?autoload={"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "             'modules':[{"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "               'name':'visualization',"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "               'version':'1',"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "               'packages':['corechart']"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "             }]"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "           }\"></script>"  >>  ${BIG_DIR}/multibench_perf_result.html 

i=0
for file in "${RS_ARRAY[@]}"; do
  count=$((i++));
  BENCH_TYPE=`echo $file | cut -d _ -f 1`
  BENCHMARCK=`echo $file | cut -d _ -f 2`
  if [ $BENCH_TYPE == "iibench" ]; then
    echo "     <script type=\"text/javascript\">"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "       google.load(\"visualization\", \"1\", {packages:[\"corechart\"]});" >>${BIG_DIR}/multibench_perf_result.html
    echo "       google.setOnLoadCallback(drawChart$count);"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "       function drawChart$count() {"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "         var data = google.visualization.arrayToDataTable(["  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "           ['Build',  '20M' , '40M' , '60M ' , '80M' , '100M' , 'Avg IPS' ]," >> ${BIG_DIR}/multibench_perf_result.html
  else
    echo "     <script type=\"text/javascript\">"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "       google.setOnLoadCallback(drawChart$count);"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "       function drawChart$count() {"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "         var data = google.visualization.arrayToDataTable(["  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "           ['Build', 'Thread_1' , 'Thread_4' , 'Thread_16' , 'Thread_64' , 'Thread_128' , 'Thread_256' , 'Thread_512' , 'Thread_1024']," >> ${BIG_DIR}/multibench_perf_result.html 
    #echo "           ['Build', 'Thread_1' , 'Thread_4' ]," >> ${BIG_DIR}/multibench_perf_result.html
  fi
  tail -10 $file  >>  ${BIG_DIR}/multibench_perf_result.html 
  echo "         ]);"  >>  ${BIG_DIR}/multibench_perf_result.html 
  echo "         var options = {"  >>  ${BIG_DIR}/multibench_perf_result.html
  if [ $BENCH_TYPE == "fbpileup" ]; then
    FBPILEUP_TYPE=`echo $file | cut -d _ -f 2`
    echo "           title: '$BENCH_TYPE $FBPILEUP_TYPE performance result',"  >>  ${BIG_DIR}/multibench_perf_result.html
  else
    echo "           title: '$BENCH_TYPE ${BENCHMARCK} performance result',"  >>  ${BIG_DIR}/multibench_perf_result.html 
  fi
  echo "           hAxis: {title: \"BUILD\"},"  >>  ${BIG_DIR}/multibench_perf_result.html
  
  if [ $BENCH_TYPE == "iibench" ]; then
    echo "           vAxis: {title: \"IPS\"},"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "           seriesType: \"bars\","  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "           series: {5: {type: \"line\"}}"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "         };"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "         var chart = new google.visualization.ComboChart(document.getElementById('curve_chart$count'));"  >>  ${BIG_DIR}/multibench_perf_result.html
  else
    echo "           vAxis: {title: \"AVG QPS\"},"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "           curveType: 'function'"  >>  ${BIG_DIR}/multibench_perf_result.html 
    echo "         };"  >>  ${BIG_DIR}/multibench_perf_result.html
    echo "         var chart = new google.visualization.LineChart(document.getElementById('curve_chart$count'));"  >>  ${BIG_DIR}/multibench_perf_result.html
  fi
 
  echo "         chart.draw(data, options);"  >>  ${BIG_DIR}/multibench_perf_result.html 
  echo "       }"  >>  ${BIG_DIR}/multibench_perf_result.html
  echo "     </script>"  >>  ${BIG_DIR}/multibench_perf_result.html 
done
echo "   </head>"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo "   <body>"  >>  ${BIG_DIR}/multibench_perf_result.html
echo "   <table>" >>  ${BIG_DIR}/multibench_perf_result.html
echo "   <tr>" >>  ${BIG_DIR}/multibench_perf_result.html
cat $BIG_DIR/hw.info >> ${BIG_DIR}/multibench_perf_result.html
tail -10 $BIG_DIR/build_info.log | xargs -IX printf '<br>%s\n' X >> ${BIG_DIR}/multibench_perf_result.html
echo "   </tr>" >>  ${BIG_DIR}/multibench_perf_result.html
i=0
for file in "${RS_ARRAY[@]}"; do 
  count=$((i++));
  [ $((count%2)) -eq 0 ] && echo "<tr>"  >>  ${BIG_DIR}/multibench_perf_result.html
  echo "<td>     <div id=\"curve_chart$count\" style=\"width: 700px; height: 500px\"></div></td>"  >>  ${BIG_DIR}/multibench_perf_result.html 
  [ $((count%2)) -ne 0 ] && echo "</tr>"  >>  ${BIG_DIR}/multibench_perf_result.html
done
[ $((count%2)) -eq 0 ] && echo "</tr>"  >>  ${BIG_DIR}/multibench_perf_result.html
echo "   </table>" >>  ${BIG_DIR}/multibench_perf_result.html
echo "   </body>"  >>  ${BIG_DIR}/multibench_perf_result.html 
echo " </html>"  >>  ${BIG_DIR}/multibench_perf_result.html 

