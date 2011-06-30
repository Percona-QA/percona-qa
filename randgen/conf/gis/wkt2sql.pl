# This script can be used to load the files from
# http://www.tm.kit.edu/~mayer/osm2wkt/ 
# into MySQL and PostGIS

use strict;

print "
/*

@MISC{mayer2010osm,
  author = {Christoph P. Mayer},
  title = {osm2wkt - OpenStreetMap to WKT Conversion},
  howpublished = {http://www.tm.kit.edu/~mayer/osm2wkt},
  year = {2010}
} 

Map data (c) OpenStreetMap contributors, CC-BY-SA

*/";

print "DROP TABLE IF EXISTS linestring;\n";

if ($ARGV[0] eq 'MySQL') {
	print "CREATE TABLE linestring (pk INTEGER NOT NULL PRIMARY KEY, linestring_key LINESTRING NOT NULL, linestring_nokey LINESTRING NOT NULL) ENGINE=Aria TRANSACTIONAL=0;\n";
} elsif ($ARGV[0] eq 'PostGIS') {
	print "CREATE TABLE lineSTRING (pk INTEGER NOT NULL PRIMARY KEY);\n";
	print "SELECT AddGeometryColumn('linestring', 'linestring_key', -1, 'LINESTRING', 2 );\n";
	print "SELECT AddGeometryColumn('linestring', 'linestring_nokey', -1, 'LINESTRING', 2 );\n";
}

my $counter = 1;
while (<STDIN>) {
	chomp $_;
	print "INSERT INTO linestring (pk, linestring_key, linestring_nokey) VALUES ($counter, GeomFromText('$_'), GeomFromText('$_'));\n";
	$counter++;
}

if ($ARGV[0] eq 'MySQL') {
	print "ALTER TABLE linestring ADD SPATIAL KEY (linestring_key);\n";
} elsif ($ARGV[0] eq 'MySQL')  {
	print "CREATE INDEX linestring_index ON linestring USING GIST ( linestring_key );\n";
}
