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

$combinations=
[
 [
  '--seed=random',
  '--seed=epoch5'
 ],['
  --duration=300 --querytimeout=60
  --short_column_names --sqltrace
  --reporter=Shutdown,Backtrace,QueryTimeout,ErrorLog,ErrorLogAlarm
  --mysqld=--log-output=none --mysqld=--sql_mode=ONLY_FULL_GROUP_BY
  --grammar=conf/percona_qa/percona_qa.yy --gendata=conf/percona_qa/percona_qa.zz'
 ],[
  '--basedir=/Percona-Server',
  '--basedir=/Percona-Server --valgrind --reporter=ValgrindErrors --validator=MarkErrorLog'
 ],[
  '--threads=1',
  '--threads=10',
  '--threads=20'
 ],[
  '',
  '--views',
  '--notnull',
  '--views --notnull',
  '--validator=Transformer',
  '--notnull --validator=Transformer',
  '--views --notnull --validator=Transformer'
 ],[
  '',
  '--mysqld=--slow_query_log'
 ],[
  '',
  '--mysqld=--userstat'
 ],[
  '',
  '--mysqld=--innodb_lazy_drop_table=1'
 ],[
  '',
  '--mysqld=--innodb_file_per_table=1',
  '--mysqld=--innodb_file_per_table=1 --mysqld=--innodb_file_format=barracuda'
 ]
]
