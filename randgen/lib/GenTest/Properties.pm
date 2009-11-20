package GenTest::Properties;

@ISA = qw(GenTest);

use strict;
use Carp;
use GenTest;
use GenTest::Constants;

use Data::Dumper;

use constant PROPS_NAME => 0;
use constant PROPS_DEFAULTS => 1; ## Default values
use constant PROPS_OPTIONS => 2;  ## Legal options to check for
use constant PROPS_HELP => 3;     ## Help text
use constant PROPS_LEGAL => 4;    ## List of legal properies
use constant PROPS_LEGAL_HASH => 5; ## Hash of legal propertis
use constant PROPS_PROPS => 6;    ## the actual properties

1;

sub AUTOLOAD {
    my $self = shift;
    my $name = our $AUTOLOAD;
    $name =~ s/.*:://;
    
    return unless $name =~ /[^A-Z]/;
    
    if (defined $self->[PROPS_LEGAL]) {
        croak("Illegal property '$name' for ". $self->[PROPS_NAME]) 
            if not $self->[PROPS_LEGAL_HASH]->{$name};
    }
    
    return $self->[PROPS_PROPS]->{$name};
}

sub new {
    my $class = shift;
    
	my $props = $class->SUPER::new({
        'name' => PROPS_NAME,
        'defaults'	=> PROPS_DEFAULTS,
        'options' => PROPS_OPTIONS,
        'legal' => PROPS_LEGAL,
        'help' => PROPS_HELP}, @_);
    
    ## List of legal properties, if no such list, 
    ## all properties are legal
    
    if (defined $props->[PROPS_LEGAL]) {
        foreach my $legal (@{$props->[PROPS_LEGAL]}) {
            $props->[PROPS_LEGAL_HASH]->{$legal}=1;
        }
    }
    
    if (defined $props->[PROPS_OPTIONS]) {
        foreach my $legal (keys %{$props->[PROPS_OPTIONS]}) {
            $props->[PROPS_LEGAL_HASH]->{$legal}=1;
        }
    }
    if (defined $props->[PROPS_DEFAULTS]) {
        foreach my $legal (keys %{$props->[PROPS_DEFAULTS]}) {
            $props->[PROPS_LEGAL_HASH]->{$legal}=1;
        }
    }
    
    my $defaults = $props->[PROPS_DEFAULTS];
    $defaults = {} if not defined $defaults;
    
    my $from_cli = $props->[PROPS_OPTIONS];
    $from_cli = {} if not defined $from_cli;
    
    my $from_file = {};
    
    if ($from_cli->{config}) {
        $from_file = _readProps($from_cli->{config},$props->[PROPS_LEGAL_HASH]);
    }
    
    $props->[PROPS_PROPS] = _mergeProps($defaults, $from_file);
    $props->[PROPS_PROPS] = _mergeProps($props->[PROPS_PROPS], $from_cli);
    
    return $props;
}

sub _readProps {
    my ($file,$legal) = @_;
    open(PFILE, $file) or die "Unable read properties file '$file': $!";
    read(PFILE, my $propfile, -s $file);
    close PFILE;
    my $props = eval($propfile);
    croak "Unable to load $file: $@" if $@;
    my $illegal = 0;
    foreach my $p (keys %$props) {
        if (not $legal->{$p}) {
            carp "'$p' is not a legal property";
            $illegal = 1;
        }
    }
    if ($illegal) {
        croak "Illegal properties";
    }
    return $props;
}

sub _mergeProps {
    my ($a,$b) = @_;
    
    # First recursively deal with hashes
    my $mergedHashes = {};
    foreach my $h (keys %$a) {
        if (UNIVERSAL::isa($a->{$h},"HASH")) {
            if (defined $b->{$h}) {
                $mergedHashes->{$h} = _mergeProps($a->{$h},$b->{$h});
            }
        }
    }
    # The merge
    my $result = {%$a, %$b};
    $result = {%$result,  %$mergedHashes};
    return $result;
}

sub printProps {
    my ($self) = @_;
    _printProps($self->[PROPS_PROPS]);
}

sub _printProps {
    my ($props,$indent) = @_;
    $indent = 1 if not defined $indent;
    my $x = join(" ", map {undef} (1..$indent*3));
    foreach my $p (sort keys %$props) {
        if (UNIVERSAL::isa($props->{$p},"HASH")) {
            say ($x .$p." => ");
            _printProps($props->{$p}, $indent+1);
	} elsif  (UNIVERSAL::isa($props->{$p},"ARRAY")) {
        say ($x .$p." => ['".join("', '",@{$props->{$p}})."']");
        } else {
            say ($x.$p." => ".$props->{$p});
        }
    }
}

sub _purgeProps {
    my ($props) = @_;
    my $purged = {};
    foreach my $key (keys %$props) {
        $purged->{$key} = $props->{$key} if defined $props->{$key};
    }
    return $purged;
}

sub _assertProps {
    my ($props, @list) = @_;
    foreach my $p (@list) {
        croak "Required property '$p' not set" if not exists $props->{$p};
    }
}

sub genOpt {
    my ($self, $prefix, $options) = @_;

    my $hash;
    if (UNIVERSAL::isa($options,"HASH")) {
        $hash = $options;
    } else {
        $hash = $self->$options;
    }
    
    return join(' ', map {$prefix.$_.(defined $hash->{$_}?
                                      ($hash->{$_} eq ''?
                                       '':'='.$hash->{$_}):'')} keys %$hash);
}

1;
