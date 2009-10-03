# A Translator translates SQL from one dialect to another
# 
package GenTest::Translator;

@ISA = qw(GenTest);

use strict;

sub new {
    my $class = shift;
    return $class->SUPER::new(@_);
}

sub translate {
    return $_[0];
}

sub init {
	return 1;
}

1;

