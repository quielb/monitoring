#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_rPDU2SensorTempHumidityStatusCommStatus = ".1.3.6.1.4.1.318.1.1.26.10.2.2.1.6"; # powernet417.mib
my $snmp_rPDU2SensorTempHumidityStatusTempF = ".1.3.6.1.4.1.318.1.1.26.10.2.2.1.7"; # powernet417.mib

my %ProgramOptions;
ParseOptions();

if( not check_threshold($ProgramOptions{'warn'}, $ProgramOptions{'crit'}))
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $status;
my $output;

my ($snmp_rPDU2SensorTempHumidityStatusCommStatus_data) = $session->bulkwalk(0,25,[$snmp_rPDU2SensorTempHumidityStatusCommStatus]);
if( $session->{ErrorStr} )
{
   print "UNKNOWN - Unable to poll rPDU2SensorTempHumidityStatusCommStatus " . $session->{ErrorStr} . " \n";
   print $Monitor::Tools::snmp_cli . " $snmp_rPDU2SensorTempHumidityStatusCommStatus\n";
   exit Monitor::Tools::UNKNOWN;
}

### Although the PDU only supports one sensor the data is in a table.  So grab the table and loop through it.
### React on the first sensor found
foreach my $row ( @$snmp_rPDU2SensorTempHumidityStatusCommStatus_data )
{
   ### 1 - notInstalled
   ### 2 - commsOK
   ### 3 - commsLost
   if( $row->val == 2 )
   {
      my $snmp_rPDU2SensorTempHumidityStatusTempF_data = $session->get($snmp_rPDU2SensorTempHumidityStatusTempF . "." . $row->iid);
      ### divide by ten because data returned is tenths of degrees Fahrenheit
      $snmp_rPDU2SensorTempHumidityStatusTempF_data = $snmp_rPDU2SensorTempHumidityStatusTempF_data / 10;
      if( $snmp_rPDU2SensorTempHumidityStatusTempF_data > $ProgramOptions{'crit'} )
      {
         $output = "CRITICAL - Temperature " . $snmp_rPDU2SensorTempHumidityStatusTempF_data . "F ";
         $output .= "is over threshold (" . $ProgramOptions{'crit'} . "F)\n";
         $status = Monitor::Tools::CRITICAL;
      }
      elsif( $snmp_rPDU2SensorTempHumidityStatusTempF_data > $ProgramOptions{'warn'} )
      {
         $output = "WARNING - " . $snmp_rPDU2SensorTempHumidityStatusTempF_data . "F ";
         $output .= "is over threshold (" . $ProgramOptions{'warn'} . "F)\n";
         $status = Monitor::Tools::WARNING;
      }
      else
      {
         $output = "OK - " . $snmp_rPDU2SensorTempHumidityStatusTempF_data . "F ";
         $output .= "is under threshold (" . $ProgramOptions{'warn'} . "F)\n";
         $status = Monitor::Tools::OK;
      }

      if( defined($ProgramOptions{'perfdata'}) )
      {
         $output .= "|temperature=$snmp_rPDU2SensorTempHumidityStatusTempF_data";
         $output .= ";" .$ProgramOptions{'warn'} . ";" . $ProgramOptions{'crit'} . "\n";
      }
      print $output;
      exit $status;
   }
   ### Don't really care if there is no probe installed, so that should be an okay state.
   elsif( $row->val == 1 )
   {
      print "OK - No temperature probe installed\n";
      exit Monitor::Tools::OK;
   }
   else
   {
      print "UNKNOWN - There is a problem communitating with the temperature probe\n";
      exit Monitor::Tools::UNKNOWN;
   }
}

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "warn=i",
      "crit=i",
      "perfdata",
   );
}

