#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_ifDescr = '.1.3.6.1.2.1.2.2.1.2';
my $snmp_ifAdminStatus = '.1.3.6.1.2.1.2.2.1.7';
my $snmp_ifOperStatus = '.1.3.6.1.2.1.2.2.1.8';
my $snmp_ifLastChange = '.1.3.6.1.2.1.2.2.1.9';

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my %Poll_OID = ( 'ifDescr' => $snmp_ifDescr, 'ifAdminStatus' => $snmp_ifAdminStatus, 'ifOperStatus' => $snmp_ifOperStatus );
my %Poll_Data;

### Collect all the data for an interface.  Did this in a loop to be compact and clean.  If there
### is a problem with any of the SNMP gets it will return UNKNOWN and exit.
foreach my $key ( keys %Poll_OID )
{
   $Poll_Data{$key} = $session->get("$Poll_OID{$key}.$ProgramOptions{'ifindex'}");
   if( not defined($Poll_Data{$key}) )
   {
      print "UNKNOWN - Unable to poll $key\n";
      print $Monitor::Tools::snmp_cli . " $Poll_OID{$key}.$ProgramOptions{'ifindex'}" . "\n";
      exit Monitor::Tools::UNKNOWN;
   }
   if( $Poll_Data{$key} =~ /NOSUCH/ )
   {
      print "UNKNOWN - No interface found for given ifIndex $ProgramOptions{'ifindex'}\n";
      print $Monitor::Tools::snmp_cli . " $Poll_OID{$key}.$ProgramOptions{'ifindex'}" . "\n";
      exit Monitor::Tools::UNKNOWN;
   }
   #print "DEBUG: $key $Poll_Data{$key}\n";
}

### Admin Down generates a WARNING
if( $Poll_Data{'ifAdminStatus'} == 2 )
{
   print "WARNING - Interface $Poll_Data{'ifDescr'} (index $ProgramOptions{'ifindex'}) is administratively down\n";
   exit Monitor::Tools::WARNING;
}

### If the interafce is not OK do stuff...
if( $Poll_Data{'ifOperStatus'} != 1 )
{
   my @InterfaceStatus = ("unused index", "up", "down", "testing", "unknown", "dormant", "notPresent", "lowerLayerDown");
   ### If the interface is down because of a lower layer being down return WARNING
   if( $Poll_Data{'ifOperStatus_data'} == 7 )
   {
      print "WARNING - Interface $Poll_Data{'ifDescr'} (index $ProgramOptions{'ifindex'}) is down because lower layer is down\n";
      exit Monitor::Tools::WARNING;
   }
   ### Any other states generate critical
   else
   {
      print "CRITICAL - Interface $Poll_Data{'ifDescr'} (index $ProgramOptions{'ifindex'}) is $InterfaceStatus[$Poll_Data{'ifOperStatus'}]\n";
      exit Monitor::Tools::CRITICAL;
   }
}

### If you get here everthing is OK
print "OK - Interface $Poll_Data{'ifDescr'} (index $ProgramOptions{'ifindex'}) is UP\n";
exit Monitor::Tools::OK;

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      "warn|w:-1",
      "crit|c:-1",
      "ifindex=s"
   );
}

