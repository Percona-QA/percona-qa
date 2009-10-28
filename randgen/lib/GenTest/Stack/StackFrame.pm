package GenTest::Stack::StackFrame;

use strict;
use Data::Dumper;

sub new {
	my $class = shift;

	my $frame = bless({}, $class);

	return $frame;
}

sub set {
    my ($self, $name, $value) = @_;
    $self->{$name}=$value;
    return undef;
}

sub get {
    my ($self, $name) = @_;
    return $self->{$name};
}

1;
