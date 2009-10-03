## Javadb/Derby specific variants to MysqlDML2ANSI

package GenTest::Translator::MysqlDML2javadb;

@ISA = qw(GenTest::Translator::MysqlDML2ANSI GenTest::Translator GenTest);

use strict;

use GenTest;

sub supported_join() {
    if ($_[1] =~ m/\bUSING\b/i ) {
        say("USING clause not supported by JavaDB/Derby");
        return 0;
    } elsif ($_[1] =~ m/\bNATURAL\b/i ) {
        say("NATURAL join not supported by JavaDB/Derby");
        return 0;
    } else {
        return 1;
    }
}

1;

