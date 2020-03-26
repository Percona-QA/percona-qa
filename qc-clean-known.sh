~/mariadb-qa/alldiffs.sh | grep max_row_locks | grep -o "[0-9]\+::" | sed 's|::||' | sort -u | xargs -I{} ~/mariadb-qa/pquery-del-trial.sh {}
