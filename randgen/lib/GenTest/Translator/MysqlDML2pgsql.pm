## Pgsql/Derby specific variants to MysqlDML2ANSI

package GenTest::Translator::MysqlDML2pgsql;

@ISA = qw(GenTest::Translator::MysqlDML2ANSI GenTest::Translator GenTest);

use GenTest;

use strict;

## LIMIT n is equal
## LIMIT n OFFSET m is equal
## LIMIT m,n needs to be changed

sub limit {
    my $dml = $_[1];
    $dml =~ s/\bLIMIT\s+(\d+)\s*,\s*(\d+)/LIMIT \2 OFFSET \1/;
    return $dml;
}



1;
