package GenTest::Executor;

require Exporter;
@ISA = qw(GenTest Exporter);

@EXPORT = qw(
        EXECUTOR_ROW_STATS
	EXECUTOR_EXPLAIN_STATS
	EXECUTOR_ERROR_STATS
);

use strict;
use GenTest;

use constant EXECUTOR_DSN		=> 0;
use constant EXECUTOR_DBH		=> 1;
use constant EXECUTOR_ID		=> 2;
use constant EXECUTOR_DEBUG		=> 3;
use constant EXECUTOR_ROW_STATS		=> 4;
use constant EXECUTOR_EXPLAIN_STATS	=> 5;
use constant EXECUTOR_ERROR_STATS	=> 6;

1;

sub new {
        my $class = shift;
	
	my $executor = $class->SUPER::new({
		'dsn'	=> EXECUTOR_DSN,
		'dbh'	=> EXECUTOR_DBH,
		'debug'	=> EXECUTOR_DEBUG
	}, @_);

        return $executor;
}

sub dbh {
	return $_[0]->[EXECUTOR_DBH];
}

sub setDbh {
	$_[0]->[EXECUTOR_DBH] = $_[1];
}

sub dsn {
	return $_[0]->[EXECUTOR_DSN];
}

sub setDsn {
	$_[0]->[EXECUTOR_DSN] = $_[1];
}

sub debug {
	return $_[0]->[EXECUTOR_DEBUG];
}

sub id {
	return $_[0]->[EXECUTOR_ID];
}

sub setId {
	$_[0]->[EXECUTOR_ID] = $_[1];
}

1;
