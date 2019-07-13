#!/usr/bin/perl

use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_wlsxAuthenticationServerTable = '.1.3.6.1.4.1.14823.2.2.1.8.1.1'; #aruba-auth.my
my $snmp_authServerType = '.1.3.6.1.4.1.14823.2.2.1.8.1.1.1.2'; #aruba-auth.my
my $snmp_authServerState = '.1.3.6.1.4.1.14823.2.2.1.8.1.1.1.7'; #aruba-auth.my
my $snmp_authServerInservice = '.1.3.6.1.4.1.14823.2.2.1.8.1.1.1.8'; #aruba-auth.my

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

my $output;
my $status = Monitor::Tools::OK;

my $session = snmp_connect($ProgramOptions{'H'}, $ProgramOptions{'C'} );  # SNMP Session to be used for the entire plugin

if( not defined($session) )
{
   print $Monitor::Tools::output;
   exit $Monitor::Tools::status;
}

my $snmp_wlsxAuthenticationServerTable_data = $session->bulkwalk(0,15,[[$snmp_authServerType],[$snmp_authServerState],[$snmp_authServerInservice]]);
my @rad_server_not_enabled;
my @rad_server_not_inservice;
my $rad_server_count = 0; #Count the Radius servers

if( $session->{ErrorStr} )
{
   print "UNKNOWN - Unable to poll wlsxAuthenticationServerTable. " . $session->{ErrorStr} . "\n";
   print $Monitor::Tools::snmp_cli . " $snmp_wlsxAuthenticationServerTable\n";
   exit Monitor::Tools::UNKNOWN;
}

for my $i  ( 0..(@{$snmp_wlsxAuthenticationServerTable_data->[0]}-1) )
{
   if($snmp_wlsxAuthenticationServerTable_data->[0]->[$i]->val == 2)
   {
      my $key;
      $rad_server_count++;
      my @name_characters = split(/\./, $snmp_wlsxAuthenticationServerTable_data->[0]->[$i]->[0]);
      @name_characters = @name_characters[16..$#name_characters+1];

      my $name;
      foreach my $letter ( @name_characters )
      {
          $name .= chr($letter);
      }
      if( $snmp_wlsxAuthenticationServerTable_data->[1]->[$i]->val == 2 )
      {
         my $name;
         foreach my $letter ( @name_characters )
         {
             $name .= chr($letter);
         }
         push(@rad_server_not_enabled, (split(/\./,$name))[0]);
      }

      if( $snmp_wlsxAuthenticationServerTable_data->[1]->[$i]->val == 2 )
      {
         my $name;
         foreach my $letter ( @name_characters )
         {
             $name .= chr($letter);
         }
         push(@rad_server_not_inservice, (split(/\./,$name))[0]);
      }
   }
}

if( $rad_server_count != $ProgramOptions{'servercount'} and defined($ProgramOptions{'servercount'}) )
{
   $output = "WARNING - Configured RADIUS server count - $rad_server_count does not match expected count - $ProgramOptions{'servercount'}\n";
   $status = Monitor::Tools::WARNING;
}
elsif( scalar(@rad_server_not_enabled) > 0 )
{
   $output = "WARNING - RADIUS servers not enabled - " . join(",", @rad_server_not_enabled) . "\n";
   $status = Monitor::Tools::WARNING;
}
elsif( scalar(@rad_server_not_inservice) > 0 )
{
   $output = "CRITICAL - RADIUS servers not in service - " . join(",", @rad_server_not_inservice) . "\n";
   $status = Monitor::Tools::CRITICAL;
}
else
{
   $output = "OK - All RADIUS servers configured, enabled, and in service ($rad_server_count checked)\n";
   $status = Monitor::Tools::OK;
}

print $output;  # Send you plugin test to STDOUT.
exit $status;  # And finally exit with the state of your check

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "warn|w:-1",
      "crit|c:-1",
      "servercount|s=s"
   );
}

