package Suite;
use lib 'unit';
use base qw(Test::Unit::TestSuite);

sub name { 'RQG Unit Tests' } 

sub include_tests { 
qw(RandomTest 
GrammarTest 
FromGrammarTest 
ParseAllGrammars
GendataTest
ExecutorTest
TestScripts
Metadata
) }

1;
