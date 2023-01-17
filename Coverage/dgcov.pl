#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use File::Find;
use File::Basename;
use Carp;
use Data::Dumper;

my $verbose;
my $help;
my $sandbox = undef;
my $uncommitted;

#Main

my $options= GetOptions
  (
   "verbose"    => \$verbose,
   "help"        => \$help,
   "sandbox=s"     => \$sandbox,
   "uncommitted"  => \$uncommitted,
  );

if (not $options) {
    print "Use --help for usage\n";
    exit 1;
}

usage() if $help;

my $file_regexp= qr/\.(c|cc|cpp|h|hpp|i|ic)$/;
my $git = "git";
my $nosource = {};
my $uncommitt_filemap = {};
my $filemap = {};
my %missing_files;

my @revisions = @ARGV;

printReport("----- Start of report ----- \n");

# Find source location to run the scrip from.
$sandbox = findSource($sandbox);

# Staged changes only.
if($uncommitted) {
  $uncommitt_filemap = find_uncommitted_changes();
}

for my $file (sort keys %$filemap) {
  my $gcov_file = findGcovFile($file);
  if (defined $gcov_file) {
      print "Using $gcov_file for $file\n" if $verbose;
      my $gcov_dir = dirname($gcov_file);

      my $res = open FH, '<', $gcov_file;
      if(!$res) {
          carp "Failed to open gcov output file '$gcov_file'\n";
          $missing_files{$gcov_file}=1;
          next;
      }
   close FH;
  }
}

printReport("----- End of report ----- \n");
exit 0;

#Subroutines

sub ignoreDir {
    my ($dir) = @_;
    return 1 if $dir =~ m/embedded.dir/;
    return 1 if $dir =~ m/innochecksum.dir/;
    return 0;
}

sub findGcovFile {
    my ($fname) = @_;
    # Seperate dir and filename.
    my $dir = dirname($fname);
    my @dir = split('/', $dir);
    @dir = reverse @dir;
    my $file = basename($fname);
    
    my @found;
    print "Looking for gcov files for $fname\n" if $verbose;
    find({wanted => sub {
        ## Ignore embedded files
        if ($_ eq "$file.gcno") {
            if (ignoreDir($File::Find::dir)) {
                print "Ignoring $File::Find::name\n" if $verbose;
            } else {
                push @found, $File::Find::dir."/".$file.".gcov";
            }
        }
          }
         },
         ".");

    my $gcf;
    if ($#found < 0) {
        # None found
        $gcf = undef;
    } elsif ($#found == 0) {
        # If just one, we pick it
        $gcf = $found[0];
    } else {
        # Ok. Some guessing.....
	foreach my $clue (@dir) {
        $clue = "$clue.dir";
        foreach my $file (@found) {
            my $parent = dirname($file);
            my $gparent = dirname($parent);
	    if ($gparent =~ m/$clue/) {
                $gcf = $file;
		last;
            }
	    # Skip searching once our clue is usefull 
	    last if defined $gcf;
         }
	}
        # If we cant find based on clue, we'll just pick the first one
        if (not defined $gcf) {
            $gcf = $found[0];
            print "Unable to detect which gcov files to use for $fname. Choosing $gcf\n" if $verbose ;
        }
    }
    if (defined $gcf) {
        print "Found gcov file $gcf\n" if $verbose ;
    } else {
        printReport("Found no gcov file for $fname\n");
	$missing_files{$fname}=1;
    }
    return $gcf;
}

my $report = "";
sub printReport {
    $report .= join('',@_);
    print @_;
}

sub findSource {
    my ($Sandbox) = @_;
    if (defined $Sandbox) {
        my $root= "$Sandbox\/.git";
        if (!-d $root) {
            croak "Failed to find git root ,this tool must be run within a git working tree";
        } else {
            return $Sandbox;
        }
    } else {
        if (-e "CMakeCache.txt") {
            open CACHE, "CMakeCache.txt";
            while (<CACHE>){
                if (m/^MySQL_SOURCE_DIR:STATIC=(.*)$/) {
                    my $dir = $1;
                    if ($verbose) {
                        print "Found source directory at ".$dir."\n";
                    }
                    return $dir;
                }
            }
            close CACHE;
        }   
        findSource("."); # Try current dir
    }
    croak "No source directory found";
}

sub find_uncommitted_changes {
  my $uncom_filemap = {};
  my $cmd;
  $cmd = "$git status -s -uno $sandbox";
  if ($verbose) {
    print "Running: $cmd\n";
  }
  open GIT_STAT, "$cmd |"
      or croak "Failed to spawn '$cmd': $!: $?\n";
  while(<GIT_STAT>) {
    next unless /(A|M)\s+(.*)$/;
    my $file = $2;
    next if ($file =~ /unittest/);
    if ($file =~ $file_regexp)
    {
      printf "Added file %s in revision(s) list\n", $file 
             if $verbose;
      $filemap->{$file} = 1;
    }
    else
    {
      printf "Skipping non source file %s\n", $file
      if $verbose;
         $nosource->{$file}= 1;
    }
  }
  close GIT_STAT
      or croak "Command '$cmd' failed: $!: $?\n";
  return $uncom_filemap;    
}

sub usage {
  print <<'END';
Usage: dgcov --help
       dgcov [options]

Options:

--help        This help.
--verbose     Increase verbosity with 1 (default is 1)
--uncommitted Changes only in staging area that are not being committed.

The dgcov program runs on gcov files for Code Coverage Analysis, and reports 
missing coverage only for those lines that are changed by the specified revision(s).

MySQL source must be compiled with cmake option -DENABLE_GCOV=ON, and the 
testsuite should be run. dgcov will report the coverage for all lines 
modified in the specified commits.

END
exit 1;
}

