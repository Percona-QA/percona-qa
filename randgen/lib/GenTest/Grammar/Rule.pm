package GenTest::Grammar::Rule;
use strict;

1;

use constant RULE_NAME		=> 0;
use constant RULE_COMPONENTS	=> 1;

my %args = (
	'name'		=> RULE_NAME,
	'components'	=> RULE_COMPONENTS
);

sub new {
	my $class = shift;
	my $rule = bless ([], $class);

	my $max_arg = (scalar(@_) / 2) - 1;

	foreach my $i (0..$max_arg) {
		if (exists $args{$_[$i * 2]}) {
			$rule->[$args{$_[$i * 2]}] = $_[$i * 2 + 1];
		} else {
			warn("Unkown argument '$_[$i * 2]' to ".$class.'->new()');
		}
	}
	return $rule;
}

sub name {
	return $_[0]->[RULE_NAME];
}

sub components {
	return $_[0]->[RULE_COMPONENTS];
}

sub setComponents {
	$_[0]->[RULE_COMPONENTS] = $_[1];
}

sub toString {
	my $rule = shift;
	my $components = $rule->components();
	return $rule->name().":\n\t".join(" |\n\t", map { join('', @$_) } @$components).";";
}


1;
