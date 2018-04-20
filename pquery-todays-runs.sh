date | awk '{print $2" "$3}' | xargs -I{} sh -c 'ls -ld [0-9]* | grep "{}"'
