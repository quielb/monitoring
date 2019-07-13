#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Health;

#STD Linux MIBs ( HOST-RESOURCES, UCD-SNMP)
my $snmp_memTotalSwap = '.1.3.6.1.4.1.2021.4.3.0';
my $snmp_memAvailSwap = '.1.3.6.1.4.1.2021.4.4.0';
my $snmp_memTotalReal = '.1.3.6.1.4.1.2021.4.5.0';
my $snmp_memAvailReal = '.1.3.6.1.4.1.2021.4.6.0';
my $snmp_hrProcessorTable = '.1.3.6.1.2.1.25.3.3';
my $snmp_hrStorageType = '.1.3.6.1.2.1.25.2.3.1.2';
my $snmp_hrStorageDescr = '.1.3.6.1.2.1.25.2.3.1.3';
my $snmp_hrStorageSize = '.1.3.6.1.2.1.25.2.3.1.5';
my $snmp_hrStorageUsed = '.1.3.6.1.2.1.25.2.3.1.6';

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Health::output;
   exit $Monitor::Health::status;
}

if (defined($ProgramOptions{'cpu'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Health::output;
      exit $Monitor::Health::status;
   }

   my $data = CheckCPUUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'memory'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Health::output;
      exit $Monitor::Health::status;
   }

   my $data = CheckMemoryUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'swap'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Health::output;
      exit $Monitor::Health::status;
   }

   my $data = CheckSwapUtil($session);
   print $data->[1];
   exit $data->[0];
}

if (defined($ProgramOptions{'disk'}))
{
   if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
   {
      print $Monitor::Health::output;
      exit $Monitor::Health::status;
   }

   my $data = CheckDiskUtil($session);
   print $data->[1];
   exit $data->[0];
}


print "UNKNOWN - No check method specified\n";
exit Monitor::Health::UNKNOWN;


sub CheckCPUUtil()
### Function to check CPU usage on Linux servers.
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
      $output .= $Monitor::Health::snmp_cli . " $snmp_hrProcessorLoad_oid\n";
      $status = Monitor::Health::UNKNOWN;
   }

   if(scalar(@$snmp_hrProcessorLoad_data) == 0)
   {
      $output = "UNKNOWN - Oops, it looks like this host doesn't implement the standard host resources mib.\n";
      $status = Monitor::Health::UNKNOWN;
      return [$status, $output];
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
      $status = Monitor::Health::CRITICAL;
   }
   elsif ( $cpuutil >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Health::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Health::OK;
   }

   $output .= "CPU utilization $cpuutil% ($cpucount found)\n";
   if (defined($ProgramOptions{'perfdata'}))
   {
      $output .= "|$perfdata\n";
   }

   return [$status,$output];
}

sub CheckMemoryUtil()
### Function to check memory usage on Linux servers.
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
         print $Monitor::Health::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Health::UNKNOWN;
      }
      if( $Poll_Data{$key} =~ /NOSUCH/ )
      {
         print "UNKNOWN - OID($Poll_OID{$key}) does not exist on given host\n";
         print $Monitor::Health::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Health::UNKNOWN;
      }
   }


   my $memused = int(($Poll_Data{'memTotalReal'} - $Poll_Data{'memAvailReal'}) / $Poll_Data{'memTotalReal'} * 100);

   if ($memused >= $ProgramOptions{'crit'})
   {
      $output = "CRITICAL - ";
      $status = Monitor::Health::CRITICAL;
   }
   elsif($memused >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Health::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Health::OK;
   }

   $output .= "$memused% Real Memory Used\n";

   if( defined($ProgramOptions{'perfdata'}) )
   {
      $output .= "|";
      $output .= "memory=" . $memused;
      $output .= ";" . $ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'};
   }

   return [$status,$output . "\n"];

}


sub CheckSwapUtil()
### Function to check swap usage on Linux servers.
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
         print $Monitor::Health::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Health::UNKNOWN;
      }
      if( $Poll_Data{$key} =~ /NOSUCH/ )
      {
         print "UNKNOWN - OID($Poll_OID{$key}) does not exist on given host\n";
         print $Monitor::Health::snmp_cli . " " . $Poll_OID{$key} . "\n";
         exit Monitor::Health::UNKNOWN;
      }
   }

   my $swapused = int(($Poll_Data{'memTotalSwap'} - $Poll_Data{'memAvailSwap'}) / $Poll_Data{'memTotalSwap'} * 100);
   if ($swapused >= $ProgramOptions{'crit'})
   {
      $output = "CRITICAL - ";
      $status = Monitor::Health::CRITICAL;
   }
   elsif($swapused >= $ProgramOptions{'warn'})
   {
      $output = "WARNING - ";
      $status = Monitor::Health::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Health::OK;
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
   my $disks;

   my ($hrStorageType_data, $hrStorageDescr_data, $hrStorageSize_data, $hrStorageUsed_data )
       = $session->bulkwalk( 0, 10, [ [$snmp_hrStorageType], [$snmp_hrStorageDescr], [$snmp_hrStorageSize], [$snmp_hrStorageUsed] ] );

   if( $session->{ErrorStr} )
   {
      ### It didn't exist so exit out UNKNOWN.  Hopefully $errortxt has something useful
      $status = Monitor::Health::UNKNOWN;
      $output = "UNKNOWN - Unable to poll hrStorage table " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Health::snmp_cli . " $snmp_hrStorageType\n";
      return [$status, $output];
   }

   for my $i ( 0..(@{$hrStorageType_data}-1) )
   {
      my $disk_used;
      my $disk_size;
      if( $hrStorageType_data->[$i]->val eq '.1.3.6.1.2.1.25.2.1.4' )
      {
         for my $j ( 0..(@{$hrStorageDescr_data}-1) )
         {
            if( $hrStorageDescr_data->[$j]->iid == $hrStorageType_data->[$i]->iid )
            {
               for my $k ( 0..(@{$hrStorageSize_data}-1) )
               {
                  if( $hrStorageDescr_data->[$j]->iid == $hrStorageSize_data->[$k]->iid )
                  {
                     $disk_size = $hrStorageSize_data->[$j]->val;
                  }
               }
               for my $k ( 0..(@{$hrStorageUsed_data}-1) )
               {
                  if( $hrStorageDescr_data->[$j]->iid == $hrStorageUsed_data->[$k]->iid )
                  {
                     $disk_used = $hrStorageUsed_data->[$k]->val;
                  }
               }
            }
         }

         #print "DEBUG: Volume - " . $hrStorageDescr_data->[$i]->val . "\n";
         #print "DEBUG: Used - $disk_used\n";
         #print "DEBUG: Size - $disk_size\n";

         my $diskused = int($disk_used / $disk_size *100);
         if( ($disk_used / $disk_size)*100 >= $ProgramOptions{'crit'} )
         {
            push( @critical_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
         elsif( ($disk_used / $disk_size)*100 >= $ProgramOptions{'warn'} )
         {
            push( @warning_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
         else
         {
            push( @ok_disk, $hrStorageDescr_data->[$i]->val . ": $diskused% Disk Used");
         }
         $disks->{$hrStorageDescr_data->[$i]->val} = $diskused;
      }
   }


   if( scalar(@critical_disk) == 0 and scalar(@warning_disk) == 0 and scalar(@ok_disk) == 0 )
   {
      $output = "UNKNOWN - Ooops no disk usage data found.  Does this host implement hrStorage?\n";
      $status = Monitor::Health::UNKNOWN;
      return [$status,$output];
   }
     
   if( scalar(@critical_disk) > 0 )
   {
      $output = "CRITICAL - ";
      $status = Monitor::Health::CRITICAL;
   }
   elsif( scalar(@warning_disk) > 0 )
   {
      $output = "WARNING - ";
      $status = Monitor::Health::WARNING;
   }
   else
   {
      $output = "OK - ";
      $status = Monitor::Health::OK;
   }

   $output .= join(" ", @critical_disk) . " " if scalar(@critical_disk) > 0;
   $output .= join(" ", @warning_disk) . " " if scalar(@warning_disk) > 0;
   $output .= join(" ", @ok_disk);
   $output .= "\n";

   if( defined($ProgramOptions{'perfdata'}))
   {
      $output .= "|";
      foreach my $key (keys %$disks)
      {
         $output .= "$key=" . $disks->{$key};
         $output .= ";" .$ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'} . " ";
      }
   }

   return [$status,$output . "\n"];
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
      'swap',
      'disk',
      'perfdata'
   );
}

