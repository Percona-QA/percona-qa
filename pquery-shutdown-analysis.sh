~/percona-qa/pquery-results.sh | grep "SHUTDOWN" | \
  sed 's|.*reducers ||;s|)||;s|,|\n|g' | \
  xargs -I{} grep --binary-files=text --color=always -m1 -B1 "gone away" {}/default.node.tld_thread-0.sql
