#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);
use Data::Dumper;

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
my $snmp_sysUpTime = '.1.3.6.1.2.1.1.3.0';
my $snmp_jnxFruName = '.1.3.6.1.4.1.2636.3.1.15.1.5';
my $snmp_jnxFruType = '.1.3.6.1.4.1.2636.3.1.15.1.6';
my $snmp_jnxFruState = '.1.3.6.1.4.1.2636.3.1.15.1.8';
my $snmp_jnxFruOfflineReason = '.1.3.6.1.4.1.2636.3.1.15.1.10';

my @jnxFruState = ( 'stupid non-zero SNMP index',
                    'unknown',
                    'empty',
                    'present',
                    'ready',
                    'announceOnline',
                    'online',
                    'announceOffline',
                    'offline',
                    'diagnostic',
                    'standyby');
my @jnxFruOfflineReason = ( 'stupid non-zero SNMP index',
                            'unknown(1)',
                            'none(2)',
                            'error(3)',
                            'noPower(4)',
                            'configPowerOff(5)',
                            'configHoldInReset(6)',
                            'cliCommand(7)',
                            'buttonPress(8)',
                            'cliRestart(9)',
                            'overtempShutdown(10)',
                            'masterClockDown(11)',
                            'singleSfmModeChange(12)',
                            'packetSchedulingModeChange(13)',
                            'physicalRemoval(14)',
                            'unresponsiveRestart(15)',
                            'sonetClockAbsent(16)',
                            'rddPowerOff(17)',
                            'majorErrors(18)',
                            'minorErrors(19)',
                            'lccHardRestart(20)',
                            'lccVersionMismatch(21)',
                            'powerCycle(22)',
                            'reconnect(23)',
                            'overvoltage(24)',
                            'pfeVersionMismatch(25)',
                            'febRddCfgChange(26)',
                            'fpcMisconfig(27)',
                            'fruReconnectFail(28)',
                            'fruFwddReset(29)',
                            'fruFebSwitch(30)',
                            'fruFebOffline(31)',
                            'fruInServSoftUpgradeError(32)',
                            'fruChasdPowerRatingExceed(33)',
                            'fruConfigOffline(34)',
                            'fruServiceRestartRequest(35)',
                            'spuResetRequest(36)',
                            'spuFlowdDown(37)',
                            'spuSpi4Down(38)',
                            'spuWatchdogTimeout(39)',
                            'spuCoreDump(40)',
                            'fpgaSpi4LinkDown(41)',
                            'i3Spi4LinkDown(42)',
                            'cppDisconnect(43)',
                            'cpuNotBoot(44)',
                            'spuCoreDumpComplete(45)',
                            'rstOnSpcSpuFailure(46)',
                            'softRstOnSpcSpuFailure(47)',
                            'hwAuthenticationFailure(48)',
                            'reconnectFpcFail(49)',
                            'fpcAppFailed(50)',
                            'fpcKernelCrash(51)',
                            'spuFlowdDownNoCore(52)',
                            'spuFlowdCoreDumpIncomplete(53)',
                            'spuFlowdCoreDumpComplete(54)',
                            'spuIdpdDownNoCore(55)',
                            'spuIdpdCoreDumpIncomplete(56)',
                            'spuIdpdCoreDumpComplete(57)',
                            'spuCoreDumpIncomplete(58)',
                            'spuIdpdDown(59)',
                            'fruPfeReset(60)',
                            'fruReconnectNotReady(61)',
                            'fruSfLinkDown(62)',
                            'fruFabricDown(63)',
                            'fruAntiCounterfeitRetry(64)',
                            'fruFPCChassisClusterDisable(65)',
                            'spuFipsError(66)',
                            'fruFPCFabricDownOffline(67)',
                            'febCfgChange(68)',
                            'routeLocalizationRoleChange(69)',
                            'fruFpcUnsupported(70)',
                            'psdVersionMismatch(71)',
                            'fruResetThresholdExceeded(72)',
                            'picBounce(73)',
                            'badVoltage(74)',
                            'fruFPCReducedFabricBW(75)',
                            'fruAutoheal(76)',
                            'builtinPicBounce(77)',
                            'fruFabricDegraded(78)',
                            'fruFPCFabricDegradedOffline(79)',
                            'fruUnsupportedSlot(80)',
                            'fruRouteLocalizationMisCfg(81)',
                            'fruTypeConfigMismatch(82)',
                            'lccModeChanged(83)',
                            'hwFault(84)',
                            'fruPICOfflineOnEccErrors(85)',
                            'fruFpcIncompatible(86)',
                            'fruFpcFanTrayPEMIncompatible(87)',
                            'fruUnsupportedFirmware(88)',
                            'openflowConfigChange(89)',
                            'fruFpcScbIncompatible(90)',
                            'hwError(91)',
                            'fruReUnresponsive(92)',
                            'fruErrorManagerReqFPCReset(93)');

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $status;
my $output;

if (defined($ProgramOptions{'cpu'}) or defined($ProgramOptions{'memory'}))
{
   if( not check_threshold($ProgramOptions{'warn'}, $ProgramOptions{'crit'}))
   {
      print $Monitor::Tools::output;
      exit $Monitor::Tools::status;
   }
}

if (defined($ProgramOptions{'cpu'}))
{
   my $data = CheckCPUUtil($session);
   print $data->[1];
   exit $data->[0];
}
elsif (defined($ProgramOptions{'memory'}))
{
   my $data = CheckMemUtil($session);
   print $data->[1];
   exit $data->[0];
}
elsif (defined($ProgramOptions{'module'}))
{
   my $data = CheckModule($session);
   print $data->[1];
   exit $data->[0];
}
elsif (defined($ProgramOptions{'fan'}))
{
   my $data = CheckFan($session);
   print $data->[1];
   exit $data->[0];
}
elsif (defined($ProgramOptions{'power'}))
{
   my $data = CheckPowerSupply($session);
   print $data->[1];
   exit $data->[0];
}
else
{
   print "UNKNOWN - No check type defined\n";
   exit Monitor::Tools::UNKNOWN;
}

sub CheckPowerSupply
{
   my $session = shift;

   my $status;
   my $output;

   my @critical_supplies;
   my $sysDescr = $session->get($snmp_sysDescr);
   my $installed_supplies = 0;
   my $min_supplies = ($sysDescr =~ /srx210/) ? 1 : 2;

   my ($snmp_jnxFruState_data) = $session->bulkwalk(0,25, $snmp_jnxFruState . ".2");
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll jnxFruState " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   if( scalar(@$snmp_jnxFruState_data) == 0 )
   {
      $output = "UNKNOWN - Device didn't return data for jnxFruState\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_jnxFruState_data )
   {
      $installed_supplies++ if( $row->val != 2 );
      if( $row->val != 2 and $row->val != 6 )
      {
         my $supply_name = $session->get($snmp_jnxFruName . "." . join(".",(split(/\./, $row->[0]))[-3..-1]) . ".0");
         push(@critical_supplies, "$supply_name ($jnxFruState[$row->val])\n");
      }
   }

   if( scalar(@critical_supplies) != 0 )
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
      $output .= join("", @critical_supplies);
   }
   elsif( $installed_supplies < $min_supplies )
   {
      $output = "CRITICAL - Number of installed power supplies does not match expected.\n";
      $status = Monitor::Tools::CRITICAL;
   }
   else
   {
      $output = "OK - All power supplies installed and functional.\n";
      $status = Monitor::Tools::OK;
   }

   return [$status, $output];
}

sub CheckModule
{
   my $session = shift;

   my $status;
   my $output;

   my @critical_modules;
   my $modules_checked = 0;

   my ($snmp_jnxFruState_data) = $session->bulkwalk(0,25, $snmp_jnxFruState);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll jnxFruState " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   if( scalar(@$snmp_jnxFruState_data) == 0 )
   {
      $output = "UNKNOWN - Device didn't return data for jnxFruState\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_jnxFruState_data )
   {
      next if (split(/\./, $row->[0]))[-3] == 2;
      next if (split(/\./, $row->[0]))[-3] == 4;
      $modules_checked++ if( $row->val != 2 );
      if( $row->val != 2 and $row->val != 6 )
      {
         my $module_name = $session->get($snmp_jnxFruName . "." . join(".",(split(/\./, $row->[0]))[-3..-1]) . ".0");
         my $offline_reason;
         if( $jnxFruState[$row->val] eq 'offline' )
         {
            $offline_reason = $session->get($snmp_jnxFruOfflineReason . "." . join(".",(split(/\./, $row->[0]))[-3..-1]) . ".0");
         }
         my $details = "($jnxFruState[$row->val]";
         $details .= " - $jnxFruOfflineReason[$offline_reason]" if $jnxFruState[$row->val] eq 'offline';
         $details .= ")";
         push(@critical_modules, "$module_name $details\n");
      }
   }

   if( scalar(@critical_modules) != 0 )
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
      $output .= join("", @critical_modules);
   }
   else
   {
      $output = "OK - All modules in acceptable state ($modules_checked checked).\n";
      $status = Monitor::Tools::OK;
   }

   return [$status, $output];



}

sub CheckFan
{
   my $session = shift;

   my $status;
   my $output;

   my @critical_fans;
   my $fans_checked = 0;

   my ($snmp_jnxFruState_data) = $session->bulkwalk(0,25, $snmp_jnxFruState . ".4");
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll jnxFruState " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   if( scalar(@$snmp_jnxFruState_data) == 0 )
   {
      $output = "UNKNOWN - Device didn't return data for jnxFruState\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_jnxFruState\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_jnxFruState_data )
   {
      $fans_checked++ if $row->val != 2;
      if( $row->val != 2 and $row->val != 6 )
      {
         my $fan_name = $session->get($snmp_jnxFruName . "." . join(".",(split(/\./, $row->[0]))[-3..-1]) . ".0");
         push(@critical_fans, "$fan_name ($jnxFruState[$row->val])\n");
      }
   }

   if( scalar(@critical_fans) != 0 )
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
      $output .= join("", @critical_fans);
   }
   else
   {
      $output = "OK - All fans in acceptable state ($fans_checked checked).\n";
      $status = Monitor::Tools::OK;
   }

   return [$status, $output];

}

sub CheckCPUUtil
{
   my $session = shift;

}

sub CheckMemUtil
{
   my $session = shift;

}

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "warn|w:-1",
      "crit|c:-1",
      "power",
      "fan",
      "module",
      "memory",
      "cpu",
      "perfdata"
   );
}
