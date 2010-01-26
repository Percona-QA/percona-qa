# Do a simple run of scripts to see that they're sound
#
package IPC;
use base qw(Test::Unit::TestCase);
use lib 'lib';
use lib 'unit';

use Data::Dumper;

use GenTest::IPC::Channel;
use GenTest::IPC::Process;

use IPC_P1;

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

sub testChannel {
    my $self = shift;

    my $outgoing = GenTest::IPC::Channel->new();
    $self->assert_not_null($outgoing);
    
    my $incoming = GenTest::IPC::Channel->new();
    $self->assert_not_null($incoming);

    my $relay = IPC_P1->new($outgoing,$incoming);
    $self->assert_not_null($relay);

    my $relay_p = GenTest::IPC::Process->new($relay);
    $self->assert_not_null($relay_p);

    $relay_p->start();

    $outgoing->writer;
    $incoming->reader;

    $message = ['foo','bar'];

    $outgoing->send($message);
    $outgoing->send($message);

    $outgoing->close;
    
    while ($incoming->more) {
        my $in_message = $incoming->recv;
        $self->assert_not_null($in_message);
        $self->assert_num_equals(1,$#{$in_message});
        $self->assert_str_equals($message->[0],$in_message->[0]);
        $self->assert_str_equals($message->[1],$in_message->[1]);
    }

    $incoming->close;
}


1;
