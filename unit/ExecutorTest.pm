# Basic grammar test
# Walk through all the grammars and feed them to the Grammar
# constructor. 
#
package ExecutorTest;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Constants;
use GenTest::Executor;

use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $executor;
sub set_up {
    $executor = GenTest::Executor->newFromDSN("dummy");
}

sub tear_down {
    # clean up after test
}

sub test_create {
    my $self = shift;
    
    $self->assert_not_null($executor);
}

sub test_functions {
    my $self = shift;

    my $type = $executor->type();

    $self->assert_equals(DB_DUMMY, $type);

    my $name = $executor->getName();

    $self->assert_equals("Dummy", $name);
    
}
1;
