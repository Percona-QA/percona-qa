cat *pquery-results* | sed 's|[ \t]*(Seen.*$||' | grep -v "=====" | sort -u
