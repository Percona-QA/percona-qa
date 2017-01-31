#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

grep -m1 BASEDIR [0-9]*/pquery-pquery-*.sh | sed 's| .*||;s|:BASEDIR=|\t\t|;s|/pquery-|\t\t|'
