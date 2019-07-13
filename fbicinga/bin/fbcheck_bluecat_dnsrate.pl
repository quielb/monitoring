#!/usr/bin/perl
use POSIX;
use strict;
use Getopt::Long qw(:config no_ignore_case);

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

my %ProgramOptions; # Hash to store CLI options
ParseOptions(); # Get CLI options.  Probably need to update GetOptions to accept more options

if( not defined($ProgramOptions{'rate'}) )
{
   print "UNKNOWN - Query Rate not specified\n";
   exit Monitor::Tools::UNKNOWN;
}

my $ods_timeseries = check_ods({
   entity => $ProgramOptions{'entity'},
   key => $ProgramOptions{'key'},
   transform => 'rate(30m,duration=1),last',
   freshness => $ProgramOptions{'freshness'},
   warn => $ProgramOptions{'warn'},
   crit => $ProgramOptions{'crit'},
   title => $ProgramOptions{'title'}
   });

if( not defined($ods_timeseries) )
{
   print $Monitor::Tools::output;
   exit Monitor::Tools::CRITICAL;
}

foreach my $key ( keys %{$ods_timeseries->{'values'}} )
{
   if( $ods_timeseries->{'values'}->{$key} < 0 )
   {
      print "OK - Query rate is less then 0.  Looks like counter rolled\n";
      exit Monitor::Tools::OK;
   }
   if( $ods_timeseries->{'values'}->{$key} < $ProgramOptions{'rate'} )
   {
      print "CRITICAL - DNS query success rate is below threshold.\n";
      exit Monitor::Tools::CRITICAL;
   }
}

print "OK - DNS Query rate is good.  This server appears to be working\n";
exit Monitor::Tools::OK;

sub ParseOptions
{
    GetOptions( \%ProgramOptions,
      'entity|E=s',
      'key|K=s',
      'freshness|F:i',
      'rate=i'
   );
}

