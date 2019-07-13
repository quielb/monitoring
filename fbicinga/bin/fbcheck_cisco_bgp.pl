#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my $snmp_cbgpPeer2State = '.1.3.6.1.4.1.9.9.187.1.2.5.1.3';
my $snmp_cbgpPeer2AdminStatus = '.1.3.6.1.4.1.9.9.187.1.2.5.1.4';
my $snmp_cbgpPeer2AcceptedPrefixes = '.1.3.6.1.4.1.9.9.187.1.2.8.1.1';
my $snmp_cbgpPeer2AdvertisedPrefixes = '.1.3.6.1.4.1.9.9.187.1.2.8.1.6';
my $snmp_cbgpPeer2FsmEstablishedTime = '.1.3.6.1.4.1.9.9.187.1.2.5.1.19';


my $status;
my $output;
my $perfdata = "| ";

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.

my $session = snmp_connect($ProgramOptions{'H'},$ProgramOptions{'C'});

if (not defined($session)) {
    print $Monitor::Tools::output;
    exit $Monitor::Tools::status;
}

my @bgpPeerStates = ('SNMP Error', 'idle', 'connect', 'active', 'opensent',
                                'openconfirm', 'established');

### Lets figure out if we are peering via v4 or v6
my $isIPv6Peer = 1 if $ProgramOptions{'p'} =~ /:/;

### Because of the way the OID is built wit AF included we have to create some
### placeholders then build the OID string based on AF of the peer address
my $snmp_cbgpPeer2State_oid;
my $snmp_cbgpPeer2AdminStatus_oid;
my $snmp_cbgpPeer2AcceptedPrefixes_oid;
my $snmp_cbgpPeer2AdvertisedPrefixes_oid;
my $snmp_cbgpPeer2FsmEstablishedTime_oid;
my $peerAddress_oid;

if (not $isIPv6Peer) {
    ### For a IPv4 peer the AF keys included in the OID are "1.4" so we will
    ### cat that on
    $snmp_cbgpPeer2State_oid = $snmp_cbgpPeer2State . ".1.4";
    $snmp_cbgpPeer2AdminStatus_oid = $snmp_cbgpPeer2AdminStatus . ".1.4";
    $snmp_cbgpPeer2AcceptedPrefixes_oid = $snmp_cbgpPeer2AcceptedPrefixes . ".1.4";
    $snmp_cbgpPeer2AdvertisedPrefixes_oid = $snmp_cbgpPeer2AdvertisedPrefixes . ".1.4";
    $snmp_cbgpPeer2FsmEstablishedTime_oid = $snmp_cbgpPeer2FsmEstablishedTime . ".1.4";
    ### Then just tack the peer address on the end
    $peerAddress_oid = "." . $ProgramOptions{'p'};
}
else {
    ### For a IPv6 peer the AF keys included in the OID are "2.16" so we will
    ### cat that on
    $snmp_cbgpPeer2State_oid = $snmp_cbgpPeer2State . ".2.16";
    $snmp_cbgpPeer2AdminStatus_oid = $snmp_cbgpPeer2AdminStatus . ".2.16";
    $snmp_cbgpPeer2AcceptedPrefixes_oid = $snmp_cbgpPeer2AcceptedPrefixes . ".2.16";
    $snmp_cbgpPeer2AdvertisedPrefixes_oid = $snmp_cbgpPeer2AdvertisedPrefixes . ".2.16";
    $snmp_cbgpPeer2FsmEstablishedTime_oid = $snmp_cbgpPeer2FsmEstablishedTime . ".2.16";

    ### Since there are so many different formats for an IP address (RFC 1884)
    ### we need to convert whatever we got as a IPv6 peer address to something
    ### predictable we can mangle
    require NetAddr::IP::Util;
    NetAddr::IP::Util->import( qw(ipv6_n2x ipv6_aton) );

    ### Now that the IPv6 address is in a predictable format work on
    ### converting it to an OID string. We have to zero-pad the address then
    ### convert from hex to decimal working with an address format of
    ### XXXX:XXXX:XXXX:XXXX sprint the sting by the : make sure its padded.
    ### The shif of the first 2 characters which are HEX and convert them to
    ### decimal
    my @ipv6AddressBlocks = split(/:/, ipv6_n2x(
        ipv6_aton($ProgramOptions{'p'})));
    foreach my $block (@ipv6AddressBlocks) {
        my $mangled_address .= sprintf("%.4x", hex($block));
        while ($mangled_address ne '') {
            $peerAddress_oid .= "." . hex(substr($mangled_address, 0, 2, ''));
        }
    }
}

### Now its time to actually get the state of things.
my $snmp_cbgpPeer2State_data = $session->get($snmp_cbgpPeer2State_oid . $peerAddress_oid);
### If the peer isn't found that is OK.  A BGP peer may get removed before the
### next discovery cycle.  Don't want to make noise for that.
if ($snmp_cbgpPeer2State_data =~ /NOSUCH/) {
    print "OK - Peer $ProgramOptions{'p'} BGP session not found.\n";
    exit Monitor::Tools::OK;
}

### Bail on no data
if ($snmp_cbgpPeer2State_data == 0) {
    print "UNKNOWN - Unable to poll cbgpPeer2State\n";
    exit Monitor::Tools::OK;
}

### If the BGP session isn't in an established state then check if its admin
### down. Admin down is OK, everything else is not.
if ($snmp_cbgpPeer2State_data != 6) {
    my $snmp_cbgpPeer2AdminStatus_data = $session->get(
        $snmp_cbgpPeer2AdminStatus_oid . $peerAddress_oid);
    if ($snmp_cbgpPeer2AdminStatus_data == 0) {
        print "UNKNOWN - Unable to poll cbgpPeer2AdminStatus\n";
        exit Monitor::Tools::OK;
    }
    if ($snmp_cbgpPeer2AdminStatus_data == 1) {
        print "OK - Peer $ProgramOptions{'p'} BGP state is "
              . "$bgpPeerStates[$snmp_cbgpPeer2State_data] "
              . "(administratively down)\n";
        exit Monitor::Tools::OK;
    } else {
        print "CRITICAL - Peer $ProgramOptions{'p'} BGP state is "
            . "$bgpPeerStates[$snmp_cbgpPeer2State_data]\n";
        exit Monitor::Tools::CRITICAL;
    }
}

### Check for a recent transition time. Any short established time
### warrants investigation if not associated with known events
my $snmp_cbgpPeer2FsmEstablishedTime_data = 'UNKNOWN';
$snmp_cbgpPeer2FsmEstablishedTime_data = $session->get(
    $snmp_cbgpPeer2FsmEstablishedTime_oid . $peerAddress_oid);
if ($snmp_cbgpPeer2FsmEstablishedTime_data !~ /[0-9]+/) {
    print "UNKNOWN - Peer $peerAddress_oid timer data is bad\n"
          . "cbgpPeer2FsmEstablishedTime("
          . "$snmp_cbgpPeer2FsmEstablishedTime_data)\n";
    exit Monitor::Tools::UNKNOWN;
}
else {
    # Too noisy - t16077211
    # my $state;
    # my $code;
    ## Not using a warning due to some funky shit: t15972444
    #if ($snmp_cbgpPeer2FsmEstablishedTime_data < 1200) {
    #    $state = "CRITICAL";
    #    $code = Monitor::Tools::CRITICAL;
    #} # if we fix said funky shit add warning back here
    #if ($code) {
    #  print "$state - Peer $ProgramOptions{'p'} last state change"
    #          . " $snmp_cbgpPeer2FsmEstablishedTime_data sec ago\n";
    #  exit $code;
    #}
    # Otherwise drop through to run other checks.
    print "OK - Peer $ProgramOptions{'p'} established for "
        . "$snmp_cbgpPeer2FsmEstablishedTime_data seconds\n";
    exit Monitor::Tools::OK;
}

### Since the session is up lets worry about how many routes we are
### getting/sending. If --routes or --perfdata do this.  The number of routes
### is used in both perfdata and to alarm against.  This is wrapped in a
### conditional because this block of code makes the runtime almost twice as
### long. Don't spend the cycles on it if it's not going to be used.
my $AcceptedRoutes;
my $AdvertisedRoutes;

if (defined($ProgramOptions{'perfdata'}) or
    defined($ProgramOptions{'routes'})) {
    ### Get count of accepted routes per known AF. Of note: accepted routes
    ### are the number of routes after any route maps have been applied
    my ($snmp_cbgpPeer2AcceptedPrefixes_data) = $session->bulkwalk(0, 10,
        [ $snmp_cbgpPeer2AcceptedPrefixes_oid . $peerAddress_oid ]);
    if ($session->{ErrorStr}) {
        print "UNKNOWN - Unable to poll cbgpPeer2AcceptedPrefixes " . $session->{ErrorStr} . " \n";
        print $Monitor::Tools::snmp_cli . " $$snmp_cbgpPeer2AcceptedPrefixes\n";
        exit Monitor::Tools::UNKNOWN;
    }

    foreach my $data (@$snmp_cbgpPeer2AcceptedPrefixes_data) {
        $AcceptedRoutes->{'ipv4'} = $data->val if (split(/\./,$data->[0]))[-1] == 1;
        $AcceptedRoutes->{'ipv6'} = $data->val if (split(/\./,$data->[0]))[-1] == 2;
    }

    ### Get count of advertised routes per known AF. Of note: advertised routes
    ### are the number of routes after any route maps have been applied and
    ### summarization
    my ($snmp_cbgpPeer2AdvertisedPrefixes_data) = $session->bulkwalk(0, 10,
        [ $snmp_cbgpPeer2AdvertisedPrefixes_oid . $peerAddress_oid ]);
    if ($session->{ErrorStr}) {
        print "UNKNOWN - Unable to poll cbgpPeer2AdvertisedPrefixes " . $session->{ErrorStr} . " \n";
        print $Monitor::Tools::snmp_cli . " $$snmp_cbgpPeer2AdvertisedPrefixes\n";
        exit Monitor::Tools::UNKNOWN;
    }

    foreach my $data (@$snmp_cbgpPeer2AdvertisedPrefixes_data) {
        $AdvertisedRoutes->{'ipv4'} = $data->val if (split(/\./,$data->[0]))[-1] == 1;
        $AdvertisedRoutes->{'ipv6'} = $data->val if (split(/\./,$data->[0]))[-1] == 2;
    }

    ### Build the perfdata
    if (defined($ProgramOptions{'perfdata'}) ) {
        foreach my $key (keys %$AcceptedRoutes) {
            $perfdata .= $key . "_AcceptedRoutes=" . $AcceptedRoutes->{$key} . " ";
        }
        foreach my $key (keys %$AdvertisedRoutes) {
            $perfdata .= $key . "_AdvertisedRoutes=" . $AdvertisedRoutes->{$key} . " ";
        }
    }

    ### If we care about the fact that we have an AF defined and aren't
    ### getting/sending those routes that is a warning.
    if (defined($ProgramOptions{'routes'})) {
        foreach my $key (keys %$AcceptedRoutes) {
            if ($AcceptedRoutes->{$key} == 0) {
                $output .= "Not receiving any routes from peer " . "$ProgramOptions{'p'} of type $key\n";
                print $perfdata if defined($ProgramOptions{'perfdata'});
                $status = Monitor::Tools::WARNING;
            }
        }
        foreach my $key (keys %$AdvertisedRoutes) {
            if ($AdvertisedRoutes->{$key} == 0) {
                $output .= "Not sending any routes to peer " . "$ProgramOptions{'p'} of type $key\n";
                print $perfdata if defined($ProgramOptions{'perfdata'});
                $status = Monitor::Tools::WARNING;
            }
        }

        if ($status != Monitor::Tools::OK) {
            print "WARNING - There is a problem with the routes we are sending/receiving with peer $ProgramOptions{'p'}\n";
            print $output;
            print $perfdata if defined($ProgramOptions{'perfdata'});
            exit $status;
        }
    }
}

### Made it all the way to the end. That means everything is OK!!
print "OK - Peer $ProgramOptions{'p'} BGP state is $bgpPeerStates[$snmp_cbgpPeer2State_data]\n";
print $perfdata if defined($ProgramOptions{'perfdata'});
exit Monitor::Tools::OK;

sub ParseOptions {
     GetOptions(\%ProgramOptions,
        "H=s",
        "C=s",
        "p=s",
        "perfdata",
        "routes",
    );
}
