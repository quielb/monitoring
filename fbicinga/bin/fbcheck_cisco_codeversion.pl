#!/usr/bin/perl

use POSIX;
use strict;
use Net::SNMP;
use Getopt::Long;
use Socket;

my $snmp_sysDescr = '1.3.6.1.2.1.1.1.0';

my %ProgramOptions;
ParseOptions();



my $session;
my $error;
my %session_opts;
%session_opts =
   (
      -hostname   => $ProgramOptions{'H'},
      -community  => $ProgramOptions{'C'},
      -port       => '161',
      -version    => 2,
      -maxmsgsize => 65535
   );

($session, $error) = Net::SNMP->session(%session_opts);
if (!defined($session))
{
   print "UNKNOWN: Unable to establish SNMP session: $error \n";
   exit 3;
}

my @oid = ( $snmp_sysDescr );
my $sysDescr = $session->get_request(-varbindlist => \@oid);

if (!defined $sysDescr)
{
   my $errortxt = $session->error();
   print "UNKNOWN: Unable to get sysDescr SNMP value: $errortxt\n";
   exit 3;
}

(my $sysDescrString, undef) = split('\n',$sysDescr->{$snmp_sysDescr});


$session->close();
print "$sysDescrString\n";
exit 0;


sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      "H=s",
      "C=s"
   );
}
