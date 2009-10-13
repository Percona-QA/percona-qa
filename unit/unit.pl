use lib unit;

use strict;

use Test::Unit::Debug qw(debug_pkgs);
use Test::Unit::TestRunner;
use RQGRunner;

# Uncomment and edit to debug individual packages.
# debug_pkgs(qw/Test::Unit::TestCase/);

my $testrunner = RQGRunner->new();
my $result = $testrunner->start(@ARGV);
exit $result;
