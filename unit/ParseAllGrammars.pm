# Basic grammar test
# Walk through all the grammars and feed them to the Grammar
# constructor. 
#
package ParseAllGrammars;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Grammar;

use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $generator;
sub set_up {
}

sub tear_down {
    # clean up after test
}

sub test_parse {
    my $self = shift;
    open FILE,"ls -1 conf/*.yy|";
    while (<FILE>) {
        chop;
        my $grammar = new GenTest::Grammar(grammar_file => $_);
        $self->assert_not_null($grammar);
        my $startRule = $grammar->firstMatchingRule("query");
        $self->assert_not_null($startRule);
    }
}


1;
