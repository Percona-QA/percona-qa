package FromGrammarTest;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Generator::FromGrammar;

use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $generator;
sub set_up {
    $generator = GenTest::Generator::FromGrammar->
        new(grammar_string => "query: item1 | item2 ;\nitem1: a | b ;\n");
}

sub tear_down {
    # clean up after test
}

sub test_create_generator {
    my $self = shift;
    
    $self->assert_not_null($generator);
}

sub test_generator_next {
    my $self = shift;

    my $x = $generator->next();
    my @x = @$x;
    $self->assert_equals(0, $#x);
    $self->assert_equals('b', $x[0]);

    my $x = $generator->next();
    my @x = @$x;
    $self->assert_equals(0, $#x);
    $self->assert_equals('item2', $x[0]);
}


1;
