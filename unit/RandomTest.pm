package RandomTest;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Random;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

sub set_up {
    # provide fixture
}

sub tear_down {
    # clean up after test
}

sub test_create_prng {
    my $self = shift;
    
    my $obj = GenTest::Random->new(seed => 1);
    
    $self->assert_not_null($obj);

}

1;
