package GenTest::XML::Environment;

require Exporter;
@ISA = qw(GenTest);

use strict;
use Carp;
use GenTest;
use Net::Domain qw(hostfqdn);

# Global variables keeping environment info
our $hostname = Net::Domain->hostfqdn();
our $arch;
our $kernel;
our $bit;
our $cpu;
our $memory;
#our $disk;
our $role = 'server';
our $locale;
our $encoding;
our $timezone;
our $osType;
our $osVer;
our $osRev;
our $osBit;


our $DEBUG=0;

sub new {
    my $class = shift;

    my $environment = $class->SUPER::new({
    }, @_);

    return $environment;
}

sub xml {
    require XML::Writer;

    # Obtain environmental info from host.
    # In separate function because lots of logic is needed to parse various
    # information based on the OS.
    getInfo();

    my $environment = shift;
    my $environment_xml;

    my $writer = XML::Writer->new(
        OUTPUT      => \$environment_xml,
    );

    $writer->startTag('environments');
    $writer->startTag('environment', 'id' => 0);
    $writer->startTag('hosts');
    $writer->startTag('host');

    # Some elements may be empty either because
    #  a) we don't know that piece of information
    #  b) values are fetched from a database of test hosts
    $writer->dataElement('name', $hostname);
    $writer->dataElement('arch', $arch);
    $writer->dataElement('kernel', $kernel);
    $writer->dataElement('bit', $bit) if defined $bit;
    $writer->dataElement('cpu', $cpu);
    $writer->dataElement('memory', $memory);
    $writer->dataElement('disk', '');
    $writer->dataElement('role', $role);
    $writer->dataElement('locale', $locale);
    $writer->dataElement('encoding', $encoding);
    $writer->dataElement('timezone', $timezone);

    # <software> ...
    $writer->startTag('software');

    # <os>
    $writer->startTag('program');
    $writer->dataElement('name', $osType);
    $writer->dataElement('type', 'os');
    $writer->dataElement('version', $osVer);
    $writer->dataElement('revision', $osRev);
    $writer->dataElement('bit', $osBit);
    $writer->endTag('program');

    # <perl>
    $writer->startTag('program');
    $writer->dataElement('name', 'perl');
    #$writer->dataElement('version', $^V); # Solaris yields: Code point \u0005 is not a valid character in XML at lib/GenTest/XML/Environment.pm line 45
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

sub getInfo()
{

    # lets see what OS type we have
    if ($^O eq 'linux')
    {
        
        # Get the CPU info
        $cpu = trim(`cat /proc/cpuinfo | grep -i "model name" | head -n 1 | cut -b 14-`);
        my $numOfP = trim(`cat /proc/cpuinfo | grep processor |wc -l`);
        $cpu ="$numOfP"."x"."$cpu";

        #try to get OS Information
        if (-e "/etc/SuSE-release"){$osVer=`cat /etc/SuSE-release  |head -n 1`;}
        elsif (-e "/etc/redhat-release"){$osVer=`cat /etc/redhat-release  |head -n 1`;}
        elsif (-e "/etc/debian_version"){$osVer=`cat /etc/debian_version  |head -n 1`;}
        else {$osVer="linux-unknown";}
        $osVer=trim($osVer);
        if (-e "/etc/SuSE-release"){$osRev=`cat /etc/SuSE-release  |tail -n 1`;}
        elsif (-e "/etc/redhat-release"){$osRev=`cat /etc/redhat-release  |tail -n 1`;}
        elsif (-e "/etc/debian_version"){$osRev=`cat /etc/debian_version  |tail -n 1`;}
        else {$osRev="unknown";}
        (my $trash, $osRev) = split(/=/,$osRev);
        $osType="Linux";
        $arch=trim(`uname -m`);
        ($trash, $bit) = split(/_/,$arch);
        $kernel=trim(`uname -r`);

        #Memory
        $memory = trim(`cat /proc/meminfo | grep -i memtotal`);
        $memory =~ s/MemTotal: //;
        ($memory, $trash) =  split(/k/,$memory);
        $memory = trim(`cat /proc/meminfo |grep -i memtotal`);
        $memory =~ /MemTotal:\s*(\d+)/;
        $memory = sprintf("%.2f",($1/1024000))."GB";

        #locale
        if (defined ($locale=`locale |grep LC_CTYPE| cut -b 10-`))
        {
            ($locale,$encoding) = split(/\./,$locale);
        }
        else
        {
            $locale   = "UNKNOWN";
            $encoding = "UNKNOWN";
        }

        #TimeZone
        $timezone = trim(`date +%Z`);
    }
    elsif($^O eq 'solaris')
    {
        
        # Get the CPU info
        my $tmpVar = `/usr/sbin/psrinfo -v | grep -i "operates" | head -1`;
        ($cpu, my $speed) = split(/processor operates at/,$tmpVar);
        $cpu =~ s/The//;
        $speed =~ s/MHz//;
        $cpu = trim($cpu);
        $speed = trim($speed);
        if ($speed => 1000)
        {
            $speed = $speed/1000;
            $speed = "$speed"."GHz";
        }
        else
        {
            $speed = "$speed"."MHz";
        }

        my $numOfP = `/usr/sbin/psrinfo -v | grep -i "operates" |wc -l`;
        $numOfP = trim($numOfP);
        $cpu ="$numOfP"."x"."$cpu"."$speed";

        #try to get OS Information
        ($osType,$osVer,$arch) = split (/ /, trim(`uname -srp`));
        # use of uname -m is discouraged (man pages), so use isainfo instead
        $kernel = `isainfo -k`;
        $osBit = `isainfo -b`;
        my $trash; # variable functioning as /dev/null
        ($trash, $trash, my $osRev1, my $osRev2, $trash) = split(/ /, trim(`cat /etc/release | head -1`));
        my $osRev3 = `uname -v`;
        $osRev = $osRev1.' '.$osRev2.' '.$osRev3;

        #Memory
        $memory = `/usr/sbin/prtconf | grep Memory`;
        $memory =~ s/Memory size://;
        $memory =~ s/Megabytes//;
        $memory = trim($memory);
        $memory = $memory/1024;
        ($memory, my $trash) = split(/\./,$memory);
        $memory = "$memory"."GB";

        #locale
        if (defined ($locale=`locale |grep LC_CTYPE| cut -b 10-`))
        {
            ($locale,$encoding) = split(/\./,$locale);
        }
        else
        {
            $locale   = "UNKNOWN";
            $encoding = "UNKNOWN";
        }

        #TimeZone
        $timezone = trim(`date +%Z`);
    }
    elsif($^O eq 'cygwin' || $^O eq 'MSWin32' || $^O eq 'MSWin64')
    {
        #$hostName = `hostname`;
        my @tmpData;
        if ($^O eq 'cygwin')
        {
            # Assuming cygwin on Windows at this point
            @tmpData = `cmd /c systeminfo 2>&1`;
        }
        else
        {
            # Assuming Windows at this point
            @tmpData = `systeminfo 2>&1`;
        }

        if ($? != 0)
        {
            carp "systeminfo command failed with: $?";
            $cpu        = "UNKNOWN";
            $osType     = "UNKNOWN";
            $osVer      = "UNKNOWN";
            $arch       = "UNKNOWN";
            $kernel     = "UNKNOWN";
            $memory     = "UNKNOWN";
            $locale     = "UNKNOWN";
            $timezone   = "UNKNOWN";
        }
        else
        {
            $kernel = "UNKOWN";
            my $cpuFlag = 0;
            # Time to get busy and grab what we need.
            foreach my $line (@tmpData)
            {
                if ($cpuFlag == 1)
                {
                    (my $numP, $cpu) = split(/\:/,$line);
                    $numP = trim($numP);
                    (my $trash, $numP) = split(/\[/,$numP);
                    ($numP, $trash) = split(/\]/,$numP);
                    $cpu = "$numP"."$cpu";
                    $cpu = trim($cpu);
                    $cpuFlag=0;
                }
                elsif ($line =~ /OS Name:\s+(.*?)\s*$/)
                {
                    $osType = $1;
                }
                elsif ($line =~ /^OS Version:\s+(.*?)\s*$/)
                {
                    $osVer = $1;
                }
                elsif ($line =~ /System type:\s/i)
                {
                    (my $trash, $arch) = split(/\:/,$line);
                    ($arch,$trash) = split(/\-/,$arch);
                    $arch = trim($arch);
                }
                elsif ($line =~ /^Processor/)
                {
                    $cpuFlag = 1;
                    next;
                }
                elsif ($line =~ /^Total Physical Memory:\s+(.*?)\s*$/)
                {
                    $memory = $1;
                }
                elsif ($line =~ /Locale:/)
                {
                    (my $trash, $locale) = split(/\:/,$line);
                    ($locale, $trash) = split(/\;/,$locale);
                    $locale = trim($locale);
                }
                elsif ($line =~ /Time Zone:\s+(.*?)\s*$/)
                {
                    $timezone = $1;
                }
            }
        }
    }
    else
    {
        confess "\n\nUnable to figure out OS!!\n\n";
    }

    if ($DEBUG)
    {
        print "cpu      = $cpu\n";
        print "os       =  $osType\n";
        print "OS ver   = $osVer\n";
        print "Arch     = $arch\n";
        print "Kernel   = $kernel\n";
        print "memory   = $memory\n";
        print "locale   = $locale\n";
        print "Timezone = $timezone\n";
    }
}

sub trim($)
{
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

1;
