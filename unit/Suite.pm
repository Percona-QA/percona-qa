package Suite;
use lib 'unit';
use base qw(Test::Unit::TestSuite);

sub name { 'My very own test suite' } 
sub include_tests { qw(RandomTest GrammarTest) }

1;
