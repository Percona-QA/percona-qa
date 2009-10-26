# Do a simple run of scripts to see that they're sound
#
package TestScripts;
use base qw(Test::Unit::TestCase);
use lib 'lib';

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

my $generator;
sub set_up {
}

sub tear_down {
    # clean up after test
}

sub test_gensql {
    my $self = shift;

    my $status = system("perl gensql.pl --grammar=conf/example.yy --dsn=dummy --queries=1");

    $self->assert_equals(0, $status);
}

sub test_gendata {
    my $self = shift;

    my $status = system("perl gendata.pl --config=conf/example.zz --dsn=dummy");

    $self->assert_equals(0, $status);
}

sub test_gendata_old {
    my $self = shift;

    my $status = system("perl gendata-old.pl --dsn=dummy");

    $self->assert_equals(0, $status);
}

sub test_gentest {
    my $self = shift;

    my $status = system("perl gentest.pl --dsn=dummy --grammar=conf/example.yy --threads=1 --queries=1");

    $self->assert_equals(0, $status);

    $status = system("perl gentest.pl --dsn=dummy --grammar=conf/example.yy --threads=1 --queries=1 --mask=10 --mask-level=2");

    $self->assert_equals(0, $status);
}


1;
