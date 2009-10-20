# Basic grammar test
# Walk through all the grammars and feed them to the Grammar
# constructor. 
#
package GendataTest;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::App::Gendata;
use GenTest::App::GendataSimple;

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

sub test_simple {
    my $self = shift;
    
    my $gen = GenTest::App::GendataSimple->new(dsn => "dummy");

    $gen->run();
}

sub test_advanced {
    my $self = shift;

    my $gen = GenTest::App::Gendata->new(dsn => "dummy",
                                         config_file => "conf/example.zz",
                                         rows => 10000000,
                                         views => 1);
    $gen->run();
}

1;
