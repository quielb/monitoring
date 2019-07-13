#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);
use feature 'switch';

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

#BlueCat MIBs
my $snmp_bcnDhcpv4SerOperState = '.1.3.6.1.4.1.13315.3.1.1.2.1.1.0';
my $snmp_bcnDnsSerOperState = '.1.3.6.1.4.1.13315.3.1.2.2.1.1.0';
#STD Linux MIBs ( HOST-RESOURCES, UCD-SNMP)
my $snmp_memTotalSwap = '.1.3.6.1.4.1.2021.4.3.0';
my $snmp_memAvailSwap = '.1.3.6.1.4.1.2021.4.4.0';
my $snmp_memTotalReal = '.1.3.6.1.4.1.2021.4.5.0';
my $snmp_memAvailReal = '.1.3.6.1.4.1.2021.4.6.0';
my $snmp_hrProcessorTable = '.1.3.6.1.2.1.25.3.3';
my $snmp_hrStorageDescr = '.1.3.6.1.2.1.25.2.3.1.3';
my $snmp_hrStorageSize = '.1.3.6.1.2.1.25.2.3.1.5';
my $snmp_hrStorageUsed = '.1.3.6.1.2.1.25.2.3.1.6';

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

if (defined($ProgramOptions{'dhcp'}))
{
   my $data = CheckDHCPProcess($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'dns'}))
{
   my $data = CheckDNSProcess($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'cpu'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Tools::output;
      exit $Monitor::Tools::status;
   }

   my $data = CheckCPUUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'memory'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Tools::output;
      exit $Monitor::Tools::status;
   }

   my $data = CheckMemoryUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'swap'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Tools::output;
      exit $Monitor::Tools::status;
   }

   my $data = CheckSwapUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'disk'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Tools::output;
      exit $Monitor::Tools::status;
   }

   my $data = CheckDiskUtil($session);
   print $data->[1];
   exit $data->[0];
}


print "UNKNOWN - No check method specified\n";
exit Monitor::Tools::UNKNOWN;


sub CheckDHCPProcess()
### Function to check DHCP process running on Adonis servers that have DHPC service enabled.
### Pre-Condition - Requires a valid SNMP session
### Post-Condition - Retuns array byref of std Icinga/Nagios plugin output.
###    1st element is plugin RC and 2nd element is message for STDOUT
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my $snmp_bcnDhcpv4SerOperState_data = $session->get( $snmp_bcnDhcpv4SerOperState );

   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll bcnDhcpv4SerOperState" . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_bcnDhcpv4SerOperState\n";
      return [$status, $output];
   }

   given($snmp_bcnDhcpv4SerOperState_data)
   {
      when(1) {$status = Monitor::Tools::OK; $output = "OK - DHCP service is running\n";}
      when(2) {$status = Monitor::Tools::CRITICAL; $output = "CRITICAL - DHCP service not running\n";}
      when(3) {$status = Monitor::Tools::WARNING; $output = "WARNING - DHCP service is starting\n";}
      when(4) {$status = Monitor::Tools::WARNING; $output = "WARNING - DHCP service is stopping\n";}
      when(5) {$status = Monitor::Tools::CRITICAL; $output = "CRITICAL - DHCP service has an unknown fault\n";}
      default {$status = Monitor::Tools::UNKNOWN; $output = "UNKNOWN - DHCP Status MIB did not return data in range $snmp_bcnDhcpv4SerOperState_data\n";}
   }

   return [$status,$output]
}

sub CheckDNSProcess()
### Function to check DHCP process running on Adonis servers that have DHPC service enabled.
### Pre-Condition - Requires a valid SNMP session
### Post-Condition - Retuns array byref of std Icinga/Nagios plugin output.
###    1st element is plugin RC and 2nd element is message for STDOUT
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my $snmp_bcnDnsSerOperState_data = $session->get( $snmp_bcnDnsSerOperState );

   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll bcnDnsSerOperState" . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_bcnDnsSerOperState\n";
      return [$status, $output];
   }

   given($snmp_bcnDnsSerOperState_data)
   {
      when(1) {$status = Monitor::Tools::OK; $output = "OK - DNS service is running\n";}
      when(2) {$status = Monitor::Tools::CRITICAL; $output = "CRITICAL - DNS service not running\n";}
      when(3) {$status = Monitor::Tools::WARNING; $output = "WARNING - DNS service is starting\n";}
      when(4) {$status = Monitor::Tools::WARNING; $output = "WARNING - DNS service is stopping\n";}
      when(5) {$status = Monitor::Tools::CRITICAL; $output = "CRITICAL - DNS service has an unknown fault\n";}
      default {$status = Monitor::Tools::UNKNOWN; $output = "UNKNOWN - DNS Status MIB did not return data in range $snmp_bcnDnsSerOperState_data\n";}
   }

   return [$status,$output]
}

sub CheckCPUUtil()
### Function to check CPU usage on Adonis servers.
### Pre-Condition - Requires a valid SNMP session
### Post-Condition - Retuns array byref of std Icinga/Nagios plugin output.
###    1st element is plugin RC and 2nd element is message for STDOUT
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;
   my $perfdata;

   my $snmp_hrProcessorLoad_oid = '.1.3.6.1.2.1.25.3.3.1.2';
   my $cpuutil = 0;

   my ($snmp_hrProcessorLoad_data) = $session->bulkwalk( 0,10,$snmp_hrProcessorLoad_oid );
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll hrProcessorLoad " . $session->{ErrorStr} . " \n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_hrProcessorLoad_oid\n";
      $status = Monitor::Tools::UNKNOWN;
   }

   my $cpucount = scalar(@$snmp_hrProcessorLoad_data);

   for my $i ( 0..(@{$snmp_hrProcessorLoad_data}-1) )
   {
      $cpuutil += $snmp_hrProcessorLoad_data->[$i]->val;
      $perfdata .= "cpu_$i=" . $snmp_hrProcessorLoad_data->[$i]->val . "%;$ProgramOptions{'warn'};$ProgramOptions{'crit'};0 ";
   }

   $cpuutil = $cpuutil/$cpucount;

   if ( $cpuutil >= $ProgramOptions{'crit'})
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
   }
   elsif ( $cpuutil >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Tools::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Tools::OK;
   }

   $output .= "CPU utilization $cpuutil% ($cpucount found)\n";
   if (defined($ProgramOptions{'perfdata'}))
   {
      $output .= "|$perfdata\n";
   }

   return [$status,$output];
}

sub CheckMemoryUtil()
### Function to check CPU usage on Adonis servers.
### Pre-Condition - Requires a valid SNMP session
### Post-Condition - Retuns array byref of std Icinga/Nagios plugin output.
###    1st element is plugin RC and 2nd element is message for STDOUT
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my %Poll_OID = ( 'memTotalReal' => $snmp_memTotalReal, 'memAvailReal' => $snmp_memAvailReal );
   my %Poll_Data;

   foreach my $key ( keys %Poll_OID )
   {
      $Poll_Data{$key} = $session->get($Poll_OID{$key});
      #print "DEBUG: $key - $Poll_Data{$key}\n";
      if( not defined($Poll_Data{$key}) )
      {
         print "UNKNOWN - Unable to poll $key\n";
         print $Monitor::Tools::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Tools::UNKNOWN;
      }
      if( $Poll_Data{$key} =~ /NOSUCH/ )
      {
         print "UNKNOWN - OID($Poll_OID{$key}) does not exist on given host\n";
         print $Monitor::Tools::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Tools::UNKNOWN;
      }
   }


   my $memused = int(($Poll_Data{'memTotalReal'} - $Poll_Data{'memAvailReal'}) / $Poll_Data{'memTotalReal'} * 100);

   if ($memused >= $ProgramOptions{'crit'})
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
   }
   elsif($memused >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Tools::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Tools::OK;
   }

   $output .= "$memused% Real Memory Used\n";

   return [$status,$output];

}


sub CheckSwapUtil()
### Function to check swap usage on Adonis servers.
### Pre-Condition - Requires a valid SNMP session
### Post-Condition - Retuns array byref of std Icinga/Nagios plugin output.
###    1st element is plugin RC and 2nd element is message for STDOUT
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my %Poll_OID = ( 'memTotalSwap' => $snmp_memTotalSwap, 'memAvailSwap' => $snmp_memAvailSwap );
   my %Poll_Data;

   foreach my $key ( keys %Poll_OID )
   {
      $Poll_Data{$key} = $session->get($Poll_OID{$key});
      #print "DEBUG: $key - $Poll_Data{$key}\n";
      if( not defined($Poll_Data{$key}) )
      {
         print "UNKNOWN - Unable to poll $key\n";
         print $Monitor::Tools::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Tools::UNKNOWN;
      }
      if( $Poll_Data{$key} =~ /NOSUCH/ )
      {
         print "UNKNOWN - OID($Poll_OID{$key}) does not exist on given host\n";
         print $Monitor::Tools::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Tools::UNKNOWN;
      }
   }

   my $swapused = int(($Poll_Data{'memTotalSwap'} - $Poll_Data{'memAvailSwap'}) / $Poll_Data{'memTotalSwap'} * 100);
   if ($swapused >= $ProgramOptions{'crit'})
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
   }
   elsif($swapused >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Tools::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Tools::OK;
   }
   $output .= "$swapused% Swap Memory Used (";
   $output .= int(($Poll_Data{'memTotalSwap'} - $Poll_Data{'memAvailSwap'}) / 1024) . " MB of ";
   $output .= int($Poll_Data{'memTotalSwap'} / 1024) . " MB)\n";

   if ( defined($ProgramOptions{'perfdata'}))
   {
      $output .= "|swap=$swapused%;$ProgramOptions{'warn'};$ProgramOptions{'crit'};0\n";
   }

   return [$status,$output];

}

sub CheckDiskUtil()
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my @critical_disk;
   my @warning_disk;
   my @ok_disk;

   my ($hrStorageDescr_data, $hrStorageSize_data, $hrStorageUsed_data ) = $session->bulkwalk( 0, 10, [ [$snmp_hrStorageDescr], [$snmp_hrStorageSize], [$snmp_hrStorageUsed] ] );

   for my $i ( 0..(@{$hrStorageDescr_data}-1) )
   {
      if( $hrStorageDescr_data->[$i]->val =~ /\/.*$/ )
      {
         my $disk_used;
         my $disk_size;
         for my $j ( 0..(@{$hrStorageSize_data}-1) )
         {
            if( $hrStorageDescr_data->[$i]->iid == $hrStorageSize_data->[$j]->iid )
            {
               $disk_size = $hrStorageSize_data->[$j]->val;
            }
         }
         for my $j ( 0..(@{$hrStorageUsed_data}-1) )
         {
            if( $hrStorageDescr_data->[$i]->iid == $hrStorageUsed_data->[$j]->iid )
            {
               $disk_used = $hrStorageUsed_data->[$j]->val;
            }
         }

         #print "DEBUG: Volume - " . $hrStorageDescr_data->[$i]->val . "\n";
         #print "DEBUG: Used - $disk_used\n";
         #print "DEBUG: Size - $disk_size\n";
         if( ($disk_used / $disk_size)*100 >= $ProgramOptions{'crit'} )
         {
            my $diskused = int($disk_used / $disk_size *100);
            push( @critical_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
         elsif( ($disk_used / $disk_size)*100 >= $ProgramOptions{'warn'} )
         {
            my $diskused = int($disk_used / $disk_size *100);
            push( @warning_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
         else
         {
            my $diskused = int($disk_used / $disk_size *100);
            push( @ok_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
      }
   }

   if( scalar(@critical_disk) > 0 )
   {
      $output = "CRITICAL - ";
      $status = Monitor::Tools::CRITICAL;
   }
   elsif( scalar(@warning_disk) > 0 )
   {
      $output = "WARNING - ";
      $status = Monitor::Tools::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Tools::OK;
   }

   $output .= join(" ", @critical_disk) . " " if scalar(@critical_disk) > 0;
   $output .= join(" ", @warning_disk) . " " if scalar(@warning_disk) > 0;
   $output .= join(" ", @ok_disk);
   $output .= "\n";

   return [$status,$output];
}

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      'H|hostname=s',
      'C|community=s',
      'warn|w=i',
      'crit|c=i',
      'cpu',
      'memory',
      'dhcp',
      'dns',
      'swap',
      'disk',
      'perfdata'
   );
}

