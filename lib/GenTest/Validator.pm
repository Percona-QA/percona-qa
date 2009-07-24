package GenTest::Validator;

@ISA = qw(GenTest);

use strict;
use GenTest::Result;

use constant VALIDATOR_DBH	=> 0;

sub new {
	my $class = shift;
	return $class->SUPER::new({
		dbh => VALIDATOR_DBH
	}, @_);
}

sub init {
	return 1;
}

sub prerequsites {
	return undef;
}

sub dbh {
	return $_[0]->[VALIDATOR_DBH];
}

sub setDbh {
	$_[0]->[VALIDATOR_DBH] = $_[1];
}

1;
