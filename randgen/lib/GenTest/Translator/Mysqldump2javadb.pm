## Javadb/Derby specific variants to Mysqldump2ANSI

package GenTest::Translator::Mysqldump2javadb;

@ISA = qw(GenTest::Translator::Mysqldump2ANSI GenTest::Translator GenTest);

use strict;

sub create_index {
    my $iname = $_[1];
    my $table = $_[2];
    my $index = $_[3];
    return "CREATE INDEX $iname ON $table $index;";
}

1;
