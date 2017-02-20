FILE=main-ms-ps-md.sql
cat ${FILE} | grep -v "+d," >> ${FILE}2
cat ${FILE}2 | grep -vi "debug.*\-d," > ${FILE}3
cat ${FILE}3 | grep -vi "set.*debug.*=" > ${FILE}4
cat ${FILE}4 | grep -vi "rm -rf" > ${FILE}5
cat ${FILE}5 | grep -vi " mv " > ${FILE}6
rm ${FILE} ${FILE}2 ${FILE}3 ${FILE}4 ${FILE}5
mv ${FILE}6 ${FILE}
