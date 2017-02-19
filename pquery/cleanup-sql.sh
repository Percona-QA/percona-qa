cat main-ms-ps-md.sql | grep -v "+d," >> main-ms-ps-md.sql2
cat main-ms-ps-md.sql2 | grep -vi "debug.*\-d," > main-ms-ps-md.sql3
cat main-ms-ps-md.sql3 | grep -vi "set.*debug.*=" > main-ms-ps-md.sql4
cat main-ms-ps-md.sql4 | grep -vi "rm -rf" > main-ms-ps-md.sql5
cat main-ms-ps-md.sql5 | grep -vi " mv " > main-ms-ps-md.sql6
