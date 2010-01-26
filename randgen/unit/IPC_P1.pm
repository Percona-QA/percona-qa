package IPC_P1;

use Data::Dumper;
use GenTest::IPC::Channel;

sub new {
    my $class = shift;
    my $self = {};

    $self->{IN}=shift;
    $self->{OUT}=shift;
    bless($self, $class);

    return $self;
}

sub run {
    my ($self, $arg) = @_;

    $self->{IN}->reader;
    $self->{OUT}->writer;
    
    while ($self->{IN}->more) 
    {
        my $msg = $self->{IN}->recv;
        if (defined $msg) {
            $self->{OUT}->send($msg);
        }
    }
    
    $self->{OUT}->close;
    $self->{IN}->close;
    
}

1;
