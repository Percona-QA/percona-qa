# Copyright (c) 2011, Oracle and/or its affiliates. All rights reserved.
#
# 1. Non bug related modifications which
#    - accelerate grammar simplification
#    - remove coverage for unimportant functionality
#      The functionality should be already covered in MTR tests and is not related to locking.
#

as_or_empty:
   AS ;

database_schema:
   DATABASE ;

databases_schemas:
   DATABASES ;

default_or_empty:
   DEFAULT ;

equal_or_empty:
   = ;

index_or_key:
   INDEX ;

into_or_empty:
   INTO ;

savepoint_or_empty:
   SAVEPOINT ;

table_or_empty:
   TABLE ;

work_or_empty:
   WORK ;

# 2. Bug related modifications
#

delayed:
   # Only 10 %
   # Bug#11763532 Deadlock between INSERT DELAYED and FLUSH TABLES
   # Disabled: INSERT/REPLACE DELAYED
   # | | | | | | | | | DELAYED ;
   ;

