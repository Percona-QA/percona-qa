# Copyright (c) 2012 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

# Certain parts (c) Percona Inc

# Note that --short_column_names is required for this grammar (see .zz for use of 'c1' name)

$combinations=
[
 ['
  --seed=random --duration=300 --querytimeout=60 --short_column_names
  --reporter=Shutdown,Backtrace,QueryTimeout,ErrorLog,ErrorLogAlarm
  --mysqld=--log-output=none --mysqld=--sql_mode=ONLY_FULL_GROUP_BY
 '],[
  '--grammar=conf/percona_qa/34411/34411.yy --gendata=conf/percona_qa/34411/34411.zz --threads=15
     --basedir=/Percona-Server-Debug',
  '--grammar=conf/percona_qa/34411/34411.yy --gendata=conf/percona_qa/34411/34411.zz --threads=10
     --basedir=/Percona-Server-Valgrind --valgrind --reporter=ValgrindErrors --validator=MarkErrorLog',
  '--grammar=conf/percona_qa/34411/34411.yy --gendata=conf/percona_qa/34411/34411.zz --threads=20 
     --basedir=/Percona-Server-Optimized'
 ],[
  '--notnull',''
 ],[
  '--no-mask --mysqld=--innodb_file_per_table=1',
  '--no-mask --mysqld=--innodb_file_per_table=1 --mysqld=--innodb_file_format=barracuda',
  '--mask-level=1',
 ],[
  '--mysqld=--innodb_flush_method=O_DSYNC
  '--mysqld=--innodb_flush_method=O_DIRECT
 ],[
  '--mysqld=--innodb_fast_shutdown=2
   --mysqld=--innodb_log_file_size=1048576
   --mysqld=--innodb_log_files_in_group=2
   --mysqld=--innodb_log_group_home_dir=_epoch
   --mysqld=--innodb_log_buffer_size=10485761
   --mysqld=--innodb_flush_log_at_trx_commit=1
  ',''
 ]
]
