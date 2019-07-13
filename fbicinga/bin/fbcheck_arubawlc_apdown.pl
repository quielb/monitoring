#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

### Add OIDs that you are interested in here. If you use a get_table call place the
### table OID here and append the remainder of the OID to the hash key you are looking for
### If it is just a get_request then put the full OID.
### format is $snmp_<OID-NAME from MIB>
my $snmp_wlsxWlanAPTable = '.1.3.6.1.4.1.14823.2.2.1.5.2.1.4'; #aruba-wlan.my
my $snmp_wlanAPName = '.1.3.6.1.4.1.14823.2.2.1.5.2.1.4.1.3'; # aruba-wlan.my
my $snmp_wlanAPStatus = '.1.3.6.1.4.1.14823.2.2.1.5.2.1.4.1.19'; # aruba-wlan.my
my $snmp_wlsxSysExtSwitchRole = '.1.3.6.1.4.1.14823.2.2.1.2.1.4.0'; # aruba-wlan.my
my $snmp_wlanAPGroupName = '.1.3.6.1.4.1.14823.2.2.1.5.2.1.4.1.4'; # aruba-wlan.my

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

if( not check_threshold($ProgramOptions{'warn'},$ProgramOptions{'crit'}) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $status = Monitor::Tools::OK; # Program return code that is interpreted by Icinga/Nagios to determine status
my $output; # string to contain the plugin out.  Printed to STDOUT just before exiting

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}


my %APGroup; # Contins info about APs known to a controller. Total APs how many are down etc..
my $aptotal_count = 0;
my $aptotal_monitored = 0;
my $apdown_count = 0;

### Lets check the controler state.  If it is standby then just dump out.  Standby controllers
### don't have APs "known" or in their AP database.
my $wlsxSysExtSwitchRole_data = $session->get($snmp_wlsxSysExtSwitchRole);
if( $session->{ErrorStr} )
{
   print "UNKNOWN - Unable to get wireless controller state " . $session->{ErrorStr} . "\n";
   exit Monitor::Tools::UNKNOWN;
}
if( $wlsxSysExtSwitchRole_data == 3 )
{
   print "OK - Wireless controller is currently in standby state. No APs known\n";
   exit Monitor::Tools::OK;;
}
### So this controller isn't standby.  Lets take a look at the APs known to it.
else
{
   ### Only pull the colums out of the APStatus table.  Pulling everything is too slow and all that other
   ### stuff we don't care about.
   my ($snmp_wlanAPStatus_data, $snmp_wlanAPName_data, $snmp_wlanAPGroupName_data);
   my $ra_group;
   if (defined($ProgramOptions{'region'}))
   {
      if ($ProgramOptions{'region'} !~ /^(apac|amer_east|amer_west|emea)$/)
      {
         print "UNKNOWN - unsupported region " . $ProgramOptions{'region'} . "\n";
         exit Monitor::Tools::UNKNOWN;
      }
      $ra_group = "MGD-OFFICE-" . $ProgramOptions{'region'};
      $ra_group =~ s/_//g;
      $ra_group = uc($ra_group);
      ($snmp_wlanAPStatus_data, $snmp_wlanAPName_data, $snmp_wlanAPGroupName_data) = $session->bulkwalk(0,15, [ [$snmp_wlanAPStatus], [$snmp_wlanAPName], [$snmp_wlanAPGroupName]]);
   }
   else
   {
      ($snmp_wlanAPStatus_data, $snmp_wlanAPName_data) = $session->bulkwalk(0,15, [ [$snmp_wlanAPStatus], [$snmp_wlanAPName]]);
   }
   if( $session->{ErrorStr} )
   {
      $output = "UNKNOWN - Unable to poll wlsxWlanAPTable " . $session->{ErrorStr} . "\n";
      $output .= $Monitor::Tools::snmp_cli . " .1.3.6.1.4.1.14823.2.2.1.5.2.1.4\n";
      print $output;
      exit Monitor::Tools::UNKNOWN;
   }

   $aptotal_count = scalar(@$snmp_wlanAPName_data);

   ### Go through all the APs we found.  Group them together by name.  This solves the campus and ra issues.
   ### The down percentage is base on the numbers for each group and not just a total % of all the APs on the
   ### controller.
   for my $i  ( 0..(@{$snmp_wlanAPName_data}-1) )
   {
      ### Check if the AP name is one of the APs we care about.  If it is, add it to the list
      next if ( $$snmp_wlanAPName_data[$i]->val =~ /EMP|EVENT|ALLHAND|:|TEST|Test/ );
      my $GroupName_key;
      if (defined($ProgramOptions{'region'}))
      {
         # When running regional checks we're only interested in the expected RA
         # group for that region.
         next unless ($$snmp_wlanAPGroupName_data[$i]->val =~ /$ra_group/);
         $GroupName_key = $$snmp_wlanAPGroupName_data[$i]->val;
      }
      else
      {
          $GroupName_key = (split(/\./, $$snmp_wlanAPName_data[$i]->val))[0];
      }

      ### If the counts for the group aren't defined we need to create them and set them to zero.
      ### Its hard to due numeric compairisons in undef values.
      if( not defined($APGroup{$GroupName_key}{'Total'}) )
      {
         $APGroup{$GroupName_key}{'Total'} = 0;
      }
      if( not defined($APGroup{$GroupName_key}{'Down'}) )
      {
         $APGroup{$GroupName_key}{'Down'} = 0;
      }
      ### Increment group total
      $APGroup{$GroupName_key}{'Total'}++;

      ### Status of 2 means down.
      if( $$snmp_wlanAPStatus_data[$i]->val == 2 )
      {
         my $APdown_info = "  " . $$snmp_wlanAPName_data[$i]->val . " ";

         ### Increment group down count
         $APGroup{$GroupName_key}{'Down'}++;

         ### The MAC address of the AP is coded in the OID.  Need to convert from hex to dec
         ### and create a string out of it so we have the MAC address of the AP in the alert
         for( my $j=-6; $j<0; $j++ )
         {
            if( $j == -1 )
            {
               $APdown_info .= sprintf("%02x", (split(/\./, $$snmp_wlanAPName_data[$i]->[0]))[$j]);
            }
            else
            {
               $APdown_info .= sprintf("%02x:", (split(/\./, $$snmp_wlanAPName_data[$i]->[0]))[$j]);
            }
         }
         ### We have the down AP name and MAC address push it onto a list that is included in the alert
         push( @{$APGroup{$GroupName_key}{'Data'}}, $APdown_info);

      }
   }


   ### Now that all info is collect and grouped about the APs on a controller, do math to figure out
   ### how many are down
   foreach my $key (keys %APGroup)
   {
      if( $APGroup{$key}{'Down'} / $APGroup{$key}{'Total'} *100 > $ProgramOptions{'crit'} )
      {
         $status = Monitor::Tools::CRITICAL;
      }
      elsif( $APGroup{$key}{'Down'} / $APGroup{$key}{'Total'} *100 > $ProgramOptions{'warn'} )
      {
         ### If status is already critical we need to check so we don't lower it to warning
         if( $status < Monitor::Tools::CRITICAL )
         {
            $status = Monitor::Tools::WARNING;
         }
      }
      ### If there are down APs we want that added to the status data.  That way all down
      ### APs for each group are listed regardless of what the alert state is.
      if( $APGroup{$key}{'Down'} != 0 )
      {
         $output .= "Group $key has $APGroup{$key}{'Down'} of $APGroup{$key}{'Total'} APs down ";
         $output .= sprintf("(%.0f%)\n",  $APGroup{$key}{'Down'} / $APGroup{$key}{'Total'} *100);
         foreach my $apdata (@{$APGroup{$key}{'Data'}})
         {
            $output .= "$apdata\n";
         }
      }
   }
}

### Put together some summary output for the status detail.
foreach my $key (keys %APGroup)
{
   $apdown_count += $APGroup{$key}{'Down'};
   $aptotal_monitored += $APGroup{$key}{'Total'};
}
### Since all the detail information was catured.  Prepend the summary data
if ($aptotal_monitored == 0)
{
   $output = "0 of $aptotal_count known APs are monitored";
}
else
{
   $output = "$apdown_count APs down. $aptotal_monitored APs monitored. $aptotal_count APs known.\n" . $output;
}

if ( $status == Monitor::Tools::CRITICAL )
{
   print "CRITICAL - " . $output;
   exit $status;
}
elsif( $status == Monitor::Tools::WARNING )
{
   print "WARNING - " . $output;
   exit $status;
}
else
{
   print "OK - $output\n";  # Send you plugin test to STDOUT.
   exit $status;
}

sub ParseOptions

{
   GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      'warn|w=i',
      'crit|c=i',
      'region|r:s',
   );

   # To simplify icinga configs, we always pass a region in, but it is only set if the host is an ra-wlc.
   # Strip the param here so we can easly differentiate what type of host we're checking with if defined()
   delete $ProgramOptions{'region'} if ($ProgramOptions{'region'} eq "");
}
