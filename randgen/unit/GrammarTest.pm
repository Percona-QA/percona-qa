package GrammarTest;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Grammar;

use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $grammar;
sub set_up {
    $grammar = GenTest::Grammar->new(grammar_string => "query: item1 | item2 ;\nitem1: a | b ;\n");
}

sub tear_down {
    # clean up after test
}

sub test_create_grammar {
    my $self = shift;
    
    $self->assert_not_null($grammar);
    
    $self->assert_not_null($grammar->rule("item1"));
    $self->assert_null($grammar->rule("item2"));
}

sub test_patch_grammar {
    my $self = shift;

    my $newGrammar = GenTest::Grammar->new(grammar_string => "item1 : foobar ;\nitem2: barfoo ;\n");

    my $patchedGrammar = $grammar->patch($newGrammar);

    $self->assert_not_null($patchedGrammar);
    $self->assert_not_null($patchedGrammar->rule('item2'));


    $item1= $patchedGrammar->rule('item1');
    $self->assert_not_null($item1);
    $self->assert_matches(qr/foobar/, $item1->toString());
}

sub test_top_grammar {
    my $self =shift;

    my $topGrammar = $grammar->topGrammar(1,'foobar','query');
    $self->assert_not_null($topGrammar);
    $self->assert_not_null($topGrammar->rule('query'));
    $self->assert_null($topGrammar->rule('itme1'));
}

1;
