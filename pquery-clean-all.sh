#!/bin/bash
ls -d --color=never [0-9][0-9][0-9][0-9][0-9][0-9] | xargs -I{} echo "if [ -d ./{} ]; then cd {}; ~/cl; cd -; fi" | xargs -P10 -I{} bash -c "{}"
