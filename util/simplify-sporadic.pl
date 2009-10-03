use strict;
use DBI;
use lib 'lib';
use lib '../lib';

$| = 1;
require GenTest::Simplifier::SQL;

#
# This script demonstrates the simplification of queries that fail sporadically. In order to account for the sporadicity,
# we define an oracle() that runs every query 5000 times, and reports that the problem is gone only if all 5000 instances
# returned the same number of rows. Otherwise, it reports that the problem remains, and the Simplifier will use this information
# to further quide the simplification process. More information is available at:
#
# http://forge.mysql.com/wiki/RandomQueryGeneratorSimplification
#

my $query = " SELECT table3 .`date_key` field1  FROM B table1  LEFT  JOIN B  JOIN ( B table3  JOIN ( AA table4  JOIN ( C table6  JOIN A table7  ON table6 .`varchar_nokey`  )  ON table6 .`int_key`  )  ON table6 .`int_nokey`  )  ON table6 .`varchar_nokey`  ON table6 .`date_key`  WHERE  NOT ( (  NOT (  NOT (  NOT (  NOT table7 .`int_key`  >= table1 .`varchar_key`  OR table3 .`time_nokey`  <> table1 .`pk`  )  AND table4 .`date_key`  >= table1 .`date_key`  )  OR table3 .`time_key`  > '2005-07-24 11:06:03' )  AND table1 .`datetime_key`  <=  8  )  AND table7 .`pk`  <  6  )  GROUP  BY field1  ORDER  BY field1  , field1  , field1  , field1  LIMIT  7 ";
my $trials = 1000;

my $dsn = 'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test';
my $dbh = DBI->connect($dsn);

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $query = shift;
		print "testing $query\n";
		my %outcomes;
		foreach my $trial (1..$trials) {
			my $sth = $dbh->prepare($query);
			$sth->execute();
			return 0 if $sth->err() > 0;
			$outcomes{$sth->rows()}++;
			print "*";
			return 1 if scalar(keys %outcomes) > 1;
		}
		return 0;
	}
);
my $simplified = $simplifier->simplify($query);

print "Simplified query:\n$simplified;\n";
