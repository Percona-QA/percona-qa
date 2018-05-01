date | awk '{print $2" "$3}' | sed 's|\([a-z]\) \([0-9]\)$|\1  \2|' | xargs -I{} sh -c 'ls -ld [0-9]* | grep "{}"'
