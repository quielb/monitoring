#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_wlsxSysExtProcessorTable = '.1.3.6.1.4.1.14823.2.2.1.2.1.13.1';
my $snmp_wlsxSysExtMemoryTable = '.1.3.6.1.4.1.14823.2.2.1.2.1.15.1';
my $snmp_wlsxExtCardTable = '.1.3.6.1.4.1.14823.2.2.1.2.1.16';
my $snmp_sysExtFanStatus = '.1.3.6.1.4.1.14823.2.2.1.2.1.17.1.2';
my $snmp_wlsxExtPowerSupplyTable = '.1.3.6.1.4.1.14823.2.2.1.2.1.18.1';


my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

if (defined($ProgramOptions{'cpu'}) or defined($ProgramOptions{'memory'}))
{
   my $error = 0;
   if( !defined($ProgramOptions{'warn'}) or !defined($ProgramOptions{'crit'}) )
   {
      $error = 1;
      print "UNKNOWN - Thresholds not defined\n";
   }
   elsif( $ProgramOptions{'warn'} == -1 or $ProgramOptions{'crit'} == -1 )
   {
      $error = 1;
      print "UNKNOWN - Threshold value not defined\n";
   }
   elsif( $ProgramOptions{'warn'} > $ProgramOptions{'crit'} )
   {
      $error = 1;
      print "UNKNOWN - Warning threshold must be greater then critical threshold\n";
   }
   if( $error )
   {
      exit Monitor::Tools::UNKNOWN;
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


sub CheckCPUUtil()
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my %CPUName;
   my %CPUUtil;
   my %CPUcrit;
   my %CPUwarn;

   my ($name, $load) = $session->bulkwalk(0,10, [[$snmp_wlsxSysExtProcessorTable . ".2"], [$snmp_wlsxSysExtProcessorTable . ".3"]]);

   if( $session->{ErrorStr} )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll wlsxSysExtProcessorTable " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_wlsxSysExtProcessorTable\n";
      return [$status, $output];
   }

   for my $i  ( 0..(@{$name}-1) )
   {
      $CPUName{$$name[$i]->iid} = $$name[$i]->val;
      $CPUUtil{$$load[$i]->iid} = $$load[$i]->val;
   }

   foreach my $key (keys %CPUUtil)
   {
      if( $CPUUtil{$key} >= $ProgramOptions{'crit'} )
      {
         $CPUcrit{$CPUName{$key}} = $CPUUtil{$key};
      }
      elsif( $CPUUtil{$key} >= $ProgramOptions{'warn'} )
      {
         $CPUwarn{$CPUName{$key}} = $CPUUtil{$key};
      }
   }

   if( scalar(keys %CPUcrit) > 0 )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL - CPU Utilization over threshold\n";
      foreach my $key (keys %CPUcrit)
      {
         $output .= $key . " " . $CPUcrit{$key} . "% utilization\n";
      }
   }
   elsif( scalar(keys %CPUwarn) > 0 )
   {
      $status = Monitor::Tools::WARNING;
      $output = "WARNING - CPU Utilization over threshold\n";
      foreach my $key (keys %CPUwarn)
      {
         $output .= $key . " " . $CPUwarn{$key} . "% utilization\n";
      }
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = "OK - CPU utilization below threshold\n";
   }

   if( defined($ProgramOptions{'perfdata'}) )
   {
      $output .= "|";
      foreach my $key (keys %CPUUtil)
      {
         $output .= lc(join('_', split(/ /, $CPUName{$key}))) . "=" . $CPUUtil{$key} . ";";
         $output .= $ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'} . " ";
      }
      $output .= "\n";
   }
   return [$status, $output];
}

sub CheckMemUtil()
{

   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   my $mem_total;
   my $mem_used;

   my ($snmp_wlsxSysExtMemoryTable_data) = $session->bulkwalk(0,10,$snmp_wlsxSysExtMemoryTable );

   if( $session->{ErrorStr} )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll wlsxSysExtMemoryTable " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_wlsxSysExtMemoryTable\n";
      return [$status, $output];
   }


   foreach my $data (@$snmp_wlsxSysExtMemoryTable_data)
   {

      if( $data->[0] =~ /.2$/ )
      {
         $mem_total = $data->val;
      }
      elsif( $data->[0] =~ /.3$/ )
      {
         $mem_used = $data->val;
      }
   }

   if( $mem_total == 0 )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll wlsxSysExtMemoryTable " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_wlsxSysExtMemoryTable\n";
   }
   elsif( $mem_used/$mem_total*100 > $ProgramOptions{'crit'} )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = sprintf("CRITICAL - Memory Usage %.00f%%\n", $mem_used/$mem_total*100);

   }
   elsif( $mem_used/$mem_total*100 > $ProgramOptions{'warn'} )
   {
      $status = Monitor::Tools::WARNING;
      $output = sprintf("WARNING - Memory Usage %.00f%%\n", $mem_used/$mem_total*100);
   }
   else
   {
      $status = Monitor::Tools::OK;
      $output = sprintf("OK - Memory Usage %.00f%%\n", $mem_used/$mem_total*100);
   }

   return [$status, $output];
}

sub CheckModule()
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status;
   my $output;

   $status = Monitor::Tools::OK;
   $output = "OK - If the module went down we would have other problems\n";
   return [$status, $output];
}

sub CheckFan()
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status = Monitor::Tools::OK;
   my $output = "OK - All fans are functional";
   my $count = 0;
   my $error = 0;

   my ($snmp_sysExtFanStatus_data) = $session->bulkwalk(0,10, $snmp_sysExtFanStatus );

   if( $session->{ErrorStr} )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll sysExtFanStatus " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_sysExtFanStatus\n";
      return [$status, $output];
   }

   foreach my $data (@$snmp_sysExtFanStatus_data)
   {
      $count++;
      if($data->val != 1)
      {
         $error = 1;
      }
   }

   if( $error )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL - This device has one or more failed fans";
   }

   $output .= " ($count checked)\n" if defined($snmp_sysExtFanStatus_data);

   return [$status, $output];
}

sub CheckPowerSupply()
{
   my $session = shift;

   ### Standard return variables.  Return as an anonymous array reference
   my $status = Monitor::Tools::OK;
   my $output = "OK - All power supplies are functional";
   my $count = 0;

   my $error = 0;
   my ($snmp_wlsxSysExtPowerSupplyTable_data) = $session->bulkwalk(0,10, $snmp_wlsxExtPowerSupplyTable );

   if( $session->{ErrorStr} )
   {
      $status = Monitor::Tools::UNKNOWN;
      $output = "UNKNOWN - Unable to poll wlsxSysExtPowerSupplyTable\n";
      $output .= $Monitor::Tools::snmp_cli . " $snmp_wlsxExtPowerSupplyTable\n";
      return [$status, $output];
   }

   foreach my $data (@$snmp_wlsxSysExtPowerSupplyTable_data)
   {
      $count++;
      if($data->val != 1)
      {
         $error = 1;
      }
   }

   if( $error )
   {
      $status = Monitor::Tools::CRITICAL;
      $output = "CRITICAL - This device has a missing or non-function power supply";
   }

   $output .= " ($count checked)\n" if $status != Monitor::Tools::UNKNOWN;

   return [$status, $output];
}

print "UNKNOWN - Got to end.  You shouldn't be here\n";
exit Monitor::Tools::UNKNOWN;  # And finally exit with the state of your check

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      "warn|w:-1",
      "crit|c:-1",
      "cpu",
      "memory",
      "module",
      "fan",
      "power",
      "perfdata"
   );
}

