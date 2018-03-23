#!/usr/bin/perl
# Created by Roel Van de Paar, Percona LLC

use strict 'vars';
use Getopt::Std;
our ($opt_i,$opt_o);
getopt('io');

if (($opt_i eq '')||($opt_o eq '')){
  print "Usage: [perl] ./parse_general_log.pl -i infile -o outfile\n";
  print "Where infile is a standard myqld general query log\n";
  print "General mysqld logs can be generated with these options to mysqld:\n";
  print "  --log-output=FILE --general_log --general_log_file=general.log\n\n";
  print "WARNING: by default this script eliminates a number of statements which may cause replay issues (KILL, RELEASE)\n";
  print "This may lead to non-reproducibility for certain bugs. Check the script's source for specifics\n";
  exit 1;
}

open IFILE, "<", $opt_i or die $!;
open OFILE, ">", $opt_o or die $!;

print OFILE "DROP DATABASE transforms;CREATE DATABASE transforms;DROP DATABASE test;CREATE DATABASE test;USE test";

while (<IFILE>) {
  chomp ($_);
  my $out="";
  # Is this a header (at top of file or anywhere inside the file - for when multiple files are combined)
  if ((!($_=~/,.*version:.*started with:/i))&&(!($_=~/^tcp port:/i))&&(!($_=~/unix socket:/i))&&(!($_=~/^time.*id.*command.*argument/i))){
    # Write multi-line statements: if line does not starts with a tab, nor a date, then this is a multi-line: write result directly to the output file
    if ((!($_=~/^\t/))&&(!($_=~/^[0-9][0-9][-0-9][0-9][-0-9][-0-9]/))){  
        $out = substr $_,0,9999999;
        if ((!($out=~/^kill [0-9]/i))&&(!($out=~/commit[^n.]*release/i))){
          print OFILE " $out";
        }
    # This is a normal line, check contents
    }elsif (($_=~/[0-9] Query\t/)||($_=~/[0-9] Prepare\t/)||($_=~/[0-9] Execute\t/)){
      if ($_=~/^[0-9]/){
        # Fix line format for lines that have timestamps
        s/.*[0-9] Query\t/\t\t    0 Query\t/;
        s/.*[0-9] Prepare\t/\t\t    0 Prepare\t/;
        s/.*[0-9] Execute\t/\t\t    0 Execute\t/;
      }
      s/\t/        /g;
      $out = substr $_,35,9999999;
      # Drop KILL and COMMIT RELEASE statements (KILL QUERY and COMMIT NO RELEASE are not affected)
      if ((!($out=~/^kill [0-9]/i))&&(!($out=~/commit[^n.]*release/i))){
        print OFILE ";\n$out";
      }
    }elsif ($_=~/[0-9] Init DB\t/){
      $out = substr $_,16,999;
      print OFILE ";\nUSE $out";
    }
  }
}
# Fixup last line
print OFILE ";\n";

# Close files
close IFILE;
close OFILE;

# Finish
print "Done! Output is ready in: $opt_o\n";
