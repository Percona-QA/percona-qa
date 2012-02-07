package GenTest::CallbackPlugin;

use strict;
use Carp;
use GenTest;

## THis module is intended for plugins (Reporters, validators etc)
## which need to call back to the framework that started RQG to
## perform certain tasks. E.g. if the db server is running another
## blace in the network, Bactrace.pm can't be performed by RQ itself
## and then have to call back to the framework to get the task
## performed.

## Usage:
##  if (defined $ENV{RQG_CALLBACK}) {
##      GenTest::CallbackPlugin("Something");
## } else {
##      do whatever in RQG
## }

## This assumes that it is (in the given framework that have set
## RQG_CALLBACK) that the command
##    $RQG_CALLBACK Something
## Will give some meaningful output

sub run {
    my ($argument) = @_;
    
    my $command = $ENV{RQG_CALLBACK} ." ". $argument;

    say("Running callback command $command");

    my $output = `$command`;
    
    return "$output";
}

1;
