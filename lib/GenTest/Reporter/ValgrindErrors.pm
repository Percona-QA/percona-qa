# Copyright (c) 2011 Oracle and/or its affiliates. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest::Reporter::ValgrindErrors;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use File::Spec::Functions;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;
use IO::File;

# This reporter looks for valgrind messages in the server error log, and
# prints the messages and returns a failure status if a LEAK SUMMARY or a number
# of valgrind errors are found.
#

sub report {

    my $reporter = shift;

    # Look for error log file
    my $error_log = $reporter->serverInfo('errorlog');
    $error_log = $reporter->serverVariable('log_error') if $error_log eq '';
    if ($error_log eq '') {
        foreach my $file ('../log/master.err', '../mysql.err') {
            my $filename = catfile($reporter->serverVariable('datadir'), $file);
            if (-f $filename) {
                $error_log = $filename;
                last;
            }
        }
    }

    # Open log file and read valgrind messages...
    my $LogFile = IO::File->new($error_log) 
        or say("ERROR: $0 could not read log file '$error_log': $!") 
            && return STATUS_ENVIRONMENT_FAILURE;
    
    my @valgrind_lines;
    my $errorcount = 0;
    my $leak_detected = 0;
    while (my $line = <$LogFile>) {
        push(@valgrind_lines, $line) if $line =~ m{^==[0-9]+==\s+\S};
        if ($line =~ m{^==[0-9]+==\s+ERROR SUMMARY: ([0-9]+) errors}) {
            $errorcount = $1;
        } elsif ($line =~ m{^==[0-9]+==\s+LEAK SUMMARY:}) {
            # we assume that LEAK SUMMARY may be present even without errors
            say("Valgrind: Possible memory leak detected");
            $leak_detected = 1;
        }
    }

    if (($errorcount > 0) or $leak_detected) {
        say("Valgrind: Issues detected (errors: $errorcount). Relevant messages from log file '$error_log':");
        foreach my $line (@valgrind_lines) {
            say($line);
        }
        return STATUS_VALGRIND_FAILURE
    } else {
        say("Valgrind: No issues found in file '$error_log'.");
        return STATUS_OK;
    }
}

sub type {
    return REPORTER_TYPE_ALWAYS ;
}

1;
