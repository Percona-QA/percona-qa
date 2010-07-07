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

use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest::Constants;
use GenTest::Executor::MySQL;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;

#
# Please modify those settings to fit your environment before you run this script
#

my $basedir = '/build/bzr/mysql-6.0-codebase-bugfixing';
my $vardir = $basedir.'/mysql-test/var';
my $dsn = 'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test';

my $original_query = ' 
	SELECT 1 FROM DUAL
';

# Maximum number of seconds a query will be allowed to proceed. It is assumed that most crashes will happen immediately after takeoff
my $timeout = 5;

my @mtr_options = (
#	'--mysqld=--innodb',
	'--start-and-exit',
	'--start-dirty',
	"--vardir=$vardir",
	"--master_port=19306",
	'--skip-ndbcluster',
	'--mysqld=--core-file-size=1',
	'--fast',
	'1st'	# Required for proper operation of MTR --start-and-exit
);

my $orig_database = 'test';
my $new_database = 'crash';

my $executor;

start_server();

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $oracle_query = shift;
		my $dbh = $executor->dbh();
	
		my $connection_id = $dbh->selectrow_array("SELECT CONNECTION_ID()");
		$dbh->do("CREATE EVENT timeout ON SCHEDULE AT CURRENT_TIMESTAMP + INTERVAL $timeout SECOND DO KILL QUERY $connection_id");

		my $oracle_result = $executor->execute($oracle_query);

		$dbh->do("DROP EVENT IF EXISTS timeout");

		if (!$executor->dbh()->ping()) {
			start_server();
			return ORACLE_ISSUE_STILL_REPEATABLE;
		} else {
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
		}
	}
);

my $simplified_query = $simplifier->simplify($original_query);
print "Simplified query:\n$simplified_query;\n\n";

my $simplifier_test = GenTest::Simplifier::Test->new(
	executors => [ $executor ],
	queries => [ $simplified_query , $original_query ]
);

my $simplified_test = $simplifier_test->simplify();

print "Simplified test\n\n";
print $simplified_test;

sub start_server {
	chdir($basedir.'/mysql-test') or die $!;
	system("MTR_VERSION=1 perl mysql-test-run.pl ".join(" ", @mtr_options));

	$executor = GenTest::Executor::MySQL->new( dsn => $dsn );

	$executor->init();

	my $dbh = $executor->dbh();

	$dbh->do("SET GLOBAL EVENT_SCHEDULER = ON");
}
