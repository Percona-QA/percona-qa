# Copyright (C) 2009-2010 Sun Microsystems, Inc. All rights reserved.
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
IPC
) }

1;
