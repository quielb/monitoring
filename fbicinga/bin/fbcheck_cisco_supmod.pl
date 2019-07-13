#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Corpnet::FBIcinga;

my $snmp_cRFStatusPeerUnitId = '.1.3.6.1.4.1.9.9.176.1.1.3.0'; #CISCO-RF-MIB
my $snmp_cRFStatusPeerUnitState = '.1.3.6.1.4.1.9.9.176.1.1.4.0'; #CISCO-RF-MIB


my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Corpnet::FBIcinga::output;
   exit $Corpnet::FBIcinga::status;
}

my @sup_states = ( "unused",
   "notKnown",
   "disabled",
   "initialization",
   "negotiation",
   "standByCold",
   "standByColdConfig",
   "standByColdFileSts",
   "standByColdBulk",
   "standByHot",
   "activeFast",
   "activeDrain",
   "activePreconfig",
   "activePostconfig",
   "active",
   "activeExtraload",
   "activeHandback");

my $snmp_cRFStatusPeerUnitId_data = $session->get($snmp_cRFStatusPeerUnitId);
if( $snmp_cRFStatusPeerUnitId_data == 0 )
{
   print "OK - This device does not have redundant supervisior module\n";
   exit Corpnet::FBIcinga::OK;
}
elsif( $snmp_cRFStatusPeerUnitId_data == 5 )
{
   print "WARNING - Slot 5 is not currently the active supervisor module\n";
   exit Corpnet::FBIcinga::WARNING;
}

my $snmp_cRFStatusPeerUnitState_data = $session->get($snmp_cRFStatusPeerUnitState);
if( $snmp_cRFStatusPeerUnitState_data != 9 )
{
   print "CRITICAL - Standby supervisior is not in standByHot state.  Current state: ";
   print $sup_states[$snmp_cRFStatusPeerUnitState_data] . "\n";
   exit Corpnet::FBIcinga::CRITICAL;
}

print "OK - Standby supervisior is in expected standByHot state.\n";
exit Corpnet::FBIcinga::OK;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H=s",
      "C=s"
   );
}

