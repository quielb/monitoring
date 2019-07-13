#!/usr/bin/perl

use POSIX;
use strict;
use feature 'switch'; # Needed for given blocks
use threads; #('stack_size' => 80000000);
use threads::shared;
use Thread::Queue;
use Net::SNMP;
use Net::Ping;
use NetAddr::IP;
use Getopt::Long;
use File::Glob;
use Net::DNS;
use List::MoreUtils qw/uniq/;
use JSON qw( decode_json );
use JSON qw( encode_json );
use Data::Dumper;

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

### Check if running as root.  If not bail.
if ( $< != 0 )
{
   print "This program must be run as root.  Exiting...\n";
   exit 0
}

### Check for a lock file.  If it exists check if that process is running.
### If the process isn't running remove the lockfile and continue.
### If the process is running then exit out.
my $LockFile = '/var/run/icinga2/icinga2-addDevice.pid';
if( -f $LockFile )
{
   my $fh;
   open($fh, '<', $LockFile);
   my $LastPID = <$fh>;
   chomp($LastPID);
   my $exists = kill 0, $LastPID;
   if( $exists )
   {
      use File::Basename;
      print "Another instance of " . basename($0) . " is running.  Try again later\n";
      exit 1;
   }
   else
   {
      unlink $LockFile;
   }
}

### Create lockfile containing current PID
my $fh;
open($fh, '>', $LockFile);
print $fh $$;
close($fh);


my $IcingaPath = '/etc/icinga2/zones.d/dc-master/generated'; # Path to Icinga Config for this zone.
my $ThreadCount = 30;  # Number of threads to run for InterrogateHost
my $SOT_attempts = 2; # How many times should we try and connect to SOT?
my $HostsQ = Thread::Queue->new(); # Devices from ENM.
my @HostInfo :shared; # Devices after InterrogateHost
my @MultiPolledHost :shared; # Devices have to be polled more then once.  This is probably temporary.... I hope....
my $RedundancyGroup;
my @ConfigErr;
my @DeleteMe;
my $StatusTrack;
my $StartTime = time;

my @LDAPGroupsDN = ("CN=icinga-users,DC=SomeCompany,DC=Internal");

my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
my $snmp_bgpPeerTable_oid = '.1.3.6.1.2.1.15.3.1';
my $snmp_ipAddrTable_oid = '.1.3.6.1.2.1.4.20.1';
my $snmp_ifTable_oid = '.1.3.6.1.2.1.2.2.1';
my $snmp_ifAlias_oid = '.1.3.6.1.2.1.31.1.1.1.18';
my $snmp_cdpCacheTable_oid = '.1.3.6.1.4.1.9.9.23.1.2.1';
my $snmp_dot3adAggTable_oid = '.1.2.840.10006.300.43.1.1.1';
my $snmp_clagAggPortListPorts_oid = '.1.3.6.1.4.1.9.9.225.1.4.1.1.1';
my $snmp_cHsrpGrpStatndbyState = '.1.3.6.1.4.1.9.9.106.1.2.1.1.15';
my $snmp_lldpRemSysName_oid = '.1.0.8802.1.1.2.1.4.1.1.9';
my $snmp_cContextMappingVrfName = '.1.3.6.1.4.1.9.9.468.1.1.1.2'; # CISCO-CONTEXT-MAPPING

### Get CLI options passed in
my %ProgramOptions;
ParseOptions();

my @thread;
### Start $ThreadCount number of threads
### Have to start the threads before the sync becuase syncWithSOT is not thread safe
### and it blows all kinds of shit up when you try to join the threads.
foreach my $i ( 1..$ThreadCount )
{
   $thread[$i] = threads->create({'context' => 'void'}, \&InterrogateHostThread);
}

if( not syncWithSOT() )
{
   foreach my $i ( 1..$ThreadCount )
   {
      $thread[$i]->join();
   }
   exit 1;
}
### Did SOT take to long?  Since we don't have blocking threads in this version of perl
### we need to check if there are threads left.  If there isn't just bail.  We probably can't
### just create new ones.  Shit probably got loaded that wasn't thread safe.
if( scalar(threads->list(threads::running)) < $ThreadCount-1 )
{
   send_to_heartbeat({ service => 'Icinga2 SOT Sync',
                       status_message => "SOT is too slow, ran out of threads\n" . $StatusTrack,
                       status_code => '1'
                    }) if not defined $ProgramOptions{'test'};
   print "Ran out of threads waiting for SOT... goodbye\n" if defined $ProgramOptions{'test'};
   foreach my $i ( 1..$ThreadCount )
   {
      $thread[$i]->join();
   }
   exit 1;
}


### Wait for threads to complete
$StartTime = time;
while( scalar(threads->list(threads::running)) > 0 )
{
   print "And still waiting....\n" if defined $ProgramOptions{'test'};
   sleep 10;
}

foreach my $i ( 1..$ThreadCount )
{
   $thread[$i]->join();
}

$StatusTrack .= "Time to Interrogate: " . (time - $StartTime) ."s\n";
### Now that we are done poking at devices let's config.
### Create config file for Interrogated devices.
### Could have done this multi-threaded, but really
### didn't seem worth the overhead.  The slow part of this
### script is the SNMP query of all the devices.
$StartTime = time;
GenerateConfig();
$StatusTrack .= "Time to GenerateConfig: " . (time - $StartTime) ."s\n";

### Find all the things that went wrong that were not critical.
my $subject = "[WARNING] Icinga2 SYNC";
my $message;
### Check if any of the devices had to be re-polled becuase of this SNMP issue
### Hopefully this in only temporary
if( @MultiPolledHost > 0)
{
   $message .= "This list of devices had to be re-polled:\n";
   foreach my $failed (@MultiPolledHost)
   {
      $message .= "\t$failed\n";
   }
}


### Check if there were any failed hosts during GenerateConfig.
### This is not a critical error and the program can continue if
### a device is missed.  But will need to be re-mediated later.
if( @ConfigErr > 0 )
{
   $message .= "Could not write the following config files:\n";
   foreach my $failed (@ConfigErr)
   {
      $message .= "\t$failed\n";
   }
}
#StatusNotify( $subject, $message );

send_to_heartbeat( { service => 'Icinga2 SOT Sync',
                     status_message => "Survived another sync\n" . $StatusTrack,
                     status_code => '0'
                   }) if not defined $ProgramOptions{'test'};
exit 0;


sub InterrogateHostThread
### Wrapper function for doing threaded InterrogateHost
### This was the easiest way to add threads. I don't have
### to re-work InterrogateHost or deal with passing values to
### the threads or capturing return values.
### Pre-Conditions: None.  If @HostsQ is empty thread will exit.
### Post-Conditions: All hosts in HostsQ will be interrogated and
###    added to @HostInfo. Any failures ( due to DNS ) will be put in @FailedHost
{
   sleep 60;
   while ( my $hostQ = $HostsQ->dequeue_nb )
   {
      #my $start_time = time;
      my $device = InterrogateHost($hostQ);
      #print "DEBUG: Finishing host " . $hostQ->{'name'} . " " . (time - $start_time) . " seconds\n";
      if( defined($device) )
      {
         lock(@HostInfo);
         push(@HostInfo, $device);
      }
   }
}
sub InterrogateHost
### Function to gather data from a give device via SNMP.
### Depending on device type ( by name ) subs are called for
### other data ie BGP or CDP peers.  A SNMP session is established
### here and passed to and used by the sub functions.
### Pre-Conditions:  requires a hostname string.
### Post-Conditions: returns a hash reference will all collected data.
###    If the device cannot be contacted a hash is still returned.  But
###    the only valid keys are name and addr4.  By creating an empty
###    host hash it will show up as a down host in icinga.
###    returns undef on DNS failure.
{
   my $session;
   my %session_opts;
   my $error;
   my $resolver = new Net::DNS::Resolver;
   my $host; # hash to be returned by reference

   $host = shift;
   $host->{'state'} = "up";

   ### Reslove IPv4 name.  If it can't be resolved return UNDEF which
   ### will generate a WARNING output.
   ### Going directly to DNS server eliminates caching by NSCD on localhost
   my $reply = $resolver->search($host->{'name'}, "A", "IN");
   ### Can't resolve host name to address there is no point
   ### in going on.  Just die
   if (!defined($reply))
   {
      ### exception code to handle OOB.  Most oob devices are getting created without
      ### a loopback address.  But there should be a DNS enrty ending in -vl3
      if( $host->{'name'} =~ /oob/ )
      {
         my $VL3name = $host->{'name'} . "-vl3";
         $reply = $resolver->search($VL3name, "A", "IN");
      }
   }

   if( defined($reply) )
   {
      my @record = $reply->answer;
      $host->{'addr4'} = $record[0]->{'address'};
   }

   ### IPv6 lookup
   $reply = $resolver->search($host->{'name'}, "AAAA", "IN");
   if (defined($reply))
   {
      my @record = $reply->answer;
      $host->{'addr6'} = $record[0]->{'address'};
   }

   if( not defined($host->{'addr4'}) and not defined($host->{'addr6'}) )
   {
      return undef;
   }

   my $address;
   my $community;
   my $domain;
   if( defined $host->{'addr4'} )
   {
      $address = $host->{'addr4'};
      $community = $host->{'community'};
      $domain = "udp4";
   }
   elsif( defined $host->{'addr6'} )
   {
      $address = $host->{'addr6'};
      $community = $host->{'community6'};
      $domain = "udp6";
   }
   else
   {
      $host->{'state'} = "down";
      return shared_clone($host);
   }

   ### Set the options for the SNMP session.
   ### Use a different timeout for DC firewall.
   my $timeout;
   if ($host->{'name'} =~ /dc-fw|dgw/)
   {
      $timeout = 45
   }
   else
   {
      $timeout = 3
   }

   %session_opts =
   (
      -hostname   => $address,
      -community  => $community,
      -domain     => $domain,
      -port       => '161',
      -version    => 2,
      -maxmsgsize => 65535,
      -translate => ['-all', 0, '-octetstring', 1, 'nosuchobject', 1, 'nosuchinstance', 1],
      -timeout    => $timeout,
      -retries => 1
   );

   ###  Connect via SNMP to the device if it doesn't respond just return
   ###  the host hash with name and address4 keys defined.
   $session = Net::SNMP->session(%session_opts);

   if (defined($session))
   {
      my $sysDescr = $session->get_request(-varbindlist => [$snmp_sysDescr]);
      if( defined($sysDescr) )
      {
         ### This is TEMP. Adding a return here so that hosts that we don't
         ### care about services just get added as empty host.  Eventually
         ### we will care about everything
         if ( $host->{'name'} =~ /-gw[0-9]|vpn-hub1|-[v]fw[1-2]|-dgw|-wgw|-pgw|-vgw|-cgw|-oob-wgw|-agw|-sgw|hgw/ and $host->{'name'} !~ /oob-cs|oob-msw|oob-cgw/)
         {
            ### Get L3IP4 interfaces and address/mask.
            #print "DEBUG: Starting L3IPv4 for $host->{'name'} \n";
            $host->{'L3IPv4'} = InterrogateHostL3IPv4($session,$host->{'name'});

            ### Get BGP peer sessions.
            #print "DEBUG: Starting BGP for $host->{'name'} \n";
            $host->{'BGP4'} = InterrogateHostBGPv4($session);

         }

         if ( $host->{'meta'}->{'vendor'} eq 'cisco' and $host->{'name'} !~ /oob|wgw/ and $host->{'meta'}->{'os'} ne 'iosxr')
         {
            #print "DEBUG: Starting Port Channel for $host->{'name'} \n";
            $host->{'PortChannel'} = InterrogateHostPortChannel($session);
         }

         if( $host->{'name'} =~ /dgw|agw|sgw/ )
         {
            #print "DEBUG: Starting HSRP for $host->{'name'} \n";
            $host->{'hsrp'} = InterrogateHostHSRP($session);
         }

         #print "DEBUG: Starting LLDP for $host->{'name'} \n";
         $host->{'LLDP'} = InterrogateHostLLDP($session);

         ### Get CDP neighbors.
         #if ( $host->{'vendor'} eq 'cisco' )
         #{
         #   $host->{'CDP'} = InterrogateHostCDP($session);
         #   $session->close();
         #}
      }
      else
      {
         $host->{'state'} = "down";
      }
   }
   else
   {
      $host->{'state'} = "down";
   }
   return shared_clone($host);

}

sub InterrogateHostL3IPv4
### Function to gather data about IP4 L3 interfaces on the device.
### Pre-Conditions: requires a valid NET::SNMP session.
### Post-Conditions:  returns an array (by ref) of hashes (by ref).
###    valid hash keys are:  addr4, mask4, alias, index
###    alias is the interface description from the device.  Used
###       only as a display feature in the WebUI
###    index is the SNMP ifIndex value.
{
   my $session = shift;  # Get the SNMP session passed in
   my $hostname = shift;

   my @L3IP4 :shared; # array of hashes for L3 interface info

   ### Get the table of IP4 addresses from the device
   my $ipAddrTable_data;
   if( $hostname =~ /dc[0-9]*-dgw[0-9]/)
   {
      $ipAddrTable_data = $session->get_table( -baseoid => $snmp_ipAddrTable_oid, -maxrepetitions => 1 );
   }
   else
   {
      $ipAddrTable_data = $session->get_table( -baseoid => $snmp_ipAddrTable_oid );
   }

   ### If there are no addresses then skip all this.
   ### This will cause undef to be returned.
   if (defined($ipAddrTable_data))
   {
      ### Placeholder for parent interfaces of sub-interfaces.  Array of ifIndex.
      my @parent_ifIndex;

      my @L3temp;  # Temp holder for L3 Interfaces

      ### reference for ifAlias table and array of OIDs
      ### for columns of interest. Even though we are only
      ### interested in one column function still requires
      ### an array reference.
      my $ifAlias_data;
      my @ifAlias_oid;

      ### reference for ifTable table and array of OIDs
      ### for columns of interest. Even though we are only
      ### interested in one column function still requires
      ### an array reference.
      my $ifTable_data;
      my @ifTable_oids;


      ### Get L3 addresses from ipAddrTable
      foreach my $key (keys %$ipAddrTable_data)
      {
         ### Right now only interested in the ipAdEntAddr (.1) column of the
         ### table.  Will use the other stuff later.
         if ( $key =~ /$snmp_ipAddrTable_oid\.1/ )
         {
              #print "DEBUG: found L3 interface $ipAddrTable_data->{$key}\n";
            push(@L3temp, $ipAddrTable_data->{$key});
         }
      }

      push(@ifAlias_oid, $snmp_ifAlias_oid);
      push(@ifTable_oids, $snmp_ifTable_oid . "\.2"); # .2 gives us the ifTable-ifDesc column
      push(@ifTable_oids, $snmp_ifTable_oid . "\.3"); # .3 gives us the ifTable-ifType column

      ### Pull as little data from tables.  Pulling the whole table is slow
      ### Couldn't use other get methods which are faster. they don't return
      ### consistent data.  Also get_entries will gather all the data where a
      ### normal get will generally overflow maxmsgsize.
      $ifAlias_data = $session->get_entries( -columns => \@ifAlias_oid );
      $ifTable_data = $session->get_table( -baseoid => $snmp_ifTable_oid);

      if ( $session->error ne '' )
      {
         my $repolled = $hostname . " " . $session->error;
         push(@MultiPolledHost, $repolled);
         sleep 4;
         $ifTable_data = $session->get_table( -baseoid => $snmp_ifTable_oid);
      }


      ### Now that we have the info put it all together put it in a hash and push to IP4 array
      foreach my $ifaceaddr (@L3temp)
      {
         my %L3interface :shared;

         my $ipAddrTable_ipAdEntifIndex_oid = $snmp_ipAddrTable_oid . "\.2\." . $ifaceaddr;
         my $ipAddrTable_ipAdEntNetMask_oid = $snmp_ipAddrTable_oid . "\.3\." . $ifaceaddr;

         my $index = $ipAddrTable_data->{$ipAddrTable_ipAdEntifIndex_oid};
         my $ifAlias_oid = $snmp_ifAlias_oid .  "\." . $index;
         my $ifDesc_oid = $snmp_ifTable_oid . "\.2\." . $index;
         my $ifType_oid = $snmp_ifTable_oid . "\.3\." . $index;
         my $iftype = $ifTable_data->{$ifType_oid};
         my $ifdesc =  $ifTable_data->{$ifDesc_oid};
         #print "DEBUG: $hostname $ifDesc_oid: type - $iftype desc - $ifdesc Alias - $ifAlias_data->{$ifAlias_oid}\n";

         ### If interface is loopback or vlan do nothing
         if ($iftype == 24)
         {
            # print "DEBUG: Found LoopBack interface\n";
         }
         ### Separated vlan from loopback and added condition to
         ### work around SNMP bug for incorrect iftype on BE LACP mode on
         #elsif ($iftype == 53 and $hostname !~ /-wgw|-csw|-cgw/)
         #{
         #}
         ### If interface has 10. default address do nothing
         elsif ($ifaceaddr =~ /10\.0\.0\.1|127\.0\.0\.1|(129|130)\.16\.0\.1/)
         {
            # print "DEBUG: Found 10. interface\n";
         }
         ### Exclude GUEST Tunnel Interfaces for now.  Too much, it breaks Icinga.
         elsif ( $ifAlias_data->{$ifAlias_oid} =~ /GUEST|tun400|lab/ or $ifdesc =~ /Tunnel400|EOBC|fxp|em0|avs|Vlan|MgmtEth0/i )
         {

         }
         ### Exclude any interfaces set to NOMON
         elsif ( $ifAlias_data->{$ifAlias_oid} =~ /NOMON/)
         {
            next;
         }
         ### Add the interface to the array to return
         else
         {
            #print "DEBUG: $hostname $ifDesc_oid: type - $iftype desc - $ifdesc Alias - $ifAlias_data->{$ifAlias_oid}\n";
            $L3interface{'addr4'} = $ifaceaddr;
            $L3interface{'mask4'} = $ipAddrTable_data->{$ipAddrTable_ipAdEntNetMask_oid};
            $L3interface{'alias'} = $ifAlias_data->{$ifAlias_oid};
            $L3interface{'index'} = $index;
            $L3interface{'name'} = $ifdesc;
            # Check if the interface is a sub interface and find the physical interface
            if( $L3interface{'name'} =~ /\./ and $L3interface{'name'} !~ /fab/ )
            {
               my $possibleparent = (split(/\./, $L3interface{'name'}))[0];
               #print "DEBUG: Found sub interface $L3interface{'name'} looking for parent $possibleparent\n";
               my %L2interface;
               foreach my $key (keys %$ifTable_data)
               {
                  if( (split(/\./, $key))[-2] == 2)
                  {
                     #print "DEBUG: Checking $ifTable_data->{$key}\n";
                     if( $ifTable_data->{$key} =~ /$possibleparent$/ )
                     {
                        #print "DEBUG: Found Parent for $L3interface{'name'} - $ifTable_data->{$key}\n";
                        $L3interface{'parent'} = "Interface " . $ifTable_data->{$key};
                        push(@parent_ifIndex, (split(/\./, $key))[-1]);
                     }
                  }
               }
            }
            # print "DEBUG: Adding $ifaceaddr\n";
            push(@L3IP4, \%L3interface) if $L3interface{'alias'} !~ /test/;
         }
      }

      ### Check if we found any sub-interface and create an Interface object for the parent so
      ### we can create dependencies.  This may not be the best place to do this since technically
      ### the parent is an L2 interface.  But we aready have all the data so we don't need to
      ### pull all the ifTable again.
      foreach my $parent_index ( uniq @parent_ifIndex)
      {
         my %L3interface :shared;
         my $ifAlias_oid = $snmp_ifAlias_oid .  "\." . $parent_index;
         my $ifDesc_oid = $snmp_ifTable_oid . "\.2\." . $parent_index;

         $L3interface{'name'} = $ifTable_data->{$ifDesc_oid};
         $L3interface{'index'} = $parent_index;
         $L3interface{'alias'} = $ifAlias_data->{$ifAlias_oid};
         #print "DEBUG: Adding parent of sub-interface $L3interface{'name'} - $L3interface{'index'} - $L3interface{'alias'}\n";
         push(@L3IP4, \%L3interface);
      }

   }


   return \@L3IP4;
}

sub InterrogateHostBGPv4
### Function to gather data about IP4 BGP peers.
### Pre-Conditions: requires a valid Net::SNMP session.
### Post-Conditions: returns an Array (by ref) of BGP peers.
{
   my $session = shift; # Get the SNMP session passed in.
   my @bgpPeer :shared; # Array of peers to return.

   my $bgpPeerTable_data = $session->get_table( -baseoid => $snmp_bgpPeerTable_oid );

   ### If the host has peers put them in an array.  Otherwise just
   ### return undef
   if (defined($bgpPeerTable_data))
   {
      foreach my $key (keys %$bgpPeerTable_data)
      {
         ### The only column in the table of interest is bgpPeerRemoteAddr (.7)
         if ( $key =~ /$snmp_bgpPeerTable_oid\.7\./ )
         {
            if ( $bgpPeerTable_data->{$key} !~ "192.168.2.110" && $bgpPeerTable_data->{$key} !~ /172\.(17|18|24)\.0\.[1-4]/)
            {
               push(@bgpPeer, $bgpPeerTable_data->{$key});
            }
         }
      }
   }
   return \@bgpPeer;
}

sub InterrogateHostCDP
### Function to gather CDP data from device
### Pre-Conditions: requires a valid Net::SNMP session.
### Post-Conditions: returns an Array (by ref) of hashes.  Valid keys for hash
###    name: hostname of CDP neighbor
###    index: ifIndex neighbor is at.
{
   my $session = shift;
   my @cdpNeighbors :shared;
   my $cdpCacheTable_data = $session->get_table(-baseoid => $snmp_cdpCacheTable_oid);

   foreach my $keys ( keys %$cdpCacheTable_data )
   {
      my %cdpNeighbor :shared;
      if ( $keys =~ /$snmp_cdpCacheTable_oid\.1\.6/ )
      {
         ($cdpNeighbor{'name'}, undef) = split(/\./, $cdpCacheTable_data->{$keys},2);
         $cdpNeighbor{'name'} = (split(/\(/, $cdpNeighbor{'name'}))[0];
         $keys =~ s/$snmp_cdpCacheTable_oid\.1\.6\.//g;
         ($cdpNeighbor{'index'}, undef) = split(/\./,$keys);
         if( $cdpNeighbor{'name'} !~ /lab|test/i )
         {
            push(@cdpNeighbors,\%cdpNeighbor);
         }
      }
   }

   if( scalar(@cdpNeighbors) == 0 )
   {
      return undef;
   }
   else
   {
      return \@cdpNeighbors;
   }
}

sub InterrogateHostLLDP
### Function to gather LLDP data from device
### Pre-Conditions: requires a valid Net::SNMP session.
### Post-Conditions: returns an Array (by ref) of hashes.  Valid keys for hash
###    name: hostname of lldp neighbor
###    index: ifIndex neighbor is at.
{
   my $session = shift;
   my @lldpNeighbors :shared;
   my $lldpRemSysName_data = $session->get_table(-baseoid => $snmp_lldpRemSysName_oid, -maxrepetitions => 10);

   foreach my $key ( keys %$lldpRemSysName_data )
   {
      my %lldpNeighbor :shared;
      #print "DEBUG: Interrogate LLDP name " . $lldpRemSysName_data->{$key} . "\n";
      # If the name shows up as FQDN strip down to short name.
      # Can't do this for all neighbors.  AP names have dots in them
      if( $lldpRemSysName_data->{$key} =~ /corp\.tfbnw\.net/ )
      {
         $lldpNeighbor{'name'} = (split(/\./, $lldpRemSysName_data->{$key}))[0];
      }
      else
      {
         $lldpNeighbor{'name'} = $lldpRemSysName_data->{$key};
      }
      $lldpNeighbor{'index'} = (split(/\./, $key))[-2];
      #print "DEBUG:  Adding host " . $lldpNeighbor{'name'} . " attached at index " . $lldpNeighbor{'index'} . "\n";
      push(@lldpNeighbors, \%lldpNeighbor);
   }
   if( scalar(@lldpNeighbors) == 0 )
   {
      return undef;
   }
   else
   {
      return \@lldpNeighbors;
   }
}


sub InterrogateHostHSRP
### Function to gather HSRP Group numbers
### Pre-Conditions: requires a valid Net::SNMP session.
### Post_conditions: returns an Array (by ref) of HSRP group numbers
{
   my $session = shift;
   my @HSRPgroups :shared;

   my $snmp_cHsrpGrpStatndbyState_data = $session->get_table(-baseoid => $snmp_cHsrpGrpStatndbyState);

   foreach my $key ( keys %$snmp_cHsrpGrpStatndbyState_data )
   {
      push( @HSRPgroups, (split('\.', $key))[-1]);
   }

   if( scalar(@HSRPgroups) == 0 )
   {
      return undef;
   }
   else
   {
      return \@HSRPgroups;
   }
}

sub InterrogateHostPortChannel
### Funtion to find port channels on devices
### Pre-Conditions: requires a valid Net::SNMP session.
### Post-Conditions: returns an Array of HASHes ifIndex of port channels.
{
   my $session = shift;
   my @dot3adAggIndex :shared;
   my $snmp_clagAggPortListPorts_data = $session->get_table( -baseoid => $snmp_clagAggPortListPorts_oid);

   if (scalar(keys %$snmp_clagAggPortListPorts_data))
   {
      foreach my $key ( keys %$snmp_clagAggPortListPorts_data )
      {
         my $poHex = $snmp_clagAggPortListPorts_data->{$key};
         $poHex =~ s/^0x//g;
         if ( substr($poHex,3,1) >= 2 )
         {
            my %POinterface :shared;
            my $poindex = (split(/\./, $key))[-1];
            my @oid = ( $snmp_ifTable_oid . "\.2\." . $poindex );
            my $ifdesc = $session->get_request(-varbindlist => \@oid);
            my $po_ifdesc = $ifdesc->{ $oid[0] };
            $POinterface{'index'} = $poindex;
            $POinterface{'name'} = $po_ifdesc;
            if( $POinterface{'name'} =~ /channel[1-9]$/ )
            {
               push(@dot3adAggIndex, \%POinterface);
            }
         }
      }
   }
   else
   {
      my $dot3adAggTable_data = $session->get_table( -baseoid => $snmp_dot3adAggTable_oid);
      foreach my $key ( keys %$dot3adAggTable_data )
      {
         if ( $key =~ /$snmp_dot3adAggTable_oid\.1\.5/ )
         {
            if ($dot3adAggTable_data->{$key} == 1)
            {
               my %POinterface :shared;
               my $poindex = (split(/\./, $key))[-1];
               my @oid = ( $snmp_ifTable_oid . "\.2\." . $poindex );
               my $ifdesc = $session->get_request(-varbindlist => \@oid);
               my $po_ifdesc = $ifdesc->{ $oid[0] };
               $POinterface{'index'} = $poindex;
               $POinterface{'name'} = $po_ifdesc;
               if( $POinterface{'name'} =~ /channel[1-9]$/ )
               {
                  push(@dot3adAggIndex, \%POinterface);
               }
            }
         }
      }
   }

   if( scalar(@dot3adAggIndex) == 0 )
   {
      return undef;
   }
   else
   {
      return \@dot3adAggIndex;
   }
}

sub GenerateConfig
### Parent function to generate Icinga 2 config blocks for hosts and services
### Pre-Conditions: Requires a valid host hash, generated from InterrogateHost()
### Post-Condition: Writes host and services config blocks to file.
###    returns 1 (TRUE) or 0 (FALSE)
{
   my $cfgstring;
   my $hostgroup_meta = {};

   foreach my $file ( @DeleteMe )
   {
      unlink $file;
   }

   for my $i ( 0..(@HostInfo-1) )
   {
      $HostInfo[$i] = GenerateConfigHost($HostInfo[$i]);
      foreach my $key ( keys %{$HostInfo[$i]->{'meta'}} )
      {
         push(@{$hostgroup_meta->{$key}}, $HostInfo[$i]->{'meta'}->{$key});
      }
   }

   foreach my $key ( keys %$hostgroup_meta )
   {
      @{$hostgroup_meta->{$key}} = uniq @{$hostgroup_meta->{$key}};
      foreach my $meta_group ( @{$hostgroup_meta->{$key}} )
      {
         if( $meta_group ne '' )
         {
            my $cfgfile = $IcingaPath . "/" . $meta_group . ".conf";
            $cfgstring = "object HostGroup \"$meta_group\" {\n";
            $cfgstring .= "assign where host.vars.meta[\"$key\"] == \"$meta_group\"\n";
            $cfgstring .= "   }\n\n";
            WriteConfig($cfgfile, $cfgstring);
         }
      }
   }

   foreach my $key ( keys %$RedundancyGroup )
   {
      if( scalar(@{$RedundancyGroup->{$key}}) > 1 and $key !~ /-sw$|-ssw$|-sgw$|oob-msw|oob-cs|ra-wlc$/ )
      {
         my $cfgstring;
         my $cfgfile = $IcingaPath . "/" . $key . ".conf";

         $cfgstring = "object Host \"$key\" {\n";
         $cfgstring .= "   vars.cluster_nodes = [ " . join(",", @{$RedundancyGroup->{$key}}) . " ]\n";
         $cfgstring .= "   import \"network-device-redundancygroup\"\n";
         $cfgstring .= "   }\n";
         WriteConfig($cfgfile, $cfgstring);
      }
   }


   GenerateConfigInterDepdencies() if not defined $ProgramOptions{'device'};
   GenerateConfigUser() if not defined $ProgramOptions{'device'};

   return 1;

}

sub GenerateConfigHost
### Function to generate the host portion of the config for Icinga
### Pre-Condtions: Requires a valid host hash be passed.
### Post-Conditions:  Returns string containing define host block
{
   my $host = shift;
   my @parents :shared; # Array of parents from CDP neighbors
   my $cfgfile = $IcingaPath . "/" . $host->{'name'} . ".conf";


   ### Check if the host is down.  If it is merge in the old config and proceed.
   if( $host->{'state'} eq 'down' )
   {
      my $host_config_ondisk;
      open($host_config_ondisk, '<', $IcingaPath . "/" . $host->{'name'} . ".conf");
      while( my $line = <$host_config_ondisk> )
      {
         if( $line =~ /###/ )
         {
            chomp $line;
            my $data_ondisk = (split(/### /, $line))[1];
            my $olddata = decode_json($data_ondisk);
            $olddata->{keys %$host} = values %$host;
            $host = $olddata;
            last;
         }
      }
   }

   delete $host->{'state'};

   ### Define the host
   my $cfgstring = "object Host \"$host->{'name'}\" {\n";
   $cfgstring .= "### " . encode_json($host) . "\n";
   foreach my $meta (keys %{$host->{'meta'}})
   {
      $cfgstring .= "   vars.meta[\"$meta\"] = \"$host->{'meta'}->{$meta}\"\n";
   }
   $cfgstring .= "   import \"$host->{'meta'}->{'role'}\"\n";
   $cfgstring .= "   address = \"$host->{'addr4'}\"\n" if defined $host->{'addr4'};
   $cfgstring .= "   address6 = \"$host->{'addr6'}\"\n" if defined $host->{'addr6'};
   $cfgstring .= "   vars.community = \"$host->{'community'}\"\n" if defined $host->{'community'};
   $cfgstring .= "   vars.community6 = \"$host->{'community6'}\"\n" if defined $host->{'community6'};

   ### Find parents based on LLDP info.  Use the Icinga Dictionary object to apply dependencies.
   ### Skip Wireless controllers because they don't actually implement the LLDP MIB so we find them
   ### from the other end.
   $cfgstring .= GenerateConfigNeighbor($host) if $host->{'name'} !~ /wlc[0-9]$|wmc[0-9]$/;

   ### Creates an array of configured Interfaces.
   ### Replaces GenerateConfigL3IPv4
   if (defined($host->{'L3IPv4'}))
   {
      foreach my $interface ( @{$host->{'L3IPv4'}} )
      {
         #clean up a few meta characters
         $interface->{'alias'} =~ s/\\//;

         ### Because I did something dirty in the discovery process I have to check if addr4 is
         ### defined.  If it is, its a L3 interface.  If its not then it is a physical interface
         ### of a sub-interface and won't have an addr4 so have to handle it differently here
         if(defined($interface->{'addr4'}))
         {
            $cfgstring .= "   vars.interface\[\"$interface->{'addr4'}\"\] = {\n";
            $cfgstring .= "      ifIndex = \"$interface->{'index'}\"\n";
            $cfgstring .= "      display_name = \"$interface->{'alias'}\"\n";
            $cfgstring .= "      ifName = \"$interface->{'name'}\"\n";
            $cfgstring .= "      addr4 = \"$interface->{'addr4'}\"\n";
            $cfgstring .= "      mask4 = \"$interface->{'mask4'}\"\n";
            $cfgstring .= "      parent = \"$interface->{'parent'}\"\n" if defined($interface->{'parent'});
            $cfgstring .= "      }\n";
         }
         else
         {
            $cfgstring .= "   vars.interface\[\"$interface->{'name'}\"\] = {\n";
            $cfgstring .= "      ifIndex = \"$interface->{'index'}\"\n";
            $cfgstring .= "      display_name = \"$interface->{'alias'}\"\n";
            $cfgstring .= "      ifName = \"$interface->{'name'}\"\n";
            $cfgstring .= "      }\n";
         }
      }
   }

   ### Creates an array of configured BGP Peers.
   ### Replaces GenerateConfigBGPv4
   my $resolver = new Net::DNS::Resolver;
   if (defined($host->{'BGP4'}))
   {
      foreach my $peer ( @{$host->{'BGP4'}} )
      {

         $cfgstring .= "   \# BGP Peer\n" if $peer ne "0.0.0.0";;
         $cfgstring .= "   vars.peer\[\"$peer\"\] = {\n" if $peer ne "0.0.0.0";
         my $reply = $resolver->search($peer, "PTR", "IN");
         if (defined($reply))
         {
            my @record = $reply->answer;
            if( $record[0]{'ptrdname'} ne '' )
            {
               $cfgstring .= "      peername = \"" . join("-",(split(/-/,(split(/\./,$record[0]{'ptrdname'}))[0]))[0..3]) . "\"\n";
            }
         }
         $cfgstring .= "      }\n" if $peer ne "0.0.0.0";
      }
   }

   ### Creates an array of HSRP groups
   if ( defined($host->{'hsrp'}) )
   {
      foreach my $HSRPgroup ( @{$host->{'hsrp'}} )
      {
         $cfgstring .= "   vars.hsrp\[\"$HSRPgroup\"\] = {\n";
         $cfgstring .= "      }\n";
      }
   }

   ### Creates an array of port channel interfaces.
   if (defined($host->{'PortChannel'}))
   {
      foreach my $poIf ( @{$host->{'PortChannel'}} )
      {
         $cfgstring .= "   vars.pointerface\[\"$poIf->{'name'}\"\] = {\n";
         $cfgstring .= "      ifIndex = \"$poIf->{'index'}\"\n";
         $cfgstring .= "      ifName = \"$poIf->{'name'}\"\n";
         $cfgstring .= "      }\n";
      }
   }


   ### If the device is implementing put it in the implementing
   ### host group to disable notifications.
   if ($host->{'lifecycle_status'} eq 'implementing')
   {
      $cfgstring .= "   groups = [ \"implementing\" ]\n";
   }

   $cfgstring .= "   }\n\n";

   if ( defined($host->{'L3IPv4'}) and defined($host->{'BGP4'}) )
   {
      $cfgstring .= GenerateConfigIntraDevice($host);
   }

   WriteConfig($cfgfile, $cfgstring);
   return shared_clone($host);
}

sub GenerateConfigNeighbor
### Function to generate host parent dictionary to apply dependencey to.
### Uses LLDP data collected during interrogation.
### Pre-Conditions: Requires a valid host hash to be passes.
### Post-Conditions: Returns a string containing vars.parents diction object string
###                  Also adds an array element to the host hash containing a list of
###                  parents.  Accessed via $host->{'parent'}
{
   my $host = shift;
   my $cfgstring;
   my $parent;
   my @parents :shared;

   ### First find a the mate for paired devices
   if( $host->{'name'} =~ /wgw|dgw|cgw|sgw|agw/ )
   {
      #print "DEBUG: Finding a mate\n";
      if( defined($host->{'LLDP'}) )
      {
         #print "DEBUG: Going through neighbors\n";
         foreach my $LLDP (@{$host->{'LLDP'}})
         {
            my $matematch = (split(/-/,$host->{'name'}))[-1];
            $matematch =~ s/[0-9]//;
            #print "DEBUG: Matching $matematch to " . $LLDP->{'name'} . "\n";
            if( $LLDP->{'name'} =~ /$matematch/ and $LLDP->{'name'} ne $host->{'name'} )
            {
               $cfgstring .= "   vars.mate = \"$LLDP->{'name'}\"\n";
               last;
            }
         }
      }
   }
   ### Find if device has wlc attached
   if( defined($host->{'LLDP'}) )
   {
      my @wlc_attached;
      foreach my $LLDP (@{$host->{'LLDP'}})
      {
         if( $LLDP->{'name'} =~ /wlc/ )
         {
            push(@wlc_attached, '"' . $LLDP->{'name'} . '"');
         }
      }
      if( scalar(@wlc_attached) > 0 )
      {
         $cfgstring .= "   vars.wlc_attached = [" . join(',', uniq @wlc_attached) . "]\n";
      }
   }

   ### Figure out who the parent is based on naming standards.
   given ( $host->{'name'} )
   {
      when(/off-sgw/)      { $parent = "cgw";}
      when(/off-agw/)      { $parent = "bb-wgw";}
      when(/off-wgw/)      { $parent = "bb-wgw"; }
      when(/off[0-9]*-dgw/)      { $parent = 'off-wgw[0-9]$|off-cgw[0-9]$'; }
      when(/off-vgw/)      { $parent = 'off-dgw[0-9]$|off-cgw'; }
      when(/cenet-vgw/)    { $parent = "bb-cgw"; }
      when(/off-cgw/)      { $parent = "off-wgw"; }
      when(/oob-msw/)      { $parent = 'oob-dgw[0-9]$|oob-cs1'; }
      when(/oob-cs/)       { $parent = "oob-dgw|oob-cgw"; }
      when(/oob-dgw/)      { $parent = 'oob-wgw[0-9]$|oob-cgw'; }
      when(/rsw[0-9]/)     { $parent = "dgw"; }
      when(/msw[0-9]/)     { $parent = "dgw"; }
      when(/ssw[0-9]/)     { $parent = "dgw"; }
      when(/off[0-9]*-sw[0-9]/)  { $parent = "off[0-9]*-dgw"; }
      when(/utl-sw[0-9]/)  { $parent = 'off-dgw[0-9]$'; }
      when(/dc[0-9]-dgw/)  { $parent = "dc-cgw"; }
      when(/dc-cgw/)       { $parent = "bb-cgw"; }
      when(/bb-cgw/)    { $parent = "bb-wgw"; }
      when(/bb-pgw/)    { $parent = "bb-cgw"; }
      when(/bb-ssw/)    { $parent = "bb-pgw"; }
      when(/ext-gw/)       { $parent = "bb-ssw"; }
      when(/trig-gw/)      { $parent = "bb-cgw"; }
      when(/dc-fw/)        { $parent = "dc-cgw"; }
      when(/eng-dgw/)      { $parent = "off-dgw|eng-cgw"; }
      when(/eng-sw/)       { $parent = "eng-dgw"; }
      default              { $parent = "ufvcnfcbbftbgunkgfgejuindlvedhib"; }
   }

   ### Check the interface descriptions. If it has one to a VPN hub LLDP may not exist
   ### and we need to set the parent here based on ifAlias to vpnhub. If it is a device
   ### that connects to a vpn-hub check LLDP exits and set $parent so that it uses the logic
   ### below.  If we don't use LLDP info set @parent and clear LLDP.  Since we set the
   ### parent here we basically want the skip the if below.  Clearing LLDP will fall into
   ### the else which most likely won't affect changes to this host.
   if( defined($host->{'L3IPv4'}) and $host->{'name'} =~ /off-wgw/ )
   {
      if (defined($host->{'LLDP'}))
      {
         foreach my $LLDP (@{$host->{'LLDP'}})
         {
            if ($LLDP->{'name'} =~ /vpn-hub/)
            {
               $parent = "vpn-hub";
            }
         }
      }
      # Check to see if parent was set above if not then check ifAlias
      if ($parent ne 'vpn-hub')
      {
         foreach my $IP4 ( @{$host->{'L3IPv4'}} )
         {
            # Prevents LLDP info from being clobbered for off-wgw on the BB
            if ( $IP4->{'alias'} =~ /vpn-hub/ and $IP4->{'alias'} !~ /FBGUEST/ )
            {
               $host->{'LLDP'} = undef;
               push( @parents, "\"" . ( split(/:/,$IP4->{'alias'}) )[0] . "\"" );
            }
         }
      }
   }

   ### Since we decided who the parent should be find it.
   if ( defined($host->{'LLDP'}) )
   {
      foreach my $LLDP (@{$host->{'LLDP'}})
      {
         if ($LLDP->{'name'} =~ /$parent/ and $parent ne '' and $host->{'name'})
         {
            #print "DEBUG: Adding parent " . $LLDP->{'name'} . "\n";
            push(@parents, "\"" . $LLDP->{'name'} . "\"");
         }
      }
   }
   ### handle devices that don't do LLDP
   else
   {
      given( $host->{'name'} )
      {
         when(/off-fw/ and $_ !~ /lhr102/)                  { s/fw/wgw/; push(@parents, "\"" . $_ . "\"");}
         when(/lhr1-pop-ra-vpn1/)                           { push(@parents, "\"lhr1-pop-dc2-csw1\"");}
      }
   }

   ### If all else fails us the interface descriptions
   if( defined($host->{'L3IPv4'}) and scalar(@parents) == 0)
   {
      foreach my $IP4 ( @{$host->{'L3IPv4'}} )
      {
         my $possibleparent = (split(/:/,$IP4->{'alias'}))[0];
         $possibleparent =~ s/description //g;
         foreach my $device (@HostInfo)
         {
            if( $possibleparent =~ /$parent/ and $possibleparent =~ /$device->{'name'}/ )
            {
               push( @parents, "\"" . $possibleparent . "\"" );
               last;
            }
         }
      }
   }

   $cfgstring .= "   vars.parents = [" . join(',', uniq @parents) . "]\n";
   $host->{'parent'} = \@parents;
   return $cfgstring;
}

sub GenerateConfigUser
### Function to create config file to generate users.  LDAP groups searched
### is controlled by @LDAPGroupsDN
### Pre-Conditions:  None
### Post-Conditions: Uses WriteConfig to create file in generated
{
   ### LDAP Stuff.  None of these should need to be modified
   use Net::LDAP;
   my $LDAPUserBase = "dc=SomeCompany,dc=Internal";
   my $LDAPUserScope = "sub";
   my $LDAPServer = "ldaps://ldap.somecompany.internal:636";


   my @icingausers; #Store DN of found user
   my $cfgstring = '';
   my $cfgfile = "$IcingaPath/user.conf";

   my $subject;
   my $message;

   ### Connect to LDAP server.  This step does not bind so you won't be able to search.
   my $ldap_connection = Net::LDAP->new($LDAPServer);

   ### Bail on error
   if (! defined($ldap_connection))
   {
      $subject = "[WARNING] Icinga2 LDAP Bind\n";
      $message = "Unable to connect to LDAP server $LDAPServer.  Users not modified.";
      StatusNotify($subject, $message);
      return;
   }


   ### Get ldap creds from a file on the file system.  This is a bit of a hack but the guys
   ### in SysOPs were less the helpful so I hacked my way around.  This will handle the changing
   ### of the bind user password, becuase automation updates the file that I read from.
   my $LDAPBindDN = `grep binddn /etc/nslcd.conf`;
   my $LDAPBindPassword = `grep bindpw /etc/nslcd.conf`;
   chomp $LDAPBindDN;
   chomp $LDAPBindPassword;
   $LDAPBindDN = (split(' ', $LDAPBindDN))[-1];
   $LDAPBindPassword = (split(' ', $LDAPBindPassword))[-1];

   ### And now bind.  This will allow searching of LDAP.
   my $ldap_bind = $ldap_connection->bind($LDAPBindDN, password => $LDAPBindPassword);

   ### Bail on error
   if ($ldap_bind->is_error or !defined $ldap_bind)
   {
      $subject = "[WARNING] Icinga2 LDAP Bind\n";
      $message = "Unable to bind to LDAP server $LDAPServer.  Users not modified.";
      StatusNotify($subject, $message);
      return;
   }

   ### Search groups defined in @LDAPGroupsDN and collect all the DN from the member attribute.
   ### I collect all the users here becauce a user can exisit in multiple groups.  For now I am
   ### using existing LDAP groups.  Someday we may add a group just for Icinga Access.
   foreach my $LDAPGroupDN (@LDAPGroupsDN)
   {
      ### Do the search of the group specified.
      my $ldap_search = $ldap_connection->search(
       base => $LDAPUserBase,
       filter => "(&(objectClass=group)(distinguishedName=$LDAPGroupDN))",
       scope => $LDAPUserScope
       );

      ### Bail on error
      if ($ldap_search->is_error or !defined $ldap_search)
      {
         $subject = "[WARNING] Icinga2 LDAP Bind\n";
         $message = "Unable to search LDAP server $LDAPServer.  Users not modified.";
         StatusNotify($subject, $message);
         return;
      }

      ### This is where we grab members of the group and push them to @icingausers.
      foreach my $entry ($ldap_search->entries)
      {
         push(@icingausers, $entry->get_value("member"));
      }
   }

   ### Now that I have uses look them up in LDAP for the attributes I need to create a user
   ### record in Icinga
   foreach my $icingauser ( uniq @icingausers )
   {
      ### Search
      my $ldap_search = $ldap_connection->search(
        base => $LDAPUserBase,
        filter => "(&(objectClass=user)(distinguishedName=$icingauser))",
        scope => $LDAPUserScope
        );

      ### Create the config
      my $username = $ldap_search->pop_entry;
      $cfgstring .= "object User \"" . $username->get_value("samAccountName") . "\" {\n";
      $cfgstring .= "   import \"network-user\"\n";
      $cfgstring .= "   display_name = \"" . $username->get_value("samAccountName") . ":" . $username->get_value("displayName") . "\"\n";
      $cfgstring .= "   }\n\n";
   }

   ### Close user session from LDAP
   $ldap_connection->unbind;

   WriteConfig($cfgfile,$cfgstring);
   return 1;

}

sub GenerateConfigIntraDevice
### Function to generate service dependencies between servcies on a host.
### Creates the following dependencies:
###    BGPv4 -> L3IPv4
### Pre-Condtions: Requires a valid host hash be passed.
### Post-Conditions:  Returns string containing define servicedependecy blocks
{
   my $host = shift;
   my $cfgstring;

   ### Create intra-device dependencies between L3 interfaces
   ### and BGP sessions.  Determined by:  IP address for BGP peer
   ### is in the same network as an interface.
   ### For each interface compare to each BGP peer.
   foreach my $interface ( @{$host->{'L3IPv4'}})
   {
      if( defined($interface->{'addr4'}) )
      {
         my $ifacenetwork = NetAddr::IP->new($interface->{'addr4'},$interface->{'mask4'});
         foreach my $peer (@{$host->{'BGP4'}})
         {
            my $peerip = NetAddr::IP->new($peer);
            if( $ifacenetwork->contains($peerip) )
            {
               $cfgstring .= "object Dependency \"Interface $interface->{'addr4'} BGP $peer\" {\n";
               $cfgstring .= "   parent_host_name = \"$host->{'name'}\"\n";
               $cfgstring .= "   parent_service_name = \"Interface $interface->{'addr4'}\"\n";
               $cfgstring .= "   child_host_name = \"$host->{'name'}\"\n";
               $cfgstring .= "   child_service_name = \"BGP $peer\"\n";
               $cfgstring .= "   states = [ OK ]\n";
               $cfgstring .= "   disable_checks = false\n";
               $cfgstring .= "   ignore_soft_states = false\n";
               $cfgstring .= "   }\n\n";
            }
         }
      }
   }

   return $cfgstring;
}

sub WriteConfig
### Function to write out config data to file
### If --test option prints to STD out otherwise prints to file.
### Pre-Conditions: requires path to file and string containing config
### Post-Conditions: writes config to specified file.
###   returns 1 (TRUE) or 0 (FALSE)
{
   my $cfgFH;
   my $cfgfile = shift;
   my $cfgstring = shift;

   ### if the --test option is used set the file handle to STDOUT
   ### otherwise open the file for writing and generate the config
   if (defined($ProgramOptions{'test'}))
   {
      $cfgFH = \*STDOUT;
   }
   else
   {
      ### Purge existing config file if it exists.
      if ( -f $cfgfile )
      {
         unlink $cfgfile;
      }
      open($cfgFH, '>', $cfgfile) or push(@ConfigErr, $cfgfile) && return 0;
   }

   print $cfgFH $cfgstring;

   if (!defined $ProgramOptions{'test'} && -f $cfgfile)
   {
      close($cfgFH);
      chmod 0664, $cfgfile;
   }

   return 1
}

sub GenerateConfigInterDepdencies
### Parent function to create service dependencies between devices.
### There should be a sub function for each service dependency type.
### Uses all the interrogated data from @HostInfo.
### Pre-Conditions:  None will just exit of @HostInfo is empty.
### Post-Conditions: Writes dependencies to $IcingaPath/generated/interdeps.cfg
{
   my $cfgstring = '';
   my $cfgfile = "$IcingaPath/interdeps.conf";

   ### Interface dependencies.  This function already existed and I didn't want
   ### to re-write it so I manipulate @HostInfo with what is necessary and send
   ### it over. InterDependenciesInterface wants an array of interface hashes but
   ### the one thing that is missing on the interface is hostname.  I have to make
   ### a copy of all the data.  I can't use :shared with NetAddr objects.
   my @interfaces;
   foreach my $host (@HostInfo)
   {
      if ( defined($host->{'L3IPv4'}) )
      {
         foreach my $L3IPv4 (@{$host->{'L3IPv4'}})
         {
            if( defined($L3IPv4->{'addr4'}) )
            {
               if( $L3IPv4->{'name'} !~ /Tunnel[1-2]$/ )
               {
                  my %interface;
                  $interface{'host'} = $host->{'name'};
                  $interface{'parent'} = join('|', uniq @{$host->{'parent'}}) if defined($host->{'parent'});
                  $interface{'parent'} =~ s/\"//g;
                  $interface{'addr4'} = $L3IPv4->{'addr4'};
                  $interface{'mask4'} = $L3IPv4->{'mask4'};
                  push(@interfaces, \%interface);
               }
            }
         }
      }
   }
   $cfgstring .= InterDependenciesInterface(\@interfaces);
   undef @interfaces;

   WriteConfig($cfgfile, $cfgstring);
}

sub InterDependenciesInterface
### Function to create interface service dependencies between devices.
### Pre-Conditions: Requires an Array of Interface Hashes from the host hash structure
### Post-Conditions: Returns string containing define servicedependacy blocks for
###    inter-device interface dependencies.
{
   my $interfaces = shift;
   my @netblocks;
   my $cfgstring;

   ### Create NetAddr object for all the interfaces and add to the interface
   ### Cast by_ref passed in back to an array.
   foreach my $interface (@{$interfaces})
   {
      my $netblock = NetAddr::IP->new($interface->{'addr4'},$interface->{'mask4'});
      $interface->{'netblock'} = $netblock;
      push(@netblocks, $interface);
   }

   ### The logic here is a bit tricky.  Each netblock needs to be compared to all
   ### other netblocks.  But for efficiency this is only done once.  For example:
   ### if you are on the 100th element of the array and you didn't pop the head, it would
   ### compare to all elements, starting at the beginning.  The comparison [99]->[0]
   ### has all ready been done, [0]->[99].
   ### The head of the array is popped and compared to the remaining of the elements of the array.

   ### The outer while is control to make sure there are still elements to compare.
   while ( @netblocks > 0 )
   {
      ### The head of the array is popped.
      my $interface = shift(@netblocks);
      ### compare the head of the array to the remaining elements of the array.
      foreach my $neighbor ( @netblocks )
      {
         ### Make sure you aren't comparing interfaces from the same host or GUEST tunnel address
         if ($interface->{'host'} !~ $neighbor->{'host'} and $interface->{'addr4'} !~ /172\.22\.[0-1]\.[0-2]{0,1}[0-5]{0,1}[0-5]/)
         {
            ### If the next element is in the same network as this interface you're getting closer.
            if( $interface->{'netblock'}->contains($neighbor->{'netblock'}) and $interface->{'addr4'} ne $neighbor->{'addr4'} )
            {
               #print "DEBUG: interface - $interface->{'host'}\n";
               #print "DEBUG: i-parent - $interface->{'parent'}\n";
               #print "DEBUG: neighbor - $neighbor->{'host'}\n";
               #print "DEBUG: n-parent - $neighbor->{'parent'}\n";
               my $search = $interface->{'parent'};
               if ( $neighbor->{'host'} =~ /$search/)
               {
                  #print "DEBUG: keeping order\n\n";
                  $cfgstring .= "object Dependency \"$interface->{'host'}-$interface->{'addr4'} $neighbor->{'host'}-$neighbor->{'addr4'}\" {\n";
                  $cfgstring .= "   parent_host_name = \"$interface->{'host'}\"\n";
                  $cfgstring .= "   parent_service_name = \"Interface $interface->{'addr4'}\"\n";
                  $cfgstring .= "   child_host_name = \"$neighbor->{'host'}\"\n";
                  $cfgstring .= "   child_service_name = \"Interface $neighbor->{'addr4'}\"\n";
                  $cfgstring .= "   states = [ OK ]\n";
                  $cfgstring .= "   disable_checks = false\n";
                  $cfgstring .= "   ignore_soft_states = false\n";
                  $cfgstring .= "   }\n\n";
               }
               else
               {
                  #print "DEBUG: swapping order\n\n";
                  $cfgstring .= "object Dependency \"$neighbor->{'host'}-$neighbor->{'addr4'} $interface->{'host'}-$interface->{'addr4'}\" {\n";
                  $cfgstring .= "   parent_host_name = \"$neighbor->{'host'}\"\n";
                  $cfgstring .= "   parent_service_name = \"Interface $neighbor->{'addr4'}\"\n";
                  $cfgstring .= "   child_host_name = \"$interface->{'host'}\"\n";
                  $cfgstring .= "   child_service_name = \"Interface $interface->{'addr4'}\"\n";
                  $cfgstring .= "   states = [ OK ]\n";
                  $cfgstring .= "   disable_checks = false\n";
                  $cfgstring .= "   ignore_soft_states = false\n";
                  $cfgstring .= "   }\n\n";
               }
               last;

            }
         }
      }
   }

   return $cfgstring;

}

sub syncWithSOT
{
   require Net::INET6Glue::INET_is_INET6;
   require URI;
   require REST::Client;
   require Monitor::Tools;
   $ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

   my $host_list;
   my $retries = 0;
   my $StartTime = time;

   my $client = REST::Client->new( {host => "https://SOT.somecompany.internal", timeout => 20} );
   my $url = "/api/v1/node";
   my $get_data->{'options'} = encode_json({ embed => [ "platform", "location", "group" ], filters => ["lifecycle_status != 'decommissioned'"]});
   $get_data->{'filter'} = encode_json({ name => $ProgramOptions{'device'} }) if defined $ProgramOptions{'device'};

   while( $retries < $SOT_attempts )
   {
      $client->GET( $url . $client->buildQuery($get_data) );
      my $post_response = $client->responseContent();
      if( $client->responseCode() != 200 )
      {
         send_to_heartbeat( { service => 'Icinga2 SOT Sync',
                              status_message => $client->responseContent(),
                              status_code => '1'
                         }) if not defined $ProgramOptions{'test'};
         print "Unable to connect to SOT Endpoint.\n" . $post_response ."\n" if defined $ProgramOptions{'test'};
         print "Retry....\n" if $retries < $SOT_attempts -1 and defined $ProgramOptions{'test'};
      }
      $retries++;
      sleep 5;
   };

   $StatusTrack .= "Time to fetch from SOT: " . (time - $StartTime) . "s\n";

   return 0 if $client->responseCode() != 200;
   $StartTime = time;

   my $raw_data = decode_json($client->responseContent());

   foreach my $row ( @$raw_data )
   {
      next if( $row->{'name'} =~ /lab/ and $row->{'name'} !~ /eng/ );
      my $host = {};
      $host->{'name'} = (split(/\./,$row->{'name'}))[0] if defined $row->{'name'};
      $host->{'lifecycle_status'} = $row->{'lifecycle_status'} if defined $row->{'lifecycle_status'};
      $host->{'meta'}->{'model'} = $row->{'platform_name'} if defined $row->{'platform_name'};
      $host->{'meta'}->{'vendor'} = $row->{'platform'}->{'vendor'} if defined $row->{'platform'}->{'vendor'};
      $host->{'meta'}->{'region'} = $row->{'location'}->{'region'} if defined $row->{'location'}->{'region'};
      $host->{'meta'}->{'site_code'} = lc($row->{'location'}->{'sitecode'}) if defined $row->{'location'}->{'sitecode'};
      $host->{'meta'}->{'role'} = $row->{'role_name'} if defined $row->{'role_name'};
      $host->{'meta'}->{'os'} = $row->{'platform'}->{'os_type'} if defined $row->{'platform'}->{'os_type'};
      $host->{'redundancy_group'} = $row->{'group_name'} if defined $row->{'group_name'};
      $host->{'community'} = $row->{'mgmt_snmp_community4'} if defined $row->{'mgmt_snmp_community4'};
      $host->{'community6'} = defined $row->{'mgmt_snmp_community6'} ? $row->{'mgmt_snmp_community6'} : $row->{'mgmt_snmp_community4'};

      if( not defined($host->{'meta'}->{'role'}) )
      {
         $host->{'meta'}->{'role'} = "network-device-unclassified";
      }
      if( $host->{'name'} =~ /oob/ and not defined($host->{'meta'}->{'vendor'}) )
      {
         $host->{'meta'}->{'vendor'} = "cisco";
      }

      $HostsQ->enqueue(shared_clone($host)) if defined $host->{'name'};
      ### Build some other structures for later on
      $host_list->{$host->{'name'}} = 1;
      push(@{$RedundancyGroup->{$row->{'group'}->{'name'}}}, '"' . $host->{'name'} . '"') if defined $row->{'group'};
   }

   ### Clean up config of decom and name change devices.  Will grab other generated config like
   ### host groups and such.
   my @existingconfigs = glob "$IcingaPath/*.conf";
   foreach my $existingconfig ( @existingconfigs )
   {
      my $filename = (split(/\//, $existingconfig))[-1];
      $filename =~ s/\.conf//g;
      if( not $host_list->{$filename} and not defined $ProgramOptions{'device'} )
      {
         #unlink $existingconfig if not defined $ProgramOptions{'test'};
         push(@DeleteMe, $existingconfig) if not defined $ProgramOptions{'test'};
         print "Should remove $existingconfig, but not going to... becuase test mode\n" if defined $ProgramOptions{'test'};
      }
   }

   $StatusTrack .= "Time to build queue for interrogate: " . (time - $StartTime) . "s\n";
   return 1;

}
sub StatusNotify
### Function to notify of errors.  For CLI prints to STDOUT and if run in
### ENM SYNC mode send email.  Rather then putting basically the same block
### of code all over the place.  Consolidated to a single function.
### Pre-Conditions: requires a string for email subject and a string for body of message
### Post-Conditions: If --device is used prints message to STDOUT.  If used in
###    ENM SYNC mode generates email to network-alerts
{
   if ( defined($ProgramOptions{'test'}) )
   {
      return;
   }
   my $subject = shift;
   my $message = shift;

   if ( defined($ProgramOptions{'device'}) )
   {
      print $message;
   }
   else
   {
     `echo "$message" | /bin/mail -s "$subject" -r pacomctaco\@fb.com network\@fb.com` if( $message ne '' );
   }
}


sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "device:s",
      "test"
   );
}
