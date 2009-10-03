package GenTest;
use base 'Exporter';
@EXPORT = ('say', 'tmpdir', 'safe_exit', 'windows', 'xml_timestamp', 'rqg_debug');

use strict;

use Cwd;
use POSIX;

my $tmpdir;

1;

sub BEGIN {
	foreach my $tmp ($ENV{TMP}, $ENV{TEMP}, $ENV{TMPDIR}, '/tmp', '/var/tmp', cwd()."/tmp" ) {
		if (
			(defined $tmp) &&
			(-e $tmp)
		) {
			$tmpdir = $tmp;
			last;
		}
	}

	if (
		($^O eq 'MSWin32') ||
		($^O eq 'MSWin64')
	) {
		$tmpdir = $tmpdir.'\\';
	} else {
		$tmpdir = $tmpdir.'/';
	}

	die("Unable to locate suitable temporary directory.") if not defined $tmpdir;
	
	return 1;
}

sub new {
	my $class = shift;
	my $args = shift;

	my $obj = bless ([], $class);

        my $max_arg = (scalar(@_) / 2) - 1;

        foreach my $i (0..$max_arg) {
                if (exists $args->{$_[$i * 2]}) {
                        $obj->[$args->{$_[$i * 2]}] = $_[$i * 2 + 1];
                } else {
                        warn("Unkown argument '$_[$i * 2]' to ".$class.'->new()');
                }
        }

        return $obj;
}

sub say {
	my @t = localtime();
	my $text = shift;

	if ($text =~ m{[\r\n]}sio) {
	        foreach my $line (split (m{[\r\n]}, $text)) {
			print "# ".sprintf("%02d:%02d:%02d", $t[2], $t[1], $t[0])." $line\n";
		}
	} else {
		print "# ".sprintf("%02d:%02d:%02d", $t[2], $t[1], $t[0])." $text\n";
	}
}

sub tmpdir {
	return $tmpdir;
}

sub safe_exit {
	my $exit_status = shift;
	POSIX::_exit($exit_status);
}

sub windows {
	if (
		($^O eq 'MSWin32') ||
	        ($^O eq 'MSWin64')
	) {
		return 1;
	} else {
		return 0;
	}	
}

sub xml_timestamp {
	my $datetime = shift;

	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = defined $datetime ? localtime($datetime) : localtime();
	$mday++;
	$year += 1900;
	
	return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $year, $mon ,$mday ,$hour, $min, $sec);
	
}

sub rqg_debug {
	if ($ENV{RQG_DEBUG}) {
		return 1;
	} else {
		return 0;
	}
}

1;
