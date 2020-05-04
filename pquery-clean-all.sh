#!/bin/bash
ls -d --color=never [0-9][0-9][0-9][0-9][0-9][0-9] | xargs -I{} echo "cd {}; ~/cl; cd -" | xargs -I{} bash -c "{}"
