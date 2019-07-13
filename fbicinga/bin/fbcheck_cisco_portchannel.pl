#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_ifdesc = '.1.3.6.1.2.1.2.2.1.2';
my $snmp_dot3adAggPortListPorts = '.1.2.840.10006.300.43.1.1.2.1.1'; #IEEE8023-LAG-MIB
my $snmp_dot3adAggPortAttachedAggID = '.1.2.840.10006.300.43.1.2.1.1.13'; #IEEE8023-LAG-MIB

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $status = Monitor::Tools::OK; # Program return code that is interpreted by Icinga/Nagios to determine status
my $output; # string to contain the plugin out.  Printed to STDOUT just before exiting

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

### Get description of LAG for pretty output.  Also checks to make sure the ifIndex is valid
my $po_ifdesc = $session->get($snmp_ifdesc . "." . $ProgramOptions{'POifIndex'});
if( $session->{ErrorStr} )
{
   $status = Monitor::Tools::UNKNOWN;
   $output = "UNKNOWN - Unable to poll ifDesc " . $session->{ErrorStr} . "\n";
   $output .= $Monitor::Tools::snmp_cli . " $snmp_ifdesc\n";
   print $output;
   exit $status;
}
elsif( $po_ifdesc =~ /NOSUCH/ )
{
   $status = Monitor::Tools::UNKNOWN;
   $output = "UNKNOWN - Specified ifIndex $ProgramOptions{'POifIndex'} does not exist\n";
   print $output;
   exit $status;
}

### Because Cisco can't be consistent we have to check 2 differnt ways.  Between 2 tables I can find if
### any members are down.  I can't figure out how to decode what the members are of a port channel, so 
### I just tell you its down and you have to go figure it out.

### First we pull dot2adAddPortAttachedAggID.  If it comes back with no data either all the port channels
### are down or the device doesn't implement this table.  Depending on the platform it will either return
### all the ports on the device and the value is the ifIndex of the LAG interface.  Or the only thing that
### is returned is a table of interfaces that are LAG members.  
my ($snmp_dot2adAddPortAttachedAggID_data) = $session->bulkwalk(0,10, $snmp_dot3adAggPortAttachedAggID );
if( $session->{ErrorStr} )
{
   $status = Monitor::Tools::UNKNOWN;
   $output = "UNKNOWN - Unable to poll dot2adAddPortAttachedAggID " . $session->{ErrorStr} . "\n";
   $output .= $Monitor::Tools::snmp_cli . " $snmp_dot3adAggPortAttachedAggID\n";
   return [$status, $output];
}

if ( scalar(@$snmp_dot2adAddPortAttachedAggID_data) == 0 )
{
   ### So if we got no data from the fisrt table then we can go do a get on dot3adAggPortListPorts with the 
   ### index of the LAG interface.  The return is a string list of members.  Cisco uses the same shorthand
   ### in the return as the interface range statement.  So we can check for the existance of a "-" or ",".
   ### if neither of those characters are there then its just a single port, and that means a member is down
   ### sample: iso.2.840.10006.300.43.1.1.2.1.1.369098752 = STRING: "47" <- Broken
   ### sample: iso.2.840.10006.300.43.1.1.2.1.1.369098752 = STRING: "47-48" <- Ok
   my $lag_member_list = $session->get($snmp_dot3adAggPortListPorts . "." . $ProgramOptions{'POifIndex'});
   if( $session->{ErrorStr} )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll dot3adAggPortListPorts" . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_dot3adAggPortListPorts\n";
      print $output;
      exit $status;
   }

   if ($lag_member_list !~ /-|,/)
   {
      $output = "CRITICAL: Port down in bundle $po_ifdesc\n";
      $status = Monitor::Tools::CRITICAL;
   }
   else
   {
      $output = "OK: All members up for $po_ifdesc\n";
   }
}
else
{
   my $activeportcount = 0;
   foreach my $port ( @$snmp_dot2adAddPortAttachedAggID_data )
   {
      if ($port->val == $ProgramOptions{'POifIndex'})
      {
         $activeportcount++;
      }
   }

   if ($activeportcount < 2 )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL: Port down in bundle $po_ifdesc\n";
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = "OK: All members up for $po_ifdesc\n";
   }
}


print $output;
exit $status;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      "POifIndex=i"
   );
}
