package GenTest::XML::Environment;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;


sub new {
	my $class = shift;

	my $environment = $class->SUPER::new({
	}, @_);

	return $environment;
}

sub xml {
	require XML::Writer;

	my $environment = shift;
	my $environment_xml;

	my $writer = XML::Writer->new(
		OUTPUT		=> \$environment_xml,
	);

	$writer->startTag('environments');
	$writer->startTag('environment', 'id' => 0);
	$writer->startTag('hosts');
	$writer->startTag('host');

	$writer->dataElement('name', `hostname`);
	$writer->dataElement('arch', $^O);
	$writer->dataElement('role', 'server');

	# <os>

	# <software>

	$writer->startTag('software');
	$writer->startTag('program');
	$writer->dataElement('name', 'perl');
	$writer->dataElement('version', $^V);
	$writer->dataElement('path', $^X);
	$writer->endTag('program');
	$writer->endTag('software');

	$writer->endTag('host');
	$writer->endTag('hosts');
	$writer->endTag('environment');
	$writer->endTag('environments');

	$writer->end();

	return $environment_xml;	
}

1;
