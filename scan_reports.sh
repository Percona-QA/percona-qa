#!/bin/bash

grep -A1 -m1 'Bug confirmed present in:' *.report | more
