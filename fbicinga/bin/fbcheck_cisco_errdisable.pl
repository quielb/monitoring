#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);
use feature 'switch';

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_cErrDisableIfStatusTable = '.1.3.6.1.4.1.9.9.548.1.3.1';
my $snmp_cErrDisableIfStatusCause = '.1.3.6.1.4.1.9.9.548.1.3.1.1.2';
my $snmp_cErrDisableIfStatusTimeToRecover = '.1.3.6.1.4.1.9.9.548.1.3.1.1.3';

my %ProgramOptions;
ParseOptions();

my $status;
my $output;
my %errDisableCount; 
my %errDisableRecover;
my $count = 0;

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});
if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

(my $snmp_cErrDisableIfStatusCause_data) = $session->bulkwalk(0, 10, $snmp_cErrDisableIfStatusCause);
if( $session->{ErrorStr} )
{
   $output = "UNKNOWN - Unable to poll cErrDisableIfStatusTable " . $session->{ErrorStr} . "\n";
   $output .= $Monitor::Tools::snmp_cli . " $snmp_cErrDisableIfStatusTable\n";
   print $output;
   exit Monitor::Tools::UNKNOWN;
}

if( scalar(@{$snmp_cErrDisableIfStatusCause_data}) == 0 )
{
   $output = "OK - Error Disabled port count is 0\n";
   $status = Monitor::Tools::OK;
}
else
{
   my $auto_recover_count = 0;
   foreach my $interface ( @{$snmp_cErrDisableIfStatusCause_data} )
   {
      $count++;
      $errDisableCount{$interface->val} += 1; 
      my $ifindex = (split(/\./, $interface->[0]))[-1];
      my $auto_recover_check = $session->get($snmp_cErrDisableIfStatusTimeToRecover . ".$ifindex.0");
      if( $auto_recover_check > 0 )
      {
         $errDisableRecover{$interface->val} = 1;
         $auto_recover_count++;
      }
   }

   if( $auto_recover_count == $count )
   {
      $output = "OK - errDisable ports ($count) are AutoRecover\n";
      $status = Monitor::Tools::OK;
   }
   else
   {
      $output .= "CRITICAL - $count error disabled port(s)\n";
      $status = Monitor::Tools::CRITICAL;
   
      foreach my $key ( keys %errDisableCount )
      {
         given( $key )
         {
            when ( /1/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - udld disabled\n"; }
            when ( /2/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - bpduGuard disabled\n"; }
            when ( /3/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - channelMisconfig disabled\n"; }
            when ( /4/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - pagpFlap disabled}\n"; }
            when ( /5/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - dtpFlapdisabled\n"; }
            when ( /6/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - linkFlap disabled\n"; }
            when ( /7/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - l2tpGuard disabled\n"; }
            when ( /8/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - dot1xSecurityViolation disabled\n"; }
            when ( /9/ and $errDisableCount{$_} > 0 )  { $output .= "$errDisableCount{$_} - portSecurityViolation disabled\n"; }
            when ( /10/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - gbicInvalid disabled\n"; }
            when ( /11/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - dhcpRateLimit disabled\n"; }
            when ( /12/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - unicastFlood disabled\n"; }
            when ( /13/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - vmps disabled\n"; }
            when ( /14/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - stormControl disabled\n"; }
            when ( /15/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - inlinePower disabled\n"; }
            when ( /16/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - arpInspection disabled\n"; }
            when ( /17/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - portLoopback disabled\n"; }
            when ( /18/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - packetBuffer disabled\n"; }
            when ( /19/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - maclimit disabled\n"; }
            when ( /20/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - linkMonitorFailure disabled\n"; }
            when ( /21/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - oamRemoteFailure disabled\n"; }
            when ( /22/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - dot1adIncompEtype disabled\n"; }
            when ( /23/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - dot1adIncompTunnel disabled\n"; }
            when ( /24/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - sfpConfigMismatch disabled\n"; }
            when ( /25/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - communityLimit disabled\n"; }
            when ( /26/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - invalidPolicy disabled\n"; }
            when ( /27/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - lsGroup disabled\n"; }
            when ( /28/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - ekey disabled\n"; }
            when ( /29/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - portModeFailure disabled\n"; }
            when ( /30/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - ppoeIaRateLimit disabled\n"; }
            when ( /31/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - oamRemoteCriticalEvent disabled\n"; }
            when ( /32/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - oamRemoteDyingGasp disabled\n"; }
            when ( /33/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - oamRemoteLinkFault disabled\n"; }
            when ( /34/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - mvrp disabled\n"; }
            when ( /35/ and $errDisableCount{$_} > 0 ) { $output .= "$errDisableCount{$_} - tranceiverIncomp disabled\n"; }
         }
      }  
   }
}

if( defined($ProgramOptions{'perfdata'}) )
{

   $output .= "|errdisable=$count\n";
}

print $output;
exit $status;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "perfdata"
   );
}
