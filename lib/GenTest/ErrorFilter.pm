package GenTest::ErrorFilter;

@ISA = qw(GenTest);

use GenTest;
use GenTest::IPC::Channel;

use strict;

use constant ERRORFILTER_CHANNEL => 0;
use constant ERRORFILTER_CACHE => 1;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new({
        'channel' => ERRORFILTER_CHANNEL},@_);

    $self->[ERRORFILTER_CACHE] = {};

    return $self;
}

sub run {
    my ($self,@args) = @_;
    $self->[ERRORFILTER_CHANNEL]->reader;
    while (1) {
        my $msg = $self->[ERRORFILTER_CHANNEL]->recv;
        if (defined $msg) {
            my ($query, $err, $errstr) = @$msg;
            if (not defined $self->[ERRORFILTER_CACHE]->{$errstr}) {
                say("Query: $query failed: $err $errstr. Further errors of this kind will be suppressed.");
            }
            $self->[ERRORFILTER_CACHE]->{$errstr}++;
        }
        sleep 1 if !$self->[ERRORFILTER_CHANNEL]->more;
    }
    $self->[ERRORFILTER_CHANNEL]->close;
}

1;
