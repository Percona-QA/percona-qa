#!/bin/sh
# Created by David Bennett, Percona LLC

# Make sure we have a URL
if [ -z "$1" ]; then
  echo "Download all rpm or deb packages from the given URL."
  echo "Usage: $0 {url}"
  exit
fi

# determine package manager for requirements function
pkgmgr=
hash apt-get >/dev/null 2>&1
if [ $? -eq 0 ]; then
  pkgmgr='apt-get'
else
  hash yum >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    pkgmgr='yum'
  fi
fi

# function to check for script dependency
reqmissing=0
requires()
{
  hash "$1" >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    reqmissing=$((reqmissing+1))
    echo "This script requires the $1 command."
    if [ -n "${pkgmgr}" ]; then
      echo "Use the ${pkgmgr} command to install it:"
      printf "\tsudo %s install %s" ${pkgmgr} "$1"
    fi
    echo ""
  fi
}

# check script dependencies
requires "lynx"
requires "wget"
# exit if something is missing
if [ $reqmissing -gt 0 ]; then
  exit 1
fi

# this is the actual downloader

# extract links
urls=$(lynx -dump "$1" 2> /dev/null | grep -E '\.(rpm|deb)$' | awk '/http/{print $2}')
# download
if [ "${urls}" ]; then
  printf "%s\n" "${urls}" | while IFS= read -r url
  do
     wget "${url}"
  done
else
  echo "No Packages found"
fi
