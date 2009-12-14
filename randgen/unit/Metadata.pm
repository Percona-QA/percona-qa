# Do a simple run of scripts to see that they're sound
#
package Metadata;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use GenTest::Executor;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $executor;
sub set_up {
    $executor = new GenTest::Executor->newFromDSN('dummy');    
    $executor->cacheMetaData();
}

sub tear_down {
}

sub test_metadata {
    my ($self) = @_;
    my $data = $executor->metaCollations();
    my $data = $executor->metaCharactersets();
    my $data = $executor->metaSchemas();
    my $data = $executor->metaColumns('tab','schema');
    my $data = $executor->metaColumnsType('indexed','tab','schema');
    my $data = $executor->metaColumnsTypeNot('pk','tab','schema');
}

sub test_missingmetadata {
    my ($self) = @_;
    my $data;
    
    eval {
        $data = $executor->metaColumns('foo','bar');
    };
    $self->assert_equals(-1,$#$data);
    
    eval {
        $data = $executor->metaColumnsType('indexed','foo','bar');
    };
    $self->assert_equals(-1,$#$data);
    
    eval {
        $data = $executor->metaColumnsTypeNot('pk','foo','bar');
    };
    $self->assert_equals(-1,$#$data);
    
}

1;
