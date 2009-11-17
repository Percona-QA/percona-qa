package GenTest::XML::Report;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;
use GenTest::XML::BuildInfo;
use GenTest::XML::Environment;

#
# Those names are taken from Vemundo's specification for a 
# test result XML report. Not all of them will be used
#

use constant XMLREPORT_DATE			=> 0;
use constant XMLREPORT_BUILDINFO		=> 1;
use constant XMLREPORT_TESTS			=> 2;
use constant XMLREPORT_ENVIRONMENT		=> 3;

1;

sub new {
	my $class = shift;

	my $report = $class->SUPER::new({
		environment	=> XMLREPORT_ENVIRONMENT,
		date		=> XMLREPORT_DATE,
		buildinfo	=> XMLREPORT_BUILDINFO,
		tests		=> XMLREPORT_TESTS
	}, @_);

	$report->[XMLREPORT_DATE] = xml_timestamp() if not defined $report->[XMLREPORT_DATE];
	$report->[XMLREPORT_ENVIRONMENT] = GenTest::XML::Environment->new() if not defined  $report->[XMLREPORT_ENVIRONMENT];

	return $report;
}

sub xml {
	my $report = shift;

	require XML::Writer;

	my $report_xml;

	my $writer = XML::Writer->new(
		OUTPUT		=> \$report_xml,
		UNSAFE		=> 1	# required for use of 'raw()'
	);

	$writer->xmlDecl('ISO-8859-1');
	$writer->startTag('report',
		'xmlns'			=> "http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia",
		'xmlns:xsi'		=> "http://www.w3.org/2001/XMLSchema-instance",
		'xsi:schemaLocation'	=> "http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia/testresult-schema-1-2.xsd",
		'version'		=> "1.2"
	);
	
	$writer->dataElement('date', $report->[XMLREPORT_DATE]);
	if ($^O eq 'linux' || $^O eq 'solaris')
	{
	  $writer->dataElement('operator', $ENV{'LOGNAME'});
	}
	else
	{
	  $writer->dataElement('operator', $ENV{'USERNAME'});
	}

	$writer->raw($report->[XMLREPORT_ENVIRONMENT]->xml()) if defined $report->[XMLREPORT_BUILDINFO];
	$writer->raw($report->[XMLREPORT_BUILDINFO]->xml()) if defined $report->[XMLREPORT_BUILDINFO];

	$writer->startTag('testsuites');
	$writer->startTag('testsuite', id => 0);
	$writer->dataElement('name', 'Random Query Generator');
	$writer->dataElement('environment_id', 0);
	$writer->dataElement('starttime', $report->[XMLREPORT_DATE]);
	$writer->dataElement('endtime', xml_timestamp());
	$writer->dataElement('description', 'http://forge.mysql.com/wiki/RQG');
	$writer->startTag('tests');

	foreach my $test (@{$report->[XMLREPORT_TESTS]}) {
		$writer->raw($test->xml());
	}

	$writer->endTag('tests');
	$writer->endTag('testsuite');
	$writer->endTag('testsuites');
	$writer->endTag('report');

	$writer->end();

	return $report_xml;
}

1;
