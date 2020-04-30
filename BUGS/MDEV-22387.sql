# Start up server with ASAN+UBSAN and observe issues seen during startup in error log
#/test/10.5_dbg/strings/ctype-mb.c:409:3: runtime error: null pointer passed as argument 2, which is declared to never be null
#/test/10.5_dbg/mysys/mf_iocache.c:825:3: runtime error: null pointer passed as argument 1, which is declared to never be null
#/test/10.5_dbg/sql/protocol.cc:61:9: runtime error: null pointer passed as argument 2, which is declared to never be null
