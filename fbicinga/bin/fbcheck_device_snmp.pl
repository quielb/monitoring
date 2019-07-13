#!/usr/bin/perl 

use POSIX;
use strict;
use Getopt::Long;

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';

my %ProgramOptions;
ParseOptions();

if( not defined $ProgramOptions{'H'} )
{
   print "UNKNOWN - No host address defined\n";
   exit Monitor::Tools::UNKNOWN;
}
if( not defined $ProgramOptions{'C'} )
{
   print "UNKNOWN - No host community defined\n";
   exit Monitor::Tools::UNKNOWN;
}


my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print "CRITICAL - Cannot connect via SNMP to device\n";
   exit Monitor::Tools::CRITICAL;
}

my $sysDescr = $session->get($snmp_sysDescr);

print "OK - SNMP Reachable: " . substr($sysDescr,0,60) . "....\n";
exit Monitor::Tools::OK;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H=s",
      "C=s"
   );
}

