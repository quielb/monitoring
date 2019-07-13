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

my $sxl_data = get_cisco_sxl({ hostname => $ProgramOptions{'hostname'}, category => $ProgramOptions{'entity'} });
if( not defined($sxl_data) )
{
   print $Monitor::Tools::output;
   exit Monitor::Tools::UNKNOWN;
}

foreach my $i (@$sxl_data)
{
   if( $ProgramOptions{'key'} eq (split(/\\/, $i->{'Name'}))[-1] )
   {
      next if $i->{'Name'} !~ /$ProgramOptions{'instance'}/ and defined $ProgramOptions{'instance'};
      if( $ProgramOptions{'compare'} =~ /greater/i )
      {
         if( $i->{'Value'} >= $ProgramOptions{'crit'} )
         {
            print "CRITICAL - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is over threshold (" . $ProgramOptions{'crit'} . ")\n";
            exit Monitor::Tools::CRITICAL;
         }
         elsif( $i->{'Value'} >= $ProgramOptions{'warn'} )
         {
            print "WARNING - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is over threshold (" . $ProgramOptions{'warn'} . ")\n";
            exit Monitor::Tools::WARNING;
         }
         else
         {
            print "OK - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is below threshold (" . $ProgramOptions{'warn'} . ")\n";
            exit Monitor::Tools::OK;
         }
      }
      elsif( $ProgramOptions{'compare'} =~ /less/i )
      {
         if( $i->{'Value'} <= $ProgramOptions{'crit'} )
         {
            print "CRITICAL - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is below threshold (" . $ProgramOptions{'crit'} . ")\n";
            exit Monitor::Tools::CRITICAL;
         }
         elsif( $i->{'Value'} <= $ProgramOptions{'warn'} )
         {
            print "WARNING - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is below threshold (" . $ProgramOptions{'warn'} . ")\n";
            exit Monitor::Tools::WARNING;
         }
         else
         {
            print "OK - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "is over threshold (" . $ProgramOptions{'warn'} . ")\n";
            exit Monitor::Tools::OK;
         }
      }
      elsif( defined($ProgramOptions{'expected'}) )
      {
         if( $i->{'Value'} != $ProgramOptions{'expected'} )
         {
            print "CRITICAL - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "does not match expected value (" . $ProgramOptions{'expected'} . ")\n";
            exit Monitor::Tools::CRITICAL; 
         }
         else
         {
            print "OK - ";
            print $ProgramOptions{'key'} . " (" . $i->{'Value'} . ") ";
            print "matches expected value (" . $ProgramOptions{'expected'} . ")\n";
            exit Monitor::Tools::OK;
         }
      }
      else
      {
         print "UNKNOWN - Invalid comparision type '$ProgramOptions{'compare'}'\n";
         exit Monitor::Tools::UNKNOWN;
      }
   }
}

print "UNKNOWN - The key '$ProgramOptions{'key'}' was not matched ";
print "in the data returned from tree '$ProgramOptions{'entity'}'\n";
exit Monitor::Tools::UNKNOWN;
         
sub SOAP::Transport::HTTP::Client::get_basic_credentials
{ 
   return $ProgramOptions{'username'} => $ProgramOptions{'password'};
}

sub ParseOptions
{
   GetOptions( \%ProgramOptions,
      "hostname|H=s",
      "username|u=s",
      "password|p=s",
      "entity|e=s",
      "key|k=s",
      "instance|i:s",
      "compare|m=s",
      "warn|w:i",
      "crit|c:i",
      "expected:s"
   );
}

