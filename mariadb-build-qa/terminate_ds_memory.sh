#!/bin/bash

if [ ! -z "$(ps -ef | grep -E '/ds$|/memory$')" ]; then
  echo 'Will terminate ~/ds and ~/memory after 3 seconds, as these are known to kill builds at random times!'
  sleep 3
  ps -ef | grep -E '/ds$|/memory$' | grep bash | awk '{print $2}' | xargs kill -9
fi
