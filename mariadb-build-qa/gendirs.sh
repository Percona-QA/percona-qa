#!/bin/bash
# Created by Roel Van de Paar, MariaDB

ls -d MD*10.[1-5]* 2>/dev/null | grep -v tar | grep -vE "ASAN|GAL"
ls -d MS*[58].[5670]* 2>/dev/null | grep -v tar | grep -vE "ASAN|GAL"
