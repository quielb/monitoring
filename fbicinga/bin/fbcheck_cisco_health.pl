#!/usr/bin/perl

#use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
my $snmp_sysUpTime = '.1.3.6.1.2.1.1.3.0';
my $snmp_ciscoEnvMonSupplyStatusDescr = '.1.3.6.1.4.1.9.9.13.1.5.1.2'; #CISCO-ENVMON-MIB
my $snmp_ciscoEnvMonSupplyState = '.1.3.6.1.4.1.9.9.13.1.5.1.3'; #CISCO-ENVMON-MIB
my $snmp_cefeFRUPowerOperStatus = '.1.3.6.1.4.1.9.9.117.1.1.2.1.2'; #CISCO-ENTITY-FRU-CONTROL-MIB
my $snmp_entPhysicalDescr = '.1.3.6.1.2.1.47.1.1.1.1.2'; #ENTITY-MIB
my $snmp_entPhysicalClass = '.1.3.6.1.2.1.47.1.1.1.1.5'; #ENTITY-MIB
my $snmp_entPhysicalContainedIn = '.1.3.6.1.2.1.47.1.1.1.1.4'; #ENTITY-MIB
my $snmp_entPhysicalName = '.1.3.6.1.2.1.47.1.1.1.1.7'; #ENTITY-MIB
my $snmp_cefcModuleOperStatus = '.1.3.6.1.4.1.9.9.117.1.2.1.1.2'; #CISCO-ENTITY-FRU-CONTROL-MIB
my $snmp_cefcModuleUpTime = '.1.3.6.1.4.1.9.9.117.1.2.1.1.8'; #CISCO-ENTITY-FRU-CONTROL-MIB
my $snmp_cefcFanTrayOperStatus = '.1.3.6.1.4.1.9.9.117.1.4.1.1.1'; #CISCO-ENTITY-FRU-CONTROL-MIB
my $snmp_cpmCPUTotalPhysicalIndex = '.1.3.6.1.4.1.9.9.109.1.1.1.1.2'; #CISCO-PROCESS-MIB
my $snmp_cpmCPUTotal1minRev = '.1.3.6.1.4.1.9.9.109.1.1.1.1.7'; #CISCO-PROCESS-MIB
my $snmp_cpmCPUTotalTable = '.1.3.6.1.4.1.9.9.109.1.1.1'; #CISCO-PROCESS-MIB
my $snmp_cpmCoreTable = '.1.3.6.1.4.1.9.9.109.1.1.2'; #CISCO-PROCESS-MIB
my $snmp_ciscoMemoryPoolName = '.1.3.6.1.4.1.9.9.48.1.1.1.2'; #CISCO-MEMORY-POOL
my $snmp_ciscoMemoryPoolUsed = '.1.3.6.1.4.1.9.9.48.1.1.1.5'; #CISCO-MEMORY-POOL
my $snmp_ciscoMemoryPoolFree = '.1.3.6.1.4.1.9.9.48.1.1.1.6'; #CISCO-MEMORY-POOL
my $snmp_ciscoMemoryPoolLargestFree = '.1.3.6.1.4.1.9.9.48.1.1.1.7'; #CISCO-MEMORY-POOL
my $snmp_ciscoEnvMonTemperatureStatusDescr = '.1.3.6.1.4.1.9.9.13.1.3.1.2'; #CISCO-ENVMON-MIB
my $snmp_ciscoEnvMonTemperatureStatusValue = '.1.3.6.1.4.1.9.9.13.1.3.1.3'; #CISCO-ENVMON-MIB
my $snmp_ciscoEnvMonTemperatureState = '.1.3.6.1.4.1.9.9.13.1.3.1.6'; #CISCO-ENVMON-MIB
my $snmp_entSensorType = '.1.3.6.1.4.1.9.9.91.1.1.1.1.1'; #CISCO-ENTITY-SENSOR-MIB
my $snmp_entSensorValue = '.1.3.6.1.4.1.9.9.91.1.1.1.1.4'; #CISCO-ENTITY-SENSOR-MIB


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
#elsif (defined($ProgramOptions{'temp'}))
#{
#   my $data = CheckTemp($session);
#   print $data->[1];
#   exit $data->[0];
#}
else
{
   print "UNKNOWN - No check type defined\n";
   exit Monitor::Tools::UNKNOWN;
}

sub CheckPowerSupply
{
   ### Checking power supply states requries 2 different lookups depending on platform.  There is also an SNMP
   ### bug in 3560X that don't report power supply states correctly from EnvMonSupplyStatusTable.
   my $session = shift;

   my @criticalsupplies;
   my @warningsupplies;

   my @PowerOperType = ('unused','offEnvOther','on','offAdmin','offDenied','offEnvPower','offEnvTemp','offEnvFan',
   'failed','onButFanFail','offCooling','offConnectiorRating','onButInlinePowerFail');
   my @ciscoEnvMonSupplyState = ('unused','normal','warning','critical','shutdown','notPresent','notFunctioning');


   ### Counters to track number of installed supplies.
   my $entPS_counter = 0;
   my $envPS_counter = 0;

   ### The two tables that could contain power supply information
   my ($snmp_entPhysicalClass_data) = $session->bulkwalk(0,25,$snmp_entPhysicalClass);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll entPhysicalClass " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_entPhysicalClass\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_entPhysicalClass_data )
   {
      if ($row->val == 6)
      {
         my $snmp_cefeFRUPowerOperStatus_data = $session->get( $snmp_cefeFRUPowerOperStatus . "." . $row->iid);
         if( $snmp_cefeFRUPowerOperStatus_data ne 'NOSUCH' )
         {
            $entPS_counter++;
            if ( $PowerOperType[$snmp_cefeFRUPowerOperStatus_data] ne 'on' and $snmp_cefeFRUPowerOperStatus_data !~ /NOSUCH/ )
            {
               if ($PowerOperType[$snmp_cefeFRUPowerOperStatus_data] eq 'unused')
               {
                  push(@criticalsupplies, "Power supply (unknown)\n");
               }
               else
               {
                  my $snmp_entPhysicalDescr_data = $session->get( $snmp_entPhysicalDescr . "." . $row->iid);
                  push(@criticalsupplies, "$snmp_entPhysicalDescr_data ($PowerOperType[$snmp_cefeFRUPowerOperStatus_data])\n");
               }
            }
         }
      }
   }


   if( scalar(@criticalsupplies) == 0 )
   {
      my ($snmp_ciscoEnvMonSupplyState_data) = $session->bulkwalk(0,25,$snmp_ciscoEnvMonSupplyState);
      if( $session->{ErrorStr} )
      {
         $output = "UNKNOWN - Unable to poll ciscoEnvMonSupplyState " . $session->{ErrorStr} . " \n";
         $output .= $Monitor::Tools::snmp_cli . " $snmp_ciscoEnvMonSupplyState\n";
         $status = Monitor::Tools::UNKNOWN;
         return [ $status, $output ];
      }

      foreach my $row ( @$snmp_ciscoEnvMonSupplyState_data )
      {
         $envPS_counter++;
         if( $ciscoEnvMonSupplyState[$row->val] ne 'normal' )
         {
            my $snmp_ciscoEnvMonSupplyStatusDescr_data = $session->get($snmp_ciscoEnvMonSupplyStatusDescr . "." . $row->iid);
            push(@criticalsupplies, "$snmp_ciscoEnvMonSupplyStatusDescr_data ($ciscoEnvMonSupplyState[$row->val])\n");
         }
      }
   }

   if(scalar(@criticalsupplies) != 0 or scalar(@warningsupplies) != 0)
   {
      if( scalar(@criticalsupplies) )
      {
         $output = "CRITICAL - ";
         $status = Monitor::Tools::CRITICAL;
      }
      else
      {
         $output = "WARNING - ";
         $status = Monitor::Tools::WARNING;
      }
      $output .= join("", @criticalsupplies) if scalar(@criticalsupplies) > 0;
      $output .= join("", @warningsupplies) if scalar(@warningsupplies) > 0;
   }
   elsif( $envPS_counter < 2 and $entPS_counter < 2 )
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
   my $module_checked =0;
   my @module_error;
   my @module_unknown;
   my @ModuleState = ('SNMP_TIMEOUT','unknown','ok','disabled','okButDiagFailed','boot','selfTest','failed','missing','mismatchWithParent',
      'mismatchConfig','diagFailed','dormant','outOfServiceAdmin','outOfServiceEnvTemp','poweredDown','poweredUp','powerDenied',
      'powerCycled','okButPowerOverWarning','okButPowerOverCritical','syncInProgress','upgrading','okButAuthFailed','mdr',
      'fwMismatchFound','fwDownloadSuccess','fwDownloadFailure');

   my ($snmp_entPhysicalClass_data) = $session->bulkwalk(0,25, $snmp_entPhysicalClass);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll entPhysicalClass " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_entPhysicalClass\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   my $snmp_sysUpTime_data = $session->get($snmp_sysUpTime);
   foreach my $row ( @$snmp_entPhysicalClass_data )
   {
      ### First we need to find the modules in a device.  Cisco is a bit loose with the term module
      if ($row->val == 9)
      {
         my $snmp_cefcModuleOperStatus_data = $session->get($snmp_cefcModuleOperStatus . "." . $row->iid);
         ### If there is status data for the module get it.  Since Cisco is loose with the term module there may
         ### not be any module status data
         if( $snmp_cefcModuleOperStatus_data !~ /NOSUCH/ )
         {
            $module_checked++;
            my $snmp_entPhysicalDescr_data = $session->get($snmp_entPhysicalDescr . "." . $row->iid);
            ### Once we find the module see how long it has been up.  This is meant to catch modules that auto reboot.  Make sure the host
            ### has been up for at least 30 minutes.
            my $snmp_cefcModuleUpTime_data = $session->get($snmp_cefcModuleUpTime . "." . $row->iid);
            if( $ModuleState[$snmp_cefcModuleOperStatus_data] ne 'ok' )
            {
               my $mod_str = "Module: " . $snmp_entPhysicalDescr_data . " State: " . $ModuleState[$snmp_cefcModuleOperStatus_data] . "\n";
               if ($ModuleState[$snmp_cefcModuleOperStatus_data] eq 'SNMP_TIMEOUT')
               {
                  push(@module_unknown, $mod_str);
               }
               else
               {
                  push(@module_error,  $mod_str);
               }
            }
            ### Now that we have passed the time constaints check the status of the module
            elsif( $snmp_cefcModuleUpTime_data ~~ [1..1800] and $snmp_sysUpTime_data > 360000 and $snmp_cefcModuleUpTime_data !~ /NOSUCH/ )
            {
               push(@module_error, "Module " . $snmp_entPhysicalDescr_data . " is below minimum runtime\n" );
            }
         }
      }
   }
   if( scalar(@module_unknown) > 0) {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to reliably poll module status.\nCould not retrieve state for:\n" . join("", @module_unknown);
   }
   elsif( scalar(@module_error) > 0 )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL - Modules in chassis have error ($module_checked checked)\n" . join("", @module_error);
   }
   else
   {
      $output = "OK - All Modules in acceptable state ($module_checked checked)\n";
      $status = Monitor::Tools::OK;
   }

   return [$status, $output];
}

sub CheckFan
{
   my $session = shift;
   my $fan_checked = 0;
   my @fan_error;
   my @FanState = ('unused','unused','up','down','warning');

   my ($snmp_entPhysicalClass_data) = $session->bulkwalk(0,25,$snmp_entPhysicalClass);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll entPhysicalClass " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_entPhysicalClass\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_entPhysicalClass_data )
   {
      if ($row->val == 7)
      {
         my $snmp_cefcFanTrayOperStatus_data = $session->get($snmp_cefcFanTrayOperStatus . "." . $row->iid);
         if( $snmp_cefcFanTrayOperStatus_data !~ /NOSUCH/ )
         {
            $fan_checked++;
            if( $FanState[$snmp_cefcFanTrayOperStatus_data] ne 'up' )
            {
               my $snmp_entPhysicalName_data = $session->get($snmp_entPhysicalName . "." . $row->iid);
               push(@fan_error, "Fan " . $snmp_entPhysicalName_data . " - " . $FanState[$snmp_cefcFanTrayOperStatus]);
            }
         }
      }
   }

   if( scalar(@fan_error) > 0 )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL - Fan(s) in device have error ($fan_checked checked)\n";
      $output .= join("", @fan_error);
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = "OK - All Fans in acceptable state ($fan_checked checked)\n";
   }

   return [$status, $output];
}

sub CheckCPUUtil
{
   my $session = shift;
   my $cpu_checked = 0;
   my %cpu;
   my $perfdata = '|';
   my @cpu_critical;
   my @cpu_warning;

   my ($cpmCPUTotalPhysicalIndex_data) = $session->bulkwalk(0,10,$snmp_cpmCPUTotalPhysicalIndex);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll cpmCPUTotalPhysicalIndex " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_cpmCPUTotalPhysicalIndex\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row (@$cpmCPUTotalPhysicalIndex_data)
   {
      # Need to check if this CPU is multi-core
      my ($snmp_cpmCore1m_data) = $session->bulkwalk(0,10, $snmp_cpmCoreTable . ".1.4." . $row->val);
      if( $session->{ErrorStr} )
      {
         $output = "UNKNOWN - Unable to poll cpmCoreTable " . $session->{ErrorStr} . " \n";
         $output .= $Monitor::Tools::snmp_cli . " $snmp_cpmCoreTable\n";
         $status = Monitor::Tools::UNKNOWN;
         return [ $status, $output ];
      }

      if( scalar(@$snmp_cpmCore1m_data) > 0 )
      {
         foreach my $row_core (@$snmp_cpmCore1m_data)
         {
            $cpu_checked++;
            my $cpu_name = $session->get($snmp_entPhysicalName . "." . $row->val) . "." . $row_core->iid;
            $cpu_name = "cpu_" . $cpu_name if $cpu_name !~ /cpu/i;
            #print "DEBUG: CPU Util OID - $cpmCPUTotal1min\n";
            $cpu{$cpu_name} = $row_core->val;
            #print "DEBUG: CPU found - $cpu_name: util " . $cpu{$cpu_name} . "\n";
         }
      }
      else
      {
         $cpu_checked++;
         # Check if single CPU.  The entTable index will be 0
         if( $row->val == 0)
         {
            my $cpu_name = "cpu_" . $row->iid if $row->iid !~ /cpu/i;
            $cpu{$cpu_name} = $session->get($snmp_cpmCPUTotal1minRev . "." . $row->iid);
            #print "DEBUG: CPU found - $cpu_name: util " . $cpu{$cpu_name} . "\n";
         }
         else
         {
            my $cpu_name = $session->get($snmp_entPhysicalName . "." . $row->val);
            # Need some special handling for N7K because Cisco is dumb
            # Get the name of the parent container and smash it all together
            if( $cpu_name =~ /1\/10 Gbps Ethernet Module|Supervisor Module-1X/ )
            {
               my $parent_container = $session->get($snmp_entPhysicalContainedIn . "." . $row->iid);
               $cpu_name = $session->get($snmp_entPhysicalName . "." . $parent_container);
            }
            $cpu_name = "cpu_" . $cpu_name if $cpu_name !~ /cpu/i;
            #print "DEBUG: CPU Util OID - $cpmCPUTotal1min\n";
            $cpu{$cpu_name} = $session->get($snmp_cpmCPUTotal1minRev . "." . $row->iid) if $cpu_name ne 'cpu_';
            #print "DEBUG: CPU found - $cpu_name: util " . $cpu{$cpu_name} . "\n";
         }
      }
   }

   foreach my $key (keys %cpu)
   {
      if( $cpu{$key} > $ProgramOptions{'crit'} )
      {
         push(@cpu_critical, "$key " . $cpu{$key} . "% utilization\n");
      }
      elsif( $cpu{$key} > $ProgramOptions{'warn'} )
      {
         push(@cpu_warning, "$key " . $cpu{$key} . "% utilization\n");
      }

      if( defined($ProgramOptions{'perfdata'}) )
      {
         if( $key !~ /NOSUCH/ )
         {
           $perfdata .= join('_', split(/ /, $key)) . "=" . $cpu{$key} . "%;";
           $perfdata .= $ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'} . ";0;100 ";
         }
      }
   }

   if( scalar(@cpu_critical) > 0 or scalar(@cpu_warning) > 0 )
   {
      if( scalar(@cpu_critical) > 0 )
      {
         $status = Monitor::Tools::CRITICAL;
         $output = "CRITICAL - CPU utilization over critical threshold";
      }
      else
      {
         $status = Monitor::Tools::WARNING;
         $output = "WARNING - CPU utilization over warning threshold";
      }
      $output .= " ($cpu_checked checked)\n";
      $output .= join("", @cpu_critical);
      $output .= join("", @cpu_warning);
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = "OK - CPU(s) are below utilization threshold ($cpu_checked checked)\n";
   }

   $output .= $perfdata . "\n" if defined $ProgramOptions{'perfdata'};
   return [$status, $output ];
}

sub CheckMemUtil
{
   my $session = shift;
   my $perfdata = "|";
   my $pool_count = 0;
   my %mempool;
   my @mem_critical;
   my @mem_warning;

   my $Poll_oid = { ciscoMemoryPoolUsed => $snmp_ciscoMemoryPoolUsed,
                    ciscoMemoryPoolFree => $snmp_ciscoMemoryPoolFree,
                    ciscoMemoryPoolLargestFree => $snmp_ciscoMemoryPoolLargestFree
                  };
   my $Poll_data;

   my ($snmp_ciscoMemoryPoolName_data) = $session->bulkwalk(0,10,$snmp_ciscoMemoryPoolName);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll ciscoMemoryPoolName " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_ciscoMemoryPoolName\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_ciscoMemoryPoolName_data)
   {
      if( $row->val !~ /reserved|image|Critical|Driver|lsmpi/ )
      {
         foreach my $key ( keys %$Poll_oid )
         {
            $Poll_data->{$key} = $session->get($Poll_oid->{$key} . "." . $row->iid);
            if( $session->{ErrorStr} )
            {
               $output = "UNKNOWN - Unable to poll $key " . $session->{ErrorStr} . " \n";
               $output .= $Monitor::Tools::snmp_cli . " " . $Poll_oid->{$key} . "\n";
               $status = Monitor::Tools::UNKNOWN;
               return [ $status, $output ];
            }
         }
         my $mem_total = $Poll_data->{'ciscoMemoryPoolUsed'} + $Poll_data->{'ciscoMemoryPoolFree'};
         #print "DEBUG: Mem Used " . $Poll_data->{'ciscoMemoryPoolUsed'} . "\n";
         #print "DEBUG: Mem Free " . $Poll_data->{'ciscoMemoryPoolFree'} . "\n";
         $mempool{$row->val} = sprintf("%.2f", ($Poll_data->{'ciscoMemoryPoolUsed'}/$mem_total)*100);
         if( $Poll_data->{'ciscoMemoryPoolLargestFree'}  /1024/1024 < 8 and $Poll_data->{'ciscoMemoryPoolLargestFree'} !~ /NOSUCH/ )
         {
            my $message = $row->val . " largest free block ";
            $message .= sprintf("%.2fMb\n", $Poll_data->{'ciscoMemoryPoolLargestFree'} /1024/1024);
            push(@mem_critical, $message);
         }
      }
   }

   foreach my $key (keys %mempool)
   {
      $pool_count++;
      if( $mempool{$key} > $ProgramOptions{'crit'} )
      {
         push(@mem_critical, "$key " . $mempool{$key} . "% utilization\n");
      }
      elsif( $mempool{$key} > $ProgramOptions{'warn'} )
      {
         push(@mem_warning, "$key " . $mempool{$key} . "% utilization\n");
      }

      $perfdata .= "'" . $key . "_memorypool'" . "=" . $mempool{$key} . "%;";
      $perfdata .= $ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'} . ";0;100 ";
   }

   if( scalar(@mem_critical) > 0 or scalar(@mem_warning) > 0 )
   {
      if( scalar(@mem_critical) > 0 )
      {
         $status = Monitor::Tools::CRITICAL;
         $output = "CRITICAL - Memory pool utilization over critical threshold ($pool_count pool(s) checked)\n";
      }
      else
      {
         $status = Monitor::Tools::WARNING;
         $output = "WARNING - Memory pool utilization over warning threshold ($pool_count pool(s) checked)\n";
      }
      $output .= join("",@mem_critical);
      $output .= join("",@mem_warning);
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = "OK - Memory pool(s) are below utilization threshold ($pool_count pool(s) checked)\n";
   }

   if( defined($ProgramOptions{'perfdata'}) )
   {
      $output .= $perfdata;
   }

   return [$status, $output . "\n"];
}

sub CheckTemp
{
   my $session = shift;
   my $perfdata = "|";

   my @warning;
   my @critical;

   my ($snmp_entSensorType_data) = $session->bulkwalk(0,10,$snmp_entSensorType);
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll entSensorType" . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_entSensorType\n";
      $status = Monitor::Tools::UNKNOWN;
      return [ $status, $output ];
   }

   foreach my $row ( @$snmp_entSensorType_data )
   {
      if( $row->val == 8 )
      {
         print "DEBUG: ENTSensor index - " . $row->iid . "\n";
         print "DEBUG: EntSensor name - " . $session->get($snmp_entPhysicalName . "." . $row->iid) . "\n";
      }
   }

   return [ $status, $output ];
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
      "temp",
      "perfdata"
   );
}
