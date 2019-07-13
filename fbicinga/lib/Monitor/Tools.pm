### This is a package for commonly used Icinga plugin stuff.
### Basically its a lot of code that is repleated in all the
### plugins.  For consistency and quick change it is put here
package Monitor::Tools;
use strict;

use Exporter qw(import);
our @EXPORT = qw(snmp_connect check_threshold check_TSDB send_http_post is_config_master send_to_chronicle get_cisco_sxl);

use constant {
   OK => 0,
   WARNING => 1,
   CRITICAL => 2,
   UNKNOWN => 3 };


our $snmp_cli;
our $status;
our $output;
our $post_response;

our $appID = '379221528933002';
our $token = 'AePf3xawhSOT9-scPNk';

our $le = sub { $_[0] <= $_[1] };
our $lt = sub { $_[0] < $_[1] };
our $ge = sub { $_[0] >= $_[1] };
our $gt = sub { $_[0] > $_[1] };

sub snmp_connect
### This is a function to establish and verify an SNMP connection
### to a device.  It will handle both v4 and v6 IP addresses.
### Pre-Conditions:  a hostname and v4 or v6 IP address must be passed
###   Only IP addresses will work.  If you pass a host name this will
###   most likely break.
### Post-Conditions:  if an SNMP session can be a established an SNMP
###   is returned.  If there is an error undef is returned.
###   Corpnet::FBIcinga::status and Corpnet::FBIcinga::output are set
###   and can be used from your main program as valid plugin output.
{
   require SNMP;

   my $params;
   if ( ref($_[0]) eq "HASH" )
   {
      $params = shift;
   }
   else
   {
      $params->{'host'} = shift;
      $params->{'comunity'} = shift;
   }
   my $snmp_sysDescr = '.1.3.6.1.2.1.1.1.0';
   my $session;  # SNMP Session to be used for the entire plugin

   if( $params->{'host'} =~ /:/ )
   {
      $params->{'host'} = "udp6:" . $params->{'host'};
   }
   $snmp_cli = "SNMP CLI check: snmpbulkwalk -v 2c -c xxxxxxxx -O n $params->{'host'}";
   ### Establish SNMP session to device.  The only option that should need to be tweeked is the
   ### timeout value.  Fetching large mounts of data, ie a large ifIndex table, may not complete
   ### for the timeout and result in either partial data or a falure of somesort.  Just depends
   ### on what kind of mood Perl is in.
   my %session_opts =
   (
      DestHost => $params->{'host'},
      Community => $params->{'comunity'},
      Version    => '2c',
      UseNumeric => 1,
      UseEnums => 0,
      RetryNoSuch => 0,
      Retries => 2,
      Timeout => 2000000
   );


   ### Check that we were able to connect to the device.  We have to check it twice.  Sometimes
   ### you can open the session and but can't pull any data ( ACL related ).  Varies by vendor
   ### and platform
   my $session = SNMP::Session->new(%session_opts);

   ### Try to actualy fetch an OID.
   my $sysDescr = $session->get($snmp_sysDescr);

   if( $session->{ErrorStr} )
   {
      ### It didn't exist so exit out UNKNOWN.  Hopefully $errortxt has something useful
      $status = UNKNOWN;
      $output = "UNKNOWN - Unable to establish SNMP session to $params->{'host'} " . $session->{ErrorStr} . "\n";
      return undef;
   }

   return $session;
}

sub check_threshold
### A function to validate alert thresholds.  Checks to make sure they are defined and that
### the values are sane.
### Pre-Conditions:  A warning and critical values must be passed in.
### Post-Conditions: Returns true if values (1) are sane.  Returns false (0) if something is wrong.
###   Corpnet::FBIcinga::status and Corpnet::FBIcinga::output are set
###   and can be used from your main program as valid plugin output.
{
   my $warn = shift;
   my $crit = shift;

   if( $warn == -1 or $crit == -1 or not defined($warn) or not defined($crit) )
   {
      $output = "UNKNOWN - Threshold values not defined\n";
      $status = UNKNOWN;
      return 0;
   }
   if( $warn >= $crit )
   {
      $output = "UNKNOWN - Warning threshold ($warn) must be less then critical ($crit) threshold\n";
      $status = UNKNOWN;
      return 0;
   }
   return 1;
}

sub check_tsdb
### Function to grab data from TSDB.  Takes an entity and key.  Ideally the entity and key only match
### one time series from TSDB.  You can provide an entity/key that returns multiple series, but only
### the first series (element 0) will be returned.  Depending on the options passed in (warn, crit)
### it will do the threshold evaluation and set Corpnet::FBIcinga::status and Corpnet::FBIcinga::output
### for you.  To trigger a threshold evaluation you also need to specify a transform of latest.
### Those values can then be used from Main.
### Pre-Conditions:  Requires a hash ref to be passed that contains all the parameters.
###   REQUIRED HASH KEYS: entity, key
###   OPTIONAL HASH KEYS: freshness, title, reduce, transform, warn, crit
###      freshness - Number of seconds to comapare the newest datapoint in the time series.
###      title - String to put in status output.  Only used if warn and crit are defined.
###      warn - Warning threshold.  There are no sanity checks.
###      crit - Critical threshold.  There are no sanity checks.
###      transform - Any valid TSDB transform
###      reduce - Any valid TSDB reduction.
### Post-Conditions: Valid data is returned as a hash ref.  Check the rapido cli wiki to see the format.
###   The JSON that is returned is converted to a perl data structure.  You might want to use Dumper
###   to peek at it.  undef is returned on error, and there a lot of possible "errors".
###   Corpnet::FBIcinga::status and Corpnet::FBIcinga::output are set
###   and can be used from your main program as valid plugin output.
{
   require URI;
   require REST::Client;
   require JSON;
   JSON->import(qw(decode_json encode_json));

   my $params = shift;
   my $fetched_data;

   ### If entity/key aren't set, bail.  Can't query TSDB without them.
   if( not defined($params->{'entity'}) or not defined($params->{'key'}) )
   {
      $output = "UNKNOWN - No valid entity or key defined\n";
      $status = UNKNOWN;
      return undef;
   }

    if (not defined($params->{'mode'}) or
        $params->{'mode'} !~ /^(g|l)(e|t)$/) {
        $params->{'mode'} = 'gt';
    }

    my $override_msgs;
    if (defined($params->{'override_msgs'})) {
        # Silly perl. Still no try?
        eval {
            $override_msgs = decode_json($params->{'override_msgs'});
        } or do {
            $override_msgs = {};
        }
    } else {
        $override_msgs = {};
    }

   ### Build connection and URL to query TSDB.
   ### for more info on the REST API
   my $client = REST::Client->new({ host => $tsdb_host, timeout => 5 });
   my $url = "/tsdb";
   my $get_data->{'query'} = encode_json({entity => $params->{'entity'},
                 key => $params->{'key'},
                 transform => $params->{'transform'},
                 reduce => $params->{'reduce'} });
   $get_data->{'access_token'} = $tsdb_host_token;


   ### Send IT!
   $client->GET($url . $client->buildQuery($get_data));
   my $response_code = $client->responseCode();
   my $post_response = $client->responseContent();

   ### No HTTP 200 response code?  Find out why and return
   if( $response_code != 200 )
   {
      sleep(1);
      $client->GET($url . $client->buildQuery($get_data));
      $response_code = $client->responseCode();
      $post_response = $client->responseContent();
   }
   if( $response_code != 200 )
   {
      $status = UNKNOWN;
      $output = "UNKNOWN - Server returned a " . $response_code . " error: ";
      $output .= $post_response . "\n";
      return undef;
   }
   ### So no server error.  But we can get empty data becuase of bad entity/keys or there
   ### just isn't any data.  No data means unknown.
   else
   {
      $fetched_data = decode_json($post_response)->{'data'};
      if( not defined($fetched_data) or scalar(@$fetched_data) == 0 )
      {
         $status = UNKNOWN;
         $output = "UNKNOWN - TSDB Query was successful, but no data was returned.  Is the entity/key pair valid?\n";
         return undef;
      }
   }

    # Sort so latest timestamp is first (values keyed by value timestamp)
    my @times = (sort {$b <=> $a}  keys %{$fetched_data->[0]->{'values'}});
    if (defined($params->{'freshness'})) {
        my $age = time - $times[0];
        if ($age > $params->{'freshness'}) {
            $status = UNKNOWN;
            $output = "UNKNOWN - Data timestamp is older than freshness "
                        . "interval. ($age > $params->{'freshness'}). "
                        . "Is the collection broken?\n";
            return undef;
        }
    }

    ### warn, crit and transform of latests must be passed to trigger threshold evaluation.
    if(defined($params->{'warn'})
       and defined($params->{'crit'})
       and $params->{'transform'} =~ /last$|latest$|newest$/ ) {

        my $dp = $fetched_data->[0]->{'values'}->{$times[0]};
        my $mode = $params->{'mode'};
        my $title = (defined($params->{'title'}))
            ? $params->{'title'} : "TSDB Data Point";
        my $msgs;
        my $op;
        my ($bad_context, $good_context) = '';

        if ($mode eq 'gt') {
            $op = $gt;
            $bad_context = 'is above';
            $good_context = 'is below';
        } elsif ($mode eq 'ge') {
            $op = $ge;
            $bad_context = 'is above or equal to';
            $good_context = 'is below';
        } elsif ($mode eq 'lt') {
            $op = $lt;
            $bad_context = 'is below';
            $good_context = 'is above';
        } elsif ($mode eq 'le') {
            $op = $le;
            $bad_context = 'is below or equal to';
            $good_context = 'is above';
        }

        if (scalar(keys(%{$override_msgs}))) {
            $msgs = $override_msgs;
        } else {
            $msgs = {
                'CRITICAL' => "$title $bad_context $params->{'crit'} ($dp)",
                'WARNING' => "$title $bad_context $params->{'warn'} ($dp)",
                'OK' => "$title $good_context $params->{'warn'} ($dp)",
            };
        }

        if ($op->($dp, $params->{'crit'})) {
            $status = CRITICAL;
            $output = "CRITICAL - $msgs->{'CRITICAL'}\n";
        } elsif ($op->($dp, $params->{'warn'})) {
            $status = WARNING;
            $output = "WARNING - $msgs->{'WARNING'}\n";
        } else {
            $status = OK;
            $output = "OK - $msgs->{'OK'}\n";
        }
    }

   ### All done.  Here is your data.
   return $fetched_data->[0];
}

sub send_http_post
{
   require Net::INET6Glue::INET_is_INET6;
   require URI;
   require REST::Client;

   $ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

   my $params = shift;

   my $uri = URI->new();
   my $client = REST::Client->new();
   $client->setHost($params->{'host'});
   $client->setTimeout(5);
   $client->addHeader('Content-Type', 'application/x-www-form-urlencoded');

   $uri->query_form($params->{'post_data'});
   $client->POST($params->{'post_url'}, $uri->query);
   $post_response = $client->responseContent();

   if( $client->responseCode() != 200 )
   {
      if( $client->responseContent() =~ /Connection refused/ )
      {
         sleep(1);
         $client->POST($params->{'post_url'}, $uri->query);
         $post_response = $client->responseContent();
      }
   }

   return $client->responseCode();

}

sub send_to_heartbeat
{
   my $params = shift;
   my $host = 'https://heartbeat.somecompay.internal';
   
   $params->{'owner'} = '1234567890' if not defined $params->{'owner'};
   send_http_post( {host => $host, post_url=> $url, post_data => $params} );
}

sub is_config_master
{
   require Sys::Hostname;
   require Env;

   my $host = Sys::Hostname::hostname();
   if( not defined($ENV{'ICINGA_MASTER'}) )
   {
      print "OOPS there is no ICINGA_MASTER ENV set.  I don't know what to do....\n";
      print "   bye\n";
      return 0;
   }
   if( $ENV{'ICINGA_MASTER'} =~ /$host/ )
   {
      return 1;
   }
   return 0;
}

sub get_cisco_sxl
{
   require SOAP::Lite;

   my $params = shift;

   if( not defined($params->{'hostname'}))
   {
      $output = "UNKNOWN - No Host specified\n";
      $status = UNKNOWN;
      return undef;
   }
   if( not defined($params->{'category'}) )
   {
      $output = "UNKNOWN - A Category must be defined\n";
      $status = UNKNOWN;
      return undef;
   }

   my $client = SOAP::Lite->new( proxy => "https://$params->{'hostname'}:8443/perfmonservice2/services/PerfmonService" );
   $client->autotype(0);
   $client->ns('http://schemas.cisco.com/ast/soap', 'soap');
   $client->ns('http://schemas.xmlsoap.org/soap/envelope/', 'soapenv');
   my $som = $client->call(
      SOAP::Data->name('perfmonCollectCounterData')->prefix('soap'),
      SOAP::Data->name('Host')->value($params->{'hostname'})->prefix('soap'),
      SOAP::Data->name('Object')->value($params->{'category'})->prefix('soap'),
   );

   if( $client->transport->status !~ /^200|500/ )
   {
      $output = "UNKNOWN - " . $client->transport->status . "\n";
      $status = UNKNOWN;
      return undef;
   }

   if( $som->fault )
   {
      $output = "UNKNOWN - " . $client->fault->faultstring . "\n";
      $status = UNKNOWN;
      return undef;
   }

   if( scalar($som->paramsout) == 0 )
   {
      $output = "UNKNOWN - Query returned no data\n";
      $status = UNKNOWN;
      return undef;
   }
   return [$som->paramsout];
}

1;
