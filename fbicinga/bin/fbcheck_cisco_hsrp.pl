#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long;

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_cHsrpGrpTable = '.1.3.6.1.4.1.9.9.106.1.2.1';
my $snmp_cHsrpGrpStatndbyState = '.1.3.6.1.4.1.9.9.106.1.2.1.1.15';
my $snmp_cHsrpGrpStandbyRouter = '.1.3.6.1.4.1.9.9.106.1.2.1.1.14';
my $snmp_ifAdminStatus = '.1.3.6.1.2.1.2.2.1.7';

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $status = Monitor::Tools::UNKNOWN; # Program return code that is interpreted by Icinga/Nagios to determine status
my $output = "UNKNOWN - HSRP group $ProgramOptions{'group'} not found in cHsrpGrpTable\n"; # string to contain the plugin out.  Printed to STDOUT just before exiting

my $session = snmp_connect($ProgramOptions{'H'}, $ProgramOptions{'C'});
if(not defined $session)
{
   ### We weren't able to establish a session.  That makes the result UNKNOWN
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $ifIndex;
my %HSRPState = ( 1, 'initial', 2, 'learn', 3, 'listen', 4, 'speak', 5, 'standby', 6, 'active' );

if ( $ProgramOptions{'mode'} !~ /active|standby/ )
{
   print "UNKNOWN - No valid HSRP state specified\n";
   exit Monitor::Tools::UNKNOWN;
}

if( !defined($ProgramOptions{'group'}) )
{
   print "UNKNOWN - No valid HSRP group specified\n";
   exit Monitor::Tools::UNKNOWN;
}


### Find the Group passed in check the state.
my $snmp_cHsrpGrpTable_data = $session->bulkwalk(0,20, [[$snmp_cHsrpGrpStandbyRouter], [$snmp_cHsrpGrpStatndbyState]]);
if( $session->{ErrorStr} )
{
   print "UNKNOWN - could not poll cHsrpGrpTable\n";
   print $Monitor::Tools::snmp_cli . " $snmp_cHsrpGrpTable\n";
   exit Monitor::Tools::UNKNOWN;
}

for my $i (0..(@{$snmp_cHsrpGrpTable_data->[1]}-1))
{
   #print "DEBUG: compairing group " . $snmp_cHsrpGrpTable_data->[1]->[$i]->iid . " to $ProgramOptions{'group'}\n";
   if ( $snmp_cHsrpGrpTable_data->[1]->[$i]->iid == $ProgramOptions{'group'} )
   {
      #print "DEBUG: Comparing state " . $snmp_cHsrpGrpTable_data->[1]->[$i]->val . " " . $HSRPState{$snmp_cHsrpGrpTable_data->[1]->[$i]->val};
      #print " to state $ProgramOptions{'mode'}\n";
      if ($HSRPState{$snmp_cHsrpGrpTable_data->[1]->[$i]->val} ne $ProgramOptions{'mode'})
      {
         #print "DEBUG: Found group not in expected state\n";
         $output = "CRITICAL - Group " . $ProgramOptions{'group'} . " state ";
         $output .= $HSRPState{$snmp_cHsrpGrpTable_data->[1]->[$i]->val} . " instead of $ProgramOptions{'mode'}\n";
         $status = Monitor::Tools::CRITICAL;
      }
      else
      {
         if( $HSRPState{$snmp_cHsrpGrpTable_data->[1]->[$i]->val} eq 'active' and $ProgramOptions{'mode'} eq 'active' )
         {
            if( $snmp_cHsrpGrpTable_data->[0]->[$i]->val eq '0.0.0.0' )
            {
               #print "DEBUG: Group in expected state but no peer\n";
               $output = "CRITICAL - HSRP group $ProgramOptions{'group'} is active but no secondary router found\n";
               $status = Monitor::Tools::CRITICAL;
            }
            else 
            {
               $output = "OK - HSRP group $ProgramOptions{'group'} is in expected state\n";
               $status = Monitor::Tools::OK;
            }
         }
         else
         {
            $output = "OK - HSRP group $ProgramOptions{'group'} is in expected state\n";
            $status = Monitor::Tools::OK;
         }
      }
      $ifIndex = (split(/\./, $snmp_cHsrpGrpTable_data->[1]->[$i]->[0]))[-1];
      last;
   }
}

if( $status == Monitor::Tools::UNKNOWN )
{
   print $output;
   exit $status;
}

### Check the state of the interface.  AdminDown is OK
my $snmp_ifAdminStatus_data =  $session->get("$snmp_ifAdminStatus.$ifIndex");
if( $session->{ErrorStr} )
{
   print "UNKNOWN - could not poll ifAdminStatus\n";
   print $Monitor::Tools::snmp_cli . " $snmp_ifAdminStatus\n";
   exit Monitor::Tools::UNKNOWN;
}
if( $snmp_ifAdminStatus_data =~ /NOSUCH/ )
{
   print "UNKNOWN - Something went terribly wrong trying to find the interface for the HSRP group\n";
   exit Monitor::Tools::UNKNOWN;
}

if ($snmp_ifAdminStatus_data == 2)
{
   $output = "OK - HSRP group $ProgramOptions{'group'} interface is Admin Down\n";
   $status = Monitor::Tools::OK;
}

print $output;
exit $status;

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      "mode=s",
      "group=i"
   );
}

