package GenTest::IPC::Channel;

use strict;

use IO::Handle;
use Data::Dumper;
use GenTest;

sub new {
    my $class = shift;
    my $self = {};

    ## open  bi-directional pipe
    pipe IN,OUT;

    $self->{IN}=*IN;
    $self->{OUT}=*OUT;
    $self->{EOF}= 0;
    $self->{READER} = undef;
    
    ## Turn off buffering of output. Each object is sent as one
    ## print-statement
    $self->{OUT}->autoflush(1);
    bless($self,$class);
    return $self;
}

sub send {
    my ($self,$obj) = @_;

    ## Preliminary save Data::Dumper settings since this is a global setting
    my $oldindent = $Data::Dumper::Indent;
    my $oldpurity = $Data::Dumper::Purity;

    ## Make output with no newlines and suitable for eval
    $Data::Dumper::Indent = 0;
    $Data::Dumper::Purity = 1;

    my $msg = Dumper($obj);

    ## Encode newline because that is used as message separator
    ## (readline on the other end)
    $msg =~ s/\n/&NEWLINE;/g;

    my $chn = $self->{OUT};
    print $chn $msg,"\n";

    ## Reset indent to old value
    $Data::Dumper::Indent = $oldindent;
    $Data::Dumper::Purity = $oldpurity;
}

sub recv {
    my ($self) = @_;
    my $obj;

    ## Read until eof or an object that may be evaluated is recieved
    while (!(defined $obj) and !(eof $self->{IN})) {
        my $line = readline $self->{IN};

        ## Decode eol
        $line =~ s/&NEWLINE;/\n/g;

        ## Turn off strict vars since received message uses variables
        ## without "my"
        no strict "vars";

        ## Evaluate object
        $obj = eval $line;
        use strict "vars";
    };
    $self->{EOF} = eof $self->{IN};
    return $obj;
}

sub reader{
    my ($self) = @_;
    
    ## Readers don't need the output part
    close $self->{OUT};
    $self->{READER} = 1;
}

sub writer {
    my ($self) = @_;

    ## Writers don't need the input part
    close $self->{IN};
    $self->{READER} = 0;
}

sub close {
    my ($self) = @_;
    if (not defined $self->{READER}) {
        close $self->{OUT};
        close $self->{IN};
    } elsif ($self->{READER}) {
        close $self->{IN};
    } else {
        close $self->{OUT};
        sleep 10;
    }
}

sub more {
    my ($self) = @_;
    return not $self->{EOF};
}

1;

