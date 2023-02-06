#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use File::Find;
use File::Basename;
use Carp;
use Data::Dumper;

my $help;
my $verbose;
my $sandbox;
my $uncommitted;

# Main

my $options = GetOptions
  (
   "verbose"    => \$verbose,
   "help"       => \$help,
   "uncommitted" => \$uncommitted,
  );

   
if (not $options) {
    print "Use --help for usage\n";
    exit 1;
}

usage() if $help;

my $file_regexp= qr/\.(c|cc|cpp|h|hpp|i|ic)$/;
my $filemap = {};
my $uncommitt_filemap = {};
my $nosource = {};
my %missing_files;
my $uncovered = 0;
my $instrumented = 0;
my $git = "git";

print("----- Start of report ----- \n");

# Find source location to run the scrip from.
$sandbox = findSource($sandbox);

# Staged changes only.
if($uncommitted) {
  $uncommitt_filemap = find_uncommitted_changes();
}

for my $file (sort keys %$filemap) {

  my $lines = [ ];
  $lines = get_cov_lines($uncommitt_filemap->{$file})
  if $uncommitt_filemap->{$file};
  next unless @$lines; 
  my $gcov_file = findGcov($file);
  if (defined $gcov_file) {
      print "Using Gcov file $gcov_file for $file\n";
      my $gcov_dir = dirname($gcov_file);

      my $res = open FH, '<', $gcov_file;
      if(!$res) {
          carp "Failed to open gcov output file '$gcov_file'\n";
          $missing_files{$gcov_file}=1;
          next;
      }

      my ($cov, $lineno, $code, $full);
      my $header = undef;

      my $printer = sub {
          unless($header) {
              print("\nFile: $file\n", '-' x 79, "\n");
              $header = 1;
          }
          print($_[0]);
      };

      while(<FH>) {
          next if /^function /; # Skip function summaries.
	  next if (/^-------/) or (/^_ZN*/); # TODO :: Handle embedded constructor calls.
          croak "Unexpected line '$_'\n in $gcov_file"
               unless /^([^:]+):[ \t]*(\d+):(.*)$/;
          ($cov, $lineno, $code, $full) = ($1, $2, $3, $_);

	  foreach (@$lines) {
	  if ($lineno eq $_ and $cov =~/#####/) {
	       $uncovered++;
	       $instrumented++;
	       $printer->("|$full");
	  } elsif ($lineno eq $_ and $cov =~ /^[ \t]*\d+$/ ) {
	       $instrumented++;
  	  }
          }
  }
  close FH;
 }  
}

print('-' x 79, "\n\n");
print("$instrumented modified line(s) instrumented.\n");
if ($instrumented != 0) {
    print("$uncovered modified and instrumented line(s) not covered by tests.\n");
    printf("Line Coverage is %.2f%% of modified code.\n\n", (($instrumented-$uncovered)/$instrumented * 100));
}
print("----- End of report ----- \n");

exit 0;

# Subroutines

sub findGcov {
    my ($fname) = @_;
    # Seperate dir and filename.
    my $dir = dirname($fname);
    my @dir = split('/', $dir);
    @dir = reverse @dir;
    my $file = basename($fname);
 
    my @found;
    print "Looking for gcov files for $fname\n" if $verbose;
    my $gcov_file = "$file.gcda";
    find(sub {
	if ($_ eq $gcov_file && -e $gcov_file) {
	   push @found, $File::Find::dir."/".$file.".gcov";
	}
        },
        ".");

    my $gcf = undef;
    if ($#found < 0) {
        # None found
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
        if (not defined $gcf && ($#found >= 0)) {
            $gcf = $found[0];
	    print "Unable to detect which gcov files to use for $fname. Choosing $gcf\n" if $verbose ;
        }
    }
    if (defined $gcf && -e $gcf) {
        print "Found gcov file $gcf\n" if $verbose ;
  	return $gcf;
    } else {
        print "Found no gcov file for $fname\n" if $verbose;
	$missing_files{$fname}=1;
  	return;
    }
}

sub findSource {
    my ($Sandbox) = @_;
    if (defined $Sandbox) {
        my $root = "$Sandbox\/.git";
        if (!-d $root) {
            croak "Failed to find git root, this tool must be run within a git working tree";
        } else {
            return $Sandbox;
        }
    } else {
        if (-e "CMakeCache.txt") {
            open CACHE, "CMakeCache.txt";
            while (<CACHE>){
                if (m/^MySQL_SOURCE_DIR:STATIC=(.*)$/) {
                    my $dir = $1;
                    print "Found source directory at ".$dir."\n" if $verbose;
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
  my $cmd;
  $cmd = "$git status -s -uno $sandbox";
  print "Running: $cmd\n"
    if $verbose;
  open GIT_STAT, "$cmd |"
      or croak "Failed to spawn '$cmd': $!: $?\n";
  while(<GIT_STAT>) {
    next unless /(A|M)\s+(.*)$/;
    my $file = $2;
    next if ($file =~ /unittest/);
    if ($file =~ $file_regexp)
    {
      printf "File %s added in revision(s) list\n", $file 
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

  my $uncom_filemap = {};
  foreach my $file (keys %$filemap) {
    $uncom_filemap->{$file} = get_diff_changes($file);
  }
  return $uncom_filemap;    
}

sub get_diff_changes {
      my ($file) = @_;
      my $modified = [ ];
      my $cmd = "$git diff -U0 $sandbox\/$file";	
      print "Running: $cmd\n"
            if $verbose;
      open GIT_DIFF, "$cmd |"
           or croak "Failed to spawn '$cmd': $!: $?\n";
      while(<GIT_DIFF>) {
           if(/^@@\s[+-](\d+),(\d+)\s[+-](\d+),(\d+)\s@@$/) {
             push @$modified, [m => $3, $3+$4];
           } elsif(/^@@\s[+-](\d+)\s[+-](\d+),(\d+)\s@@$/) {
             push @$modified, [m => $2, $2+$3];
           } elsif(/^@@\s[+-](\d+),(\d+)\s[+-](\d+)\s@@$/) {
             push @$modified, [m => $3, $3];
           } elsif(/^@@\s[+-](\d+)\s[+-](\d+)\s@@$/) {
             push @$modified, [m => $2, $2];
	   } elsif(/^@@\s/) {
	     # Ignore diffs with 0 lines changed.
           } elsif(/^[ +-]|^$/) {
             # We are not interested in the diff content.
           } elsif(/^(---|\+\+\+) ./) {
             # Ignore file names.
           } elsif(/^diff.*git.*/) {
             # Ignore diff --git line.
           } elsif(/^index.*/) {
             # Ignore Index line.
           } else {
	     chomp $_;
             carp "Unexpected line $_ in file $file\n";
           }
     }
     close GIT_DIFF
          or croak "Command '$cmd' failed: $!: $?\n";
     return $modified;
}

sub get_cov_lines {
  my ($content) = @_;
  my $new_lines = [ ];
  for my $elements (@$content) {
    my $type = shift @$elements;
     if($type eq 'm') {
      my ($from, $to) = @$elements;
      push @$new_lines, ($from .. $to);
    } else {
      croak "Unable to get coverage info lines";
    }
  }
  return $new_lines;
}

sub usage {
  print <<'END';
Usage: dgcov --help
       dgcov [options]
Options:

--help        Display script usage information.
--verbose     Show command outputs by setting verbosity with 1.
--uncommitted Changes only in staging area that are not being committed.

The dgcov program runs on gcov files for Code Coverage Analysis, and reports 
missing coverage only for those lines that are changed by the specified revision(s).

MySQL source must be compiled with cmake option -DENABLE_GCOV=ON, and the 
testsuite should be run. Program dgcov will report the coverage for all lines 
modified in the specified commits.

END
exit 1;
}
