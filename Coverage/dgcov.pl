#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use File::Find;
use Cwd 'realpath';
use File::Basename;
use Carp;

# Arguments
my $help;
my $verbose;
my $source=undef;
my $uncommitted;
my $changedlines = 0;

my $options = GetOptions
  (
   "verbose"     => \$verbose,
   "help"        => \$help,
   "uncommitted" => \$uncommitted,
   "source=s"    => \$source,
  );

if (not $options) {
    print "Use --help for usage\n";
    exit 1;
}

usage() if $help;

# Variables

my $file_regexp= qr/\.(c|cc|cpp|h|hpp|i|ic)$/;
my $filemap = {};
my $nosourcemap = {};
my $uncommitt_filemap = {};
my $committ_filemap = {};
my $nosource = {};
my %missing_files;
my $uncovered = 0;
my $instrumented = 0;
my @revisions;
my $annotation; 
my ($revid1, $revid2);
my $git = "git";

# Main

print("----- Start of report ----- \n");

# Find source location to run the scrip from.
$source = findSource($source);

# Staged/Working changes only.
if($uncommitted) {
  my $cmd = "$git status -s -uno $source";
  find_changes($cmd);
  foreach my $file (keys %$filemap) {
    $uncommitt_filemap->{$file} = get_diff_lines($file);
  }
} else {
# Add revisions present in this snapshot only.
my $cmd = "$git rev-list HEAD ^origin --first-parent --topo-order";
print "Running: $cmd\n"
   if $verbose;
for $_ (`$cmd`) {
    chomp($_);
    push @revisions, $_;
    print("Added revision $_\n")
      if $verbose;
    }
    if ($#revisions < 0) {
        print("No local revisions in $source\n");
        print("----- End of dgcov.pl report ----- \n");
        exit 0;
    }
# Find revisions included in the list of revisions.
$revid1= $revisions[0];
$revid2= $revisions[$#revisions];
my $ncmd = "$git diff ";
$ncmd.= "$revid2~..$revid1 ";
$ncmd.= "--name-status --oneline --diff-filter=\"AM\" --pretty=\"%H\" ";
find_changes($ncmd);
foreach my $file (keys %$filemap) {
    $committ_filemap->{$file} = get_diff_lines($file);
}
}

for my $file (sort keys %$filemap) {
  my $lines = [ ];

  $lines = get_cov_lines($uncommitt_filemap->{$file})
  if (exists $uncommitt_filemap->{$file} and $uncommitted);
  $lines = get_cov_lines($committ_filemap->{$file})
  if (exists $committ_filemap->{$file} and (not $uncommitted) );

  # All lines in revision(s) changed.
  $changedlines = $changedlines + scalar @$lines;
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
          check_purecov($code, $gcov_file, $lineno);

	  foreach (@$lines) {
	  if ($lineno eq $_ and $cov =~/#####/) {
	       $uncovered++;
	       $instrumented++;
	       $printer->("|$full");
	  } elsif ($lineno eq $_ and $cov =~ /^[ \t]*[0-9]+$/ ) {
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
    # Seperate dir and filename
    my $dir = dirname($fname);
    my @dir = split('/', $dir);
    # Special case
    my @cmake_dir = ("sql_main","sql_dd","sql_gis");
    @dir = (@dir, @cmake_dir) if ( grep(/^sql$/, @dir) );
    @dir = reverse @dir;
    my $file = basename($fname);
 
    my @found;
    print "Looking for gcov files for $fname\n" if $verbose;
    my $gcov_file = "$file.gcno";
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
            my $fpath = dirname($file);
	    my @parents = split('/',$fpath);
	    foreach my $parent (@parents) {
	    if ($parent =~ m/^$clue$/) {
                $gcf = $file;
		last;
            }
   	    }
	    # Skip searching once our clue is usefull 
	    last if defined $gcf;
         }
	last if defined $gcf;
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
    my ($Source) = @_;
    if (defined $Source) {
        my $root = "$Source\/.git";
        if (!-d $root) {
            croak "Failed to find git root, this tool must be run within a git working tree";
        } else {
            return $Source;
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

sub find_changes {
  my ($cmd) = @_;
  print "Running: $cmd\n"
    if $verbose;
  open GIT_CMD, "$cmd |"
      or croak "Failed to spawn '$cmd': $!: $?\n";
  while(<GIT_CMD>) {
    next unless /(A|M)\s+(.*)$/;
    my $file = $2;
    $file = realpath($file) if $uncommitted;
    $file = $source."/".$file if not $uncommitted;
    next if ($file =~ /unittest/);
    if ($file =~ $file_regexp)
    {
      printf "Added file %s\n", $file
      if $verbose and (not exists $filemap->{$file});
      $filemap->{$file} = 1 if (not exists $filemap->{$file});
    }
    else
    {
      printf "Skipping non source file %s\n", $file
      if $verbose;
         $nosourcemap->{$file} = 1;
    }
  }
  close GIT_CMD
      or croak "Command '$cmd' failed: $!: $?\n";
}

sub get_diff_lines {
      my ($file) = @_;
      my $modified = [ ];
      my $cmd = "$git diff -U0 ";
      if (not $uncommitted) {
         $cmd .= "$revid2~..$revid1 ";
      }
      $cmd .= "$file";
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
      $to=$to-1 if ($from!=$to);
      push @$new_lines, ($from..$to);
    } else {
      croak "Unable to get coverage info lines";
    }
  }
  return $new_lines;
}

sub check_purecov
{
  my $code = $_[0];
  my $fname = $_[1];
  my $lineno = $_[2];
  # Check for source annotation are in line/block for inspected/dead/tested code.
  if($code =~ m{/\*[\s\t]+purecov[\s\t]*:[\s\t]*(inspected|tested|deadcode)[\s\t]+\*/})
  {
    $annotation = 'LINE';
  } elsif($code =~ m{/\*[\s\t]+purecov[\s\t]*:[\s\t]*begin[\s\t]+(inspected|tested|deadcode)[\s\t]+\*/}) {
    $annotation = 'BLOCK';
  } elsif($code =~ m{/\*[\s\t]+purecov[\s\t]*:[ \t]*end[\s\t]+\*/}) {
    carp "Warning: Found /* purecov: end */ annotation ".
         "not matched by any begin.\n".
         " at line $lineno in '$fname'.\n"
      unless defined($annotation) && $annotation eq 'BLOCK';
    $annotation= undef;
  } else {
    $annotation = undef if defined($annotation) && $annotation eq 'LINE';
  }
}

sub usage {
  print <<'END';
Usage: dgcov --help
       dgcov [options]
Options:

--help        Display script usage information.
--verbose     Show execution command outputs by setting verbosity.
--uncommitted Changes only in working area that havent being committed.
--source      Git Source/Root directory location.

The dgcov program runs on gcov files for Code Coverage Analysis, and reports 
missing coverage only for those lines that are changed by the specified revision(s).

MySQL source must be compiled with cmake option -DENABLE_GCOV=ON, and the 
testsuite should be run. Program dgcov will report the coverage for all lines 
modified in the specified commits.

END
exit 1;
}
