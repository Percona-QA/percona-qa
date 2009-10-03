## Postgres specific variants to Mysqldump2ANSI

package GenTest::Translator::Mysqldump2pgsql;

@ISA = qw(GenTest::Translator::Mysqldump2ANSI GenTest::Translator GenTest);

use strict;

sub auto_increment {
    my $line = $_[1];
    ## Assumption types like int(11) etc has been converted to integer
    $line =~ s/\binteger(.*)auto_increment\b/SERIAL \1/i;
    return $line;
}

sub create_index {
    my $iname = $_[1];
    my $table = $_[2];
    my $index = $_[3];
    return "CREATE INDEX $iname ON $table $index;";
}

1;
