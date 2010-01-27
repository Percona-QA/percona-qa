package GenTest::ErrorFilter;

use GenTest;
use GenTest::IPC::Channel;

use strict;

sub new {
    my $class = shift;
    my $self = {};

    $self->{CHANNEL} = shift;
    $self->{CACHE} = {};

    bless ($self, $class);

    return $self;
}

sub run {
    my ($self,@args) = @_;
    $self->{CHANNEL}->reader;
    while (1) {
        my $msg = $self->{CHANNEL}->recv;
        if (defined $msg) {
            my ($query, $err, $errstr) = @$msg;
            if (not defined $self->{CACHE}->{$errstr}) {
                say("Query: $query failed: $err $errstr. Further errors of this kind will be suppressed.");
            }
            $self->{CACHE}->{$errstr}++;
        }
        sleep 1 if !$self->{CHANNEL}->more;
    }
    $self->{CHANNEL}->close;
}

1;
