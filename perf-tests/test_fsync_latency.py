#!/usr/bin/python

import os, sys, mmap
#import cProfile

FILE_NAME="testfile"
ROUNDS=1000

if len(sys.argv) >= 2:
   ROUNDS=int(sys.argv[1])

def test_sync():
   print(f"Usage: time python {sys.argv[0]} [rounds]")
   print("rounds - a number of fsync calls (default=1000)")
   print("\nReturns e.g.:")
   print("# real  0m6,334s")
   print("# user  0m0,036s")
   print("# sys   0m0,041s")
   print("Where \"real\" shows latency = 6,334s/1000 rounds = 6,334 ms")
   print(f"\nStart testing {ROUNDS} rounds...")

   # Open a file
   fd = os.open( FILE_NAME, os.O_RDWR|os.O_CREAT|os.O_DIRECT )

   m = mmap.mmap(-1, 512)

   for i in range (1,ROUNDS):
      os.lseek(fd,os.SEEK_SET,0)
      m[1] = 1
      os.write(fd, m)
      os.fsync(fd)

   # Close opened file
   os.close( fd )
   os.remove(FILE_NAME)

#cProfile.run("test_sync()", sort='cumulative')
test_sync()
