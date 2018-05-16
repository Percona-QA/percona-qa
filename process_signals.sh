#!/usr/bin/perl

# Display signals blocked, ignored and caught by a process

# use as: $0 [PID]...

# based on a script by waldner

# Enhanced by David Bennett - david.bennett@percona.com - 2015-02-24

use warnings;
use strict;
use bignum;
use Config;

my %sigMap=(
  'SigPnd','Thread Pending',
  'ShdPnd','Process Pending',
  'SigBlk','Blocked',
  'SigIgn','Ignored',
  'SigCgt','Caught'
);

defined $Config{sig_name} or die "Cannot find signal names in Config";
my @sigs = map { "SIG$_" } split(/ /, $Config{sig_name});

# print the process

sub showproc {
  my $pid=shift(@_);

  # print BSD style process output
  my $pscmd = "ps xww -q $pid";
  open (P, "$pscmd |");
  while(<P>) { print; }
  close P;

  # print the signal status

  my $statfile = "/proc/$pid/status";

  open(S, "<", $statfile) or die "Cannot open status file $statfile";

  while(<S>) {
    chomp;
    if (/^((Sig|Shd)(Pnd|Blk|Ign|Cgt)):\s+(\S+)/) {
      if (my @list = grep { oct("0x$4") & (1 << ($_ - 1)) } (1..64) ) {
        print "\t$sigMap{$1}: " . join(",", map { "$sigs[$_]" } @list) . "\n";
      }
    }
  }
  close(S);
}

# main loop
foreach my $pid (@ARGV) {
  showproc($pid);
}
