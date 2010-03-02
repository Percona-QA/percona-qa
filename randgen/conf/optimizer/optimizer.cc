# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

$combinations = [
	[
	'
		--grammar=conf/opt_grammar_b_exp.yy
		--queries=100K
		--threads=1
		--seed=time
		--mysqld=--init-file=/randgen/gentest-pcrews/mysql-test/gentest/init/no_materialization.sql
	'], [
		'--engine=INNODB',
		'--engine=MYISAM',
		'--engine=MEMORY'
	]
];
