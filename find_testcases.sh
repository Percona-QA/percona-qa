#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This quickly finds already partly simplified testcases (run from the root of your usual working directory - for example from /sda/)

find . | grep '_out$' | xargs wc -l
