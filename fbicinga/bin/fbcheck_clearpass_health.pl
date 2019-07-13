#!/usr/bin/perl
use POSIX;
use strict;
use Net::SNMP;
use Getopt::Long;

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
my $snmp_extOutput = '.1.3.6.1.4.1.2021.8.1.101';
my %ProcessMap =
(
   'admin' => 1,
   'system-auxiliary' => 2,
   'policy' => 3,
   'tacacs' => 4,
   'radius' => 5,
   'dbwrite' => 6,
   'repl' => 7,
   'dbcn' => 8,
   'async' => 9,
   'multi-master-cache' => 10,
   'vip' => 13,
   'carbon' => 14,
   'statsd' => 15
);

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
my $output; # string to contain the plugin out.  Printed to STDOUT just before exiting 

### Establish SNMP session to device.  The only option that should need to be tweeked is the
### timeout value.  Fetching large mounts of data, ie a large ifIndex table, may not complete
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

if (!defined($ProgramOptions{'process'}))
{
   $session->close();
   print "UNKNOWN - No process check selected\n";
   exit UNKNOWN;
}
if (!defined($ProcessMap{$ProgramOptions{'process'}}))
{
   $session->close();
   print "UNKNOWN - $ProgramOptions{'process'} is not a valid process\n";
   exit UNKNOWN;
}



my $oid = "$snmp_extOutput." . $ProcessMap{$ProgramOptions{'process'}};

my $data = $session->get_request(-varbindlist => [$oid]);

if (!defined($data))
{
   $session->close();
   print "Unable to poll $ProcessMap{$ProgramOptions{'process'}} status\n";
   exit UNKNOWN;
}

if ($data->{$oid} =~ /is stopped/)
{
   $output = "CRITICAL - $data->{$oid}\n";
   $status = CRITICAL;
}
else
{
   $output = "OK - $data->{$oid}\n";
   $status = OK;
}

$session->close(); # Close the SNMP session.  You probably don't have to explicitly close it but use good habits.
print "$output\n";  # Send you plugin test to STDOUT.
exit $status;  # And finally exit with the state of your check

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "H=s",
      "C=s",
      "process=s"
   );
}