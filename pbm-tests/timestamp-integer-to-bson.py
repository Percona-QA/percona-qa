#!/usr/bin/env python3
import sys
from bson.timestamp import Timestamp

def long_to_bson_ts(val):
    """Convert integer into BSON timestamp.
    """
    seconds = val >> 32
    increment = val & 0xffffffff

    return Timestamp(seconds, increment)

print("{}".format(long_to_bson_ts(int(sys.argv[1]))))
