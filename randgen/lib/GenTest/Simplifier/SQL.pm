package GenTest::Simplifier::SQL;

require Exporter;
use GenTest;
@ISA = qw(GenTest);

use strict;

use lib 'lib';
use DBIx::MyParsePP;
use DBIx::MyParsePP::Rule;

my $empty_child = DBIx::MyParsePP::Rule->new();
my $myparse = DBIx::MyParsePP->new();

use constant SIMPLIFIER_ORACLE		=> 0;
use constant SIMPLIFIER_CACHE		=> 1;
use constant SIMPLIFIER_QUERY_OBJ	=> 2;

1;

sub new {
        my $class = shift;

	my $simplifier = $class->SUPER::new({
		'oracle'	=> SIMPLIFIER_ORACLE,
		'cache'		=> SIMPLIFIER_CACHE
	}, @_);

	$simplifier->[SIMPLIFIER_CACHE] = {} if not defined $simplifier->[SIMPLIFIER_CACHE];

	return $simplifier;
}

sub simplify {
	my ($simplifier, $initial_query) = @_;

	return $initial_query if $initial_query =~ m{^\s*$}sio;

	if (!$simplifier->oracle($initial_query)) {
		warn("Initial query $initial_query failed oracle check.");
		return undef;
	}

	my $query_obj = $myparse->parse($initial_query);
	$simplifier->[SIMPLIFIER_QUERY_OBJ] = $query_obj;

	$simplifier->[SIMPLIFIER_CACHE] = {};

	my $root = $query_obj->root();
        $root->shrink();

	$simplifier->descend($root, undef, 0);

	$simplifier->[SIMPLIFIER_CACHE] = {};

	my $final_query = $root->toString();

	if (!$simplifier->oracle($final_query)) {
		warn("Final query $final_query failed oracle check");
		return undef;
	} else {
		return $final_query;
	} 
}

sub descend {
	my ($simplifier, $parent, $grandparent, $parent_id) = @_;

	my $query_obj = $simplifier->[SIMPLIFIER_QUERY_OBJ];

	my @children = $parent->children();
	return if $#children == -1;

	foreach my $child_id (0..$#children) {

		my $orig_child = $children[$child_id];
		my $orig_parent = $grandparent->[$parent_id + 1];

		if (defined $grandparent) {	
			# replace parent with child
			my $child_str = $orig_child->toString();
			$grandparent->[$parent_id + 1] = $orig_child;
			my $new_query1 = $query_obj->toString();
			$grandparent->[$parent_id + 1] = $orig_parent;

			if ($simplifier->oracle($new_query1)) {
				# Problem is still present, make tree modification permanent
				$grandparent->[$parent_id + 1] = $orig_child;
				$simplifier->descend($orig_child, $grandparent, $parent_id);
			}
		}

		# remove the child altogether

		$parent->[$child_id + 1] = $empty_child;
		my $new_query2 = $query_obj->toString();
		$parent->[$child_id + 1] = $orig_child;
		my $removed_fragment2 = $orig_child->toString();

		next if $removed_fragment2 =~ m{^\s*$}sio;	# Empty fragment, skip

		if ($new_query2 =~ m{^\s*$}sio) {		# New query is empty, we amputated too much
			$simplifier->descend($orig_child, $parent, $child_id);
		}

		my $oracle_outcome2 = $simplifier->oracle($new_query2);

		if ($simplifier->oracle($new_query2)) {
			# Problem is still present, make tree modification permanent
			$parent->[$child_id + 1] = $empty_child;
		} else {
			$simplifier->descend($orig_child, $parent, $child_id);
		}
	}
}

sub oracle {
	my ($simplifier, $query) = @_;

	my $cache = $simplifier->[SIMPLIFIER_CACHE];
	my $oracle = $simplifier->[SIMPLIFIER_ORACLE];

	$cache->{$query} = $oracle->($query) if not exists $cache->{$query};
	return $cache->{$query};
}

1;
