#!/usr/bin/perl
use warnings;
use strict;

# Sequence match will search through the standard input
# for a sequence of lines that match a sequence of regular
# expressions and report when a match is found.
#
# This can be used to find a blocks of matching code
# within a project.
#
# david. bennett at percona. com - 1/2/2016
#

# The number of non-matching lines to tolerate when
# reporting sequences

my $TOLERANCE=1;

# define the regular expressions to match in $expressions
# the example given will match starting with the last
# variable declaration and beginning of the main loop
# when this script is given as input.

my $expressions = <<'_EOL_';
^my
^while
\$lineNumber
_EOL_

my @matchingExpressions=split /\n/, $expressions;
my $matchCurrentOffset=0;
my $lineNumber=0;
my $startMatchLineNumber=0;
my $currentLinesSkipped=0;

while (<STDIN>) {
  $lineNumber++;
  if ($matchCurrentOffset > 0 && m/$matchingExpressions[$matchCurrentOffset-1]/) {
    if ($matchCurrentOffset == 1) {
      $startMatchLineNumber=$lineNumber;
    }
    $currentLinesSkipped=0;    
  }
  if ($matchCurrentOffset == 0+@matchingExpressions) {
    print "Found on line number: $startMatchLineNumber\n";
    $matchCurrentOffset=0;
    $currentLinesSkipped=0;
  }
  if (m/$matchingExpressions[$matchCurrentOffset]/) {
    $matchCurrentOffset++;
    if ($matchCurrentOffset == 1) {
      $startMatchLineNumber=$lineNumber;
    }
    $currentLinesSkipped=0;
  }
  if ($currentLinesSkipped++ > $TOLERANCE) {
    $matchCurrentOffset=0;
    $currentLinesSkipped=0;
  }
}
