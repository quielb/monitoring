#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monnitor::Tools;

my $snmp_rPDU2PhaseStatusLoadState = '.1.3.6.1.4.1.318.1.1.26.6.3.1.4'; # powernet417.mib
my $snmp_rPDU2PhaseStatusCurrent = '.1.3.6.1.4.1.318.1.1.26.6.3.1.5'; # powernet417.mib
my $snmp_rPDU2PhaseStatusPower = '.1.3.6.1.4.1.318.1.1.26.6.3.1.7'; # powernet417.mib
my $snmp_rPDU2BankStatusLoadState = '.1.3.6.1.4.1.318.1.1.26.8.3.1.4'; # powernet417.mib
my $snmp_rPDU2BankStatusCurrent = '.1.3.6.1.4.1.318.1.1.26.8.3.1.5'; # powernet417.mib

my %ProgramOptions;
ParseOptions();

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});
if( not defined($session) )
{
   print $Monnitor::Tools::output;
   exit $Monnitor::Tools::status;
}

my @phaseInfo;
my @bankInfo;
my $status = Monnitor::Tools::OK; # Set a default status.  If that doesn't change then everthing is ok
my $output;
my $perfdata = "|";

### Start with the load for the entire PDU.  The data is in a table because could be a multiphase 
### strip.  We don't currently have any?  But the code should allow for it.
my ($snmp_rPDU2PhaseStatusLoadState_data) = $session->bulkwalk(0,25,[$snmp_rPDU2PhaseStatusLoadState]);
if( $session->{ErrorStr} )
{
   print "UNKNOWN - Unable to poll rPDU2PhaseStatusLoadState " . $session->{ErrorStr} . " \n";
   print $Monnitor::Tools::snmp_cli . " $snmp_rPDU2PhaseStatusLoadState\n";
   exit Monnitor::Tools::UNKNOWN;
}

### Pulling load state which APC decides the load condition based on amperage usage
### Current is AMPs used
### Power is watts
foreach my $row ( @$snmp_rPDU2PhaseStatusLoadState_data )
{
   my $phaseData;
   $phaseData->{'LoadState'} = $row->val;
   ### Divided by 10 because return is tenths of AMPs
   $phaseData->{'Current'} = $session->get($snmp_rPDU2PhaseStatusCurrent . "." . $row->iid) /10;
   ### Multiply by 10 because return is hundredths of kilowatts and want to convert to watts.
   $phaseData->{'Power'} = $session->get($snmp_rPDU2PhaseStatusPower . "." . $row->iid) *10;
   $phaseInfo[$row->iid] = $phaseData;
}

### Get data for the individual banks on the PDU.  Depending on model could be 1,2 or 3.
my ($snmp_rPDU2BankStatusLoadState_data) = $session->bulkwalk(0,25,[$snmp_rPDU2BankStatusLoadState]);
if( $session->{ErrorStr} )
{
   print "UNKNOWN - Unable to poll rPDU2BankStatusLoadState " . $session->{ErrorStr} . " \n";
   print $Monnitor::Tools::snmp_cli . " $snmp_rPDU2BankStatusLoadState\n";
   exit Monnitor::Tools::UNKNOWN;
}

foreach my $row ( @$snmp_rPDU2BankStatusLoadState_data )
{
   my $bankData;
   $bankData->{'LoadState'} = $row->val;
   ### Divided by 10 because return is tenths of AMPs
   $bankData->{'Current'} = $session->get($snmp_rPDU2BankStatusCurrent . "." . $row->iid) /10;
   $bankInfo[$row->iid] = $bankData;
}

### Now lets find the problems
### Starting at 1 becuase there is no phase 0.  Its either 1,2, or 3
for my $i ( 1..(@phaseInfo-1) )
{
   ### 1 - lowLoad
   ### 2 - normal
   ### 3 - nearOverload
   ### 4 - overload
   if( $phaseInfo[$i]->{'LoadState'} == 3 )
   {
      $output .= "Phase $i is near overload\n";
      $status = Monnitor::Tools::WARNING if $status < Monnitor::Tools::WARNING;
   }
   elsif( $phaseInfo[$i]->{'LoadState'} == 4 )
   {
      $output .= "Phase $i is overloaded\n";
      $status = Monnitor::Tools::CRITICAL;
   }
   $perfdata .= "phase_" . $i . "_current_amps=" . $phaseInfo[$i]->{'Current'} . " ";
   $perfdata .= "phase_" . $i . "_power_watts=" . $phaseInfo[$i]->{'Power'} . " ";
}

### Starting at 1 becuase there is no bank 0 on a PDU its either 1 or 2.  Which kind of sucks
### because on the PDU they are usually labeled A and B
for my $i ( 1..(@bankInfo-1) )
{
   ### 1 - lowLoad
   ### 2 - normal
   ### 3 - nearOverload
   ### 4 - overload
   if ( $bankInfo[$i]->{'LoadState'} == 3 )
   {
      $output .= "Bank $i is near overload\n";
      $status = Monnitor::Tools::WARNING if $status < Monnitor::Tools::WARNING;
   }
   elsif( $bankInfo[$i]->{'LoadState'} == 4 )
   {
      $output .= "Bank $i is overloaded\n";
      $status = Monnitor::Tools::CRITICAL;
   }
   $perfdata .= "bank_" . $i . "_current_amps=" . $bankInfo[$i]->{'Current'} . " ";
}

if( $status == Monnitor::Tools::OK )
{
    print "OK - All power usage is fine\n";
}
else
{
   print "WARNING - " if $status == Monnitor::Tools::WARNING;
   print "CRITICAL - " if $status == Monnitor::Tools::CRITICAL;
}
 
print $output;
print "$perfdata\n" if defined $ProgramOptions{'perfdata'};
exit $status;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "perfdata",
   );
}

