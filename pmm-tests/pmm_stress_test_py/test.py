import os

abspath = os.path.abspath(__file__)
dname = os.path.dirname(abspath)

print abspath
print dname[:-18]
