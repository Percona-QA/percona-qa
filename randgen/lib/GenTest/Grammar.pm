package GenTest::Grammar;

require Exporter;
@ISA = qw(GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar::Rule;

use constant GRAMMAR_RULES	=> 0;
use constant GRAMMAR_FILE	=> 1;
use constant GRAMMAR_STRING	=> 2;

1;

sub new {
	my $class = shift;


	my $grammar = $class->SUPER::new({
		'grammar_file'          => GRAMMAR_FILE,
		'grammar_string'        => GRAMMAR_STRING
	}, @_);

        $grammar->[GRAMMAR_RULES] = {} if not defined $grammar->rules();

	if (defined $grammar->file()) {
		my $parse_result = $grammar->parseFromFile($grammar->file());
		return undef if $parse_result > STATUS_OK;
	}

	if (defined $grammar->string()) {
		my $parse_result = $grammar->parseFromString($grammar->string());
		return undef if $parse_result > STATUS_OK;
	}

	return $grammar;
}

sub file {
	return $_[0]->[GRAMMAR_FILE];
}

sub string {
	return $_[0]->[GRAMMAR_STRING];
}


sub toString {
	my $grammar = shift;
	my $rules = $grammar->rules();
	return join("\n\n", map { $grammar->rule($_)->toString() } sort keys %$rules);
}


sub parseFromFile {
	my ($grammar, $grammar_file) = @_;

	open (GF, $grammar_file) or die "Unable to open() grammar $grammar_file: $!";
	read (GF, my $grammar_string, -s $grammar_file) or die "Unable to read() $grammar_file: $!";

	return $grammar->parseFromString($grammar_string);
}

sub parseFromString {
	my ($grammar, $grammar_string) = @_;

	#
	# provide an #include directive 
	#

	while ($grammar_string =~ s{#include [<"](.*?)[>"]$}{
		{
			my $include_string;
			my $include_file = $1;
		        open (IF, $1) or die "Unable to open include file $include_file: $!";
		        read (IF, my $include_string, -s $include_file) or die "Unable to open $include_file: $!";
			$include_string;
	}}mie) {};

	# Strip comments. Note that this is not Perl-code safe, since perl fragments 
	# can contain both comments with # and the $# expression. A proper lexer will fix this
	
	$grammar_string =~ s{#.*$}{}iomg;

	# Join lines ending in \

	$grammar_string =~ s{\\$}{ }iomg;

	# Strip end-line whitespace

	$grammar_string =~ s{\s+$}{}iomg;

	# Add terminating \n to ease parsing

	$grammar_string = $grammar_string."\n";

	my @rule_strings = split (";\s*[\r\n]+", $grammar_string);

	my %rules;

	foreach my $rule_string (@rule_strings) {
		my ($rule_name, $components_string) = $rule_string =~ m{^(.*?):(.*)$}sio;
		$rule_name =~ s{[\r\n]}{}gsio;
		$rule_name =~ s{^\s*}{}gsio;

		next if $rule_name eq '';

		if (exists $rules{$rule_name}) {
			say("Rule $rule_name is defined twice.");
			return STATUS_ENVIRONMENT_FAILURE;
		}

		my @component_strings = split (m{\|}, $components_string);
		my @components;
		foreach my $component_strings (@component_strings) {
			# Remove leading whitespace
			$component_strings =~ s{^\s+}{}sgio;
			$component_strings =~ s{\s+$}{}sgio;
		
			# Rempove repeating whitespaces
			$component_strings =~ s{\s+}{ }sgio;

			# Split this so that each identifier is separated from all syntax elements
			# The identifier can start with a lowercase letter or an underscore , plus quotes

			$component_strings =~ s{([_a-z0-9'"`\{\}\$]+)}{|$1|}sgo;

			# Revert overzealous splitting that splits things like _varchar(32) into several tokens
		
			$component_strings =~ s{([a-z0-9_]+)\|\(\|(\d+)\|\)}{$1($2)|}sgo;

			# Remove leading and trailing pipes
			$component_strings =~ s{^\|}{}sgio;
			$component_strings =~ s{\|$}{}sgio;

			my @component_parts = split (m{\|}, $component_strings);

			#
			# If this grammar rule contains Perl code, assemble it between the various
			# component parts it was split into. This "reconstructive" step is definitely bad design
			# The way to do it properly would be to tokenize the grammar using a full-blown lexer
			# which should hopefully come up in a future version.
			#

			my $nesting_level = 0;
			my $pos = 0;
			my $code_start;

			while (1) {
				if ($component_parts[$pos] =~ m{\{}so) {
					$code_start = $pos if $nesting_level == 0;	# Code segment starts here
					my $bracket_count = ($component_parts[$pos] =~ tr/{//);
					$nesting_level = $nesting_level + $bracket_count;
				}
				
				if ($component_parts[$pos] =~ m{\}}so) {
					my $bracket_count = ($component_parts[$pos] =~ tr/}//);
					$nesting_level = $nesting_level - $bracket_count;
					if ($nesting_level == 0) {
						# Resemble the entire Perl code segment into a single string
						splice(@component_parts, $code_start, ($pos - $code_start + 1) , join ('', @component_parts[$code_start..$pos]));
						$pos = $code_start + 1;
						$code_start = undef;
					}
				}
				last if $pos > $#component_parts;
				$pos++;
			}

			push @components, \@component_parts;
		}

		my $rule = GenTest::Grammar::Rule->new(
			name => $rule_name,
			components => \@components
		);
		$rules{$rule_name} = $rule;
	}

	$grammar->[GRAMMAR_RULES] = \%rules;
	return STATUS_OK;
}

sub rule {
	return $_[0]->[GRAMMAR_RULES]->{$_[1]};
}

sub rules {
	return $_[0]->[GRAMMAR_RULES];
}

sub deleteRule {
	delete $_[0]->[GRAMMAR_RULES]->{$_[1]};
}

1;
