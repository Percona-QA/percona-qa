#!/bin/bash 

grep --no-group-separator --binary-files=text -A1 '^3A) Add bug' *.report | grep -v '3A) Add bug' | sed 's|^[0-9]\+\.sql\.report-||' | sort -u > inprogress_known_bugs.strings
