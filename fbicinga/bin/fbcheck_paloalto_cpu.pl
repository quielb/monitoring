#!/usr/bin/perl
use POSIX;
use strict;
use Net::SNMP;
use Getopt::Long qw(:config no_ignore_case);

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
my $snmp_CPU = '.1.3.6.1.2.1.25.3.3.1.2';

my %ProgramOptions; # Hash to store CLI options  
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

### Return codes for status so Icinga/Nagios knows what the state of the return is
### exaple: $status = CRITICAL
use constant {
   OK => 0,
   WARNING => 1,
   CRITICAL => 2,
   UNKNOWN => 3 };

my $session;  # SNMP Session to be used for the entire plugin
my $error; # Used to store error text from SNMP session
my $status = OK; # Program return code that is interpreted by Icinga/Nagios to determine status
my $output; # string to contain the plugin output.  Printed to STDOUT just before exiting 

### Establish an SNMP session to device.  The only option that should need to be tweeked is the
### timeout value.  Fetching large amounts of data, ie a large ifIndex table, may not complete
### for the timeout and result in either partial data or a falure of somesort.  Just depends
### on what kind of mood Perl is in.
my %session_opts;
%session_opts =
   (
      -hostname   => $ProgramOptions{'H'},
      -community  => $ProgramOptions{'C'},
      -port       => '161',
      -version    => 2,
      -timeout    => 2,
      -maxmsgsize => 65535
   );

### Check that we were able to connect to the device.  We have to check it twice.  Sometimes
### you can open the session and but can't pull any data ( ACL related ).  Varies by vendor
### and platform
($session, $error) = Net::SNMP->session(%session_opts);
if(not defined $session)
{
   ### We weren't able to establish a session.  That makes the result UNKNOWN
   print "UNKNOWN - Unable to establish SNMP session: $error \n";
   exit UNKNOWN;
}

### Try to actualy fetch an OID.  varbindlist accepts an array of OID.  I just use an an
### anonymous array reference here.  You could assign values to an array and the provide the
### array refence to the function
my $sysDescr = $session->get_request(-varbindlist => [$snmp_sysDescr]);

if(not defined $sysDescr)
{
   ### It didn't exist so exit out UNKNOWN.  Hopefully $errortxt has something useful
   my $errortxt = $session->error();
   print "UNKNOW - Unable to establish SNMP session: $errortxt \n";
   exit UNKNOWN;
}

$output = CheckWarnCriticalValid();
if( defined($output) )
{
   $session->close();   
   print $output;
   exit UNKNOWN;
}
   
my $mgmt_cpu;
my $dp_cpu;
my $snmp_cpu_data = $session->get_table( -baseoid => $snmp_CPU );

### Get CPU util values.  MGMT is at index 1
foreach my $key ( keys %$snmp_cpu_data )
{
   if( (split(/\./, $key))[-1] == 1 )
   {
      $mgmt_cpu = $snmp_cpu_data->{$key};
   }
   else
   {
      $dp_cpu = $snmp_cpu_data->{$key};
   }
}

### Check data plane CPU against thresholds.
if( $dp_cpu >= $ProgramOptions{'crit'} )
{
   $output = "CRITICAL - Dataplane CPU $dp_cpu% load\n";
   $status = CRITICAL;
}
elsif( $dp_cpu >= $ProgramOptions{'warn'} )
{
   $output = "WARNING - Dataplane CPU $dp_cpu% load\n";
   $status = WARNING;
}
else
{
   $output = "OK - Dataplane CPU $dp_cpu% load. Management CPU $mgmt_cpu% load\n";
}

### Generate Perf Data
$output .= "|management_cpu=$mgmt_cpu%;$ProgramOptions{'warn'};$ProgramOptions{'crit'};0;100 ";
$output .= "dataplane_cpu1=$dp_cpu%;$ProgramOptions{'warn'};$ProgramOptions{'crit'};0;100\n";

$session->close(); # Close the SNMP session.  You probably don't have to explicitly close it but use good habits.
print "$output\n";  # Send you plugin test to STDOUT.
exit $status;  # And finally exit with the state of your check

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H|hostname=s",
      "C|community=s",
      "warn|w:-1",
      "crit|c:-1"
   );
}

sub CheckWarnCriticalValid
### Function to check warning and critical threshold values.  Provides some basic sanity checks.
### warning and crital have valid values
### warning < critical
### Don't need to check to see if they are defined.  They will always exist.
### The use of this function is optional.  But should be used if passing threshold on th CLI.
### If there is an error returns error string that can be used for exit STDOUT and used with an
### unknown state.  Otherwise returns undef.
{
   my $error = 0;
   my $return;


   ### Did warning and critical get values?
   if( $ProgramOptions{'warn'} == -1 or $ProgramOptions{'crit'} == -1 )
   {
      $error = 1;
      $return = "UNKNOWN - Threshold value not defined\n";
   }
   ### Is warning less then critical?
   elsif( $ProgramOptions{'warn'} > $ProgramOptions{'crit'} )
   {
      $error = 1;
      $return = "UNKNOWN - Warning threshold must be less then critical threshold\n";
   }

   ### If there was an error return the error string
   if( $error )
   {
      return $return;
   }
   
   return undef;
} 
