#!/usr/bin/perl

### OMG so many modules to import
use POSIX;
use strict;
use Getopt::Long;
use Env;
use DBI;
use DBD::mysql;
use feature 'switch'; # Needed for given blocks
use Log::Trivial;
use JSON qw( decode_json );
use JSON qw( encode_json );
use DateTime;
use Sys::Hostname;
use Sys::Syslog qw( :DEFAULT setlogsock );

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0) . '/lib';
use Monitor::Tools;

### Set some defaults
my $log_file = '/var/log/icinga2/notification.log';
my $chirp_email = 'alerts@somecompany.internal';

### Get the options passed to CLI and read from ENV
my %ProgramOptions;
ParseOptions();

if ($ProgramOptions{'email'} eq '')
{
   exit 0;
}


### At one point there was a function to build notification_data with some values from the
### livestatus API.  I don't need that anymore but I didn't want to change all the referenes
### so I just made an assignment.
my $notification_data = \%ProgramOptions;

if( defined($notification_data->{'test'}) )
{
   $log_file = '/var/log/icinga2/notification-test.log';
   $chirp_email = 'barryq@fb.com';
   $notification_data->{'email'} = 'barryq@fb.com';
}


my $log = Log::Trivial->new(log_file => $log_file);

### Build the message body.  Used in email message body and AM detail field
$notification_data->{'notification'} = GenerateMessage();

if( $notification_data->{'notification'}->[1] =~ /Remote Icinga instance/ )
{
  WriteLog("AM-DROP");
  exit 0;
}
###  Becuase of some bugs in Icinga and other stuff we only send notification for specific conditions
###  everything else is dropped and logged.
if( $notification_data->{'state'} =~ /OK|UP/ )
{
   SendAlertManager();
}
elsif( $notification_data->{'type'} =~ /DOWNTIME|PROBLEM/ )
{
   SendAlertManager();
} 
else
{
   WriteLog("AM-DROP");
}

#if ( !defined($notification_data->{'autotask'}) and $notification_data->{'type'} !~ /FLAPPING|DOWNTIME/ and $notification_data->{'level'} !~ /P(3|4)/ )
#{
#   WriteLog("EMAIL");
#   SendEmail();
#}

sub GenerateMessage
### Function to generate the body of the notification.  It also builds a subject for emails.
### Pre-Conditions: None.  But there should be some data in the notification_data hash or
#       this will fail very badly.
### Post-Conditions: Returns a 2 element array reference.   1st element is a string for an
#       email subject.  The second element is the alert detail message.
{
   
   my $subject = '';
   my $message = '';

   if( defined($notification_data->{'test'}) )
   {
      $subject .= "[TEST]";
   }
   
   if ($notification_data->{'type'} =~ /ACKNOWLEDGEMENT/)
   {
      $subject .= "[ACK]";
   }
   elsif ($notification_data->{'type'} =~ /FLAPPING|DOWNTIME/)
   {
      $subject .= "[$notification_data->{'type'}]";
   }
   else
   {
      $subject .= "[$notification_data->{'state'}]";
   }
     
   $subject .= "[$notification_data->{'level'}] $notification_data->{'host'}";
   $subject .= " $notification_data->{'service'}";
   
   #$message .= "DATE/TIME: $notification_data->{'date'}\t\n";
   $message .= "Notification: $notification_data->{'type'}\t\n";
   $message .= "Command Endpoint: $notification_data->{'endpoint'}\t\n\n" if $notification_data->{'endpoint'} ne '';
   
   $message .= "STATUS: $notification_data->{'state'}\t\n";
   $message .= "PLEVEL: $notification_data->{'level'}\t\n";
   $message .= "HOST: $notification_data->{'host'} ($notification_data->{'address'})\t\n";

   if ( $notification_data->{'service'} ne '' )
   {
      $message .= "SERVICE: $notification_data->{'service'}";
      if ( $notification_data->{'displayname'} ne $notification_data->{'service'} )
      {
         $message .= " ($notification_data->{'displayname'})";
      }
      $message .= "\t\n";
   }
   $message .= "ALERT DETAIL: $notification_data->{'checkoutput'}\t\n";

   $message .= "\nCOMMENT FROM: $notification_data->{'author'}\t\n" if $notification_data->{'author'} ne '';
   $message .= "COMMENT DETAIL: $notification_data->{'comment'}\t\n" if $notification_data->{'comment'} ne '';

   if ( $notification_data->{'service'} ne '' )
   {
      my $service = $notification_data->{'service'};
      $service =~ s/\s/+/g;
      $message .= "\nhttps://" . hostname . ".thefacebook.com/icinga/cgi-bin/extinfo.cgi?type=2&host=$notification_data->{'host'}&service=$service\t\n\n";
   }
   else
   {
      $message .= "\nhttps://" . hostname . ".thefacebook.com/icinga/cgi-bin/extinfo.cgi?type=1&host=$notification_data->{'host'}\t\n\n";
   }

   my @alert;
   push(@alert, $subject);
   push(@alert, $message);
   return \@alert;
}
 
sub SendEmail
{

   my $subject = $notification_data->{'notification'}->[0];
   my $message = $notification_data->{'notification'}->[1];
   
   `echo "$message" | /bin/mail -s "$subject" -r alert\@somecompany.internal $notification_data->{'email'}`;
}

sub SendAlertManager
{
   my $alerts;
   my $alert;
   my $post_data;
   my %plevel_map = ( 'P1' => 'major', 'P2' => 'minor', 'P3' => 'warning', 'P4' => 'notice');

   
   $post_data->{'app'} = $Monitor::Tools::appID;
   $post_data->{'token'} = $Monitor::Tools::token;

   if( defined($notification_data->{'author'}) )
   {
      my $resp = send_http_post( 
                  { host => $Monitor::Tools::noisemaker, 
                    post_url => '/employee/' . $notification_data->{'author'},
                    post_data => $post_data });
      if( $resp == 200 )
      {
         $alert->{'owner'} = decode_json($Monitor::Tools::post_response)->{'id'};   
      }
   }

   $post_data->{'viewer_id'} = "100006841066674";
   
   $alert->{'entity'} = $notification_data->{'entity'};
   $alert->{'key'} = $notification_data->{'key'};
   $alert->{'alert'} = "[" . $notification_data->{'level'} . "] " . $notification_data->{'amalert'};
   
   
   if ( $notification_data->{'state'} !~ /OK|UP/ and $notification_data->{'type'} ne 'DOWNTIMESTART')
   {
      $alert->{'expire_time'} = time + ( 3600 * 8 ); # Current time + 8 hours
      $alert->{'text'} = $notification_data->{'notification'}->[1];
      $alert->{'alert_urgency'} = $plevel_map{$notification_data->{'level'}};
      $alert->{'devicename'} = $notification_data->{'host'} . ".corp.somecompany.internal";
      $alert->{'entity_fqdn'} = $alert->{'devicename'};
      if( defined($notification_data->{'links'}) and $notification_data->{'links'} ne '' )
      {
         $alert->{'links'} = "TSDB Chart:" . $notification_data->{'links'};
         $alert->{'links'} =~ s/\'//g;
      }

      my @task_tags = split(/,/, $notification_data->{'tags'}) if defined($notification_data->{'tags'});
      foreach my $task_tag ( @task_tags )
      {
         $task_tag =~ s/^\s+|\s+$//g;
         $alert->{'tags'}{$task_tag} = "true";
      }
      $alert->{'tags'}{(split(/-/, $notification_data->{'host'}))[0]} = "true";
      $alert->{'tags'}{$notification_data->{'level'}} = "true";

      delete $post_data->{'viewer_id'};
         
      WriteLog("AM-CREATE");
   }
   else
   {
      WriteLog("AM-CLEAR");
   }
   
   push(@$alerts, $alert);
   $post_data->{'alerts'} = encode_json($alerts);

   my $post_url = "/alert/clear";
   $post_url = "/alert/create" if not defined $post_data->{'viewer_id'};
   my $resp = send_http_post(
               { host => $Monitor::Tools::noisemaker,
                 post_url => $post_url,
                 post_data => $post_data });
   if( $resp != 200 )
   {
      WriteLog("AM-FAIL");
   }
   elsif( $resp == 200 and not defined(decode_json($Monitor::Tools::post_response)->{'alert_count'}))
   {
      WriteLog("AM-FAIL");
   }
}

sub AutoTaskGenerate
{
   my $mail_to;
   my $subject = $notification_data->{'notification'}->[0];
   my $message = $notification_data->{'notification'}->[1];
   
   $subject =~ s/\[[A-Z]+\]//g;
   
   my @tags = ('network','issue','autotask');
   if ($notification_data->{'level'} =~ /P1|P2/)
   {
      push(@tags, 'on-call');
   }
   
   given ( $notification_data->{'level'} )
   {
      when (/P1/) { push(@tags, 'hi-pri'); }
      when (/P2/) { push(@tags, 'mid-pri'); }
      when (/P3/) { push(@tags, 'mid-pri'); }
      when (/P4/) { push(@tags, 'low-pri'); }
   }
   
   $mail_to = "tasks+" . join('&',@tags);
   
   if ($notification_data->{'autotask'} eq 'ONCALL')
   {
      $mail_to .= "&=assign_oncall";

   }
   else
   {
      $mail_to .= "&=assign_upforgrabs";
   }
   $mail_to .= "\@somecompany.internal";
   
   `echo "$message" | /bin/mail -s "$subject" -r network-autotask\@somecompany.internal \'$mail_to\'`;
   
}

sub WriteLog
{
   my $action = shift;
   my $log_entry;

   $log_entry .= "$action:" . $notification_data->{'host'}; #Date:ACTION
   $log_entry .= ";" . $notification_data->{'service'} if $notification_data->{'service'} ne ''; #HOST-SERVICE
   $log_entry .= ":" . $notification_data->{'type'}; # Type (ACK,DOWNTIME,FLAP)
   $log_entry .= ":" . $notification_data->{'state'}; # State (Up,Down,Critical)
   $log_entry .= "\n" . $Monitor::Tools::post_response if $action eq "AM-FAIL";
   syslog('info',$log_entry);
   $log->write($log_entry);
}

sub ParseOptions
{
   
   my %plevel_reduce = ( 'P1' => 'P2', 'P2' => 'P3', 'P3' => 'P4', 'P4' => 'P4');
   GetOptions( \%ProgramOptions,
      "entity:s",
      "key:s",
      "amalert:s",
      "tags:s",
      "test"
   );
 
   $ProgramOptions{'type'} = $ENV{'NOTIFICATIONTYPE'};
   $ProgramOptions{'date'} = $ENV{'LONGDATETIME'};
   $ProgramOptions{'email'} = $ENV{'USEREMAIL'};
   $ProgramOptions{'author'} = (split(/:/, $ENV{'NOTIFICATIONAUTHORNAME'}))[0];
   $ProgramOptions{'comment'} = $ENV{'NOTIFICATIONCOMMENT'};
   $ProgramOptions{'checkoutput'} = $ENV{'CHECKOUTPUT'};
   $ProgramOptions{'level'} = $ENV{'LEVEL'};
   $ProgramOptions{'links'} = $ENV{'LINKS'};
   
   
   $ProgramOptions{'host'} = $ENV{'HOSTALIAS'};
   $ProgramOptions{'hoststate'} = $ENV{'HOSTSTATE'};
   $ProgramOptions{'address'} = $ENV{'HOSTADDRESS'};
   $ProgramOptions{'hoststate'} = $ENV{'HOSTSTATE'};
   
   $ProgramOptions{'displayname'} = $ENV{'SERVICEDISPLAYNAME'};
   $ProgramOptions{'service'} = $ENV{'SERVICEDESC'};
   $ProgramOptions{'servicestate'} = $ENV{'SERVICESTATE'};
   $ProgramOptions{'endpoint'} = $ENV{'ENDPOINT'};
   
   if ($ProgramOptions{'service'} eq '')
   {
      $ProgramOptions{'state'} = $ProgramOptions{'hoststate'};
   }
   else
   {
      $ProgramOptions{'state'} = $ProgramOptions{'servicestate'};
   }

   if( $ProgramOptions{'state'} eq 'WARNING' )
   {
      $ProgramOptions{'level'} = $plevel_reduce{$ProgramOptions{'level'}};
   }
   elsif( $ProgramOptions{'state'} eq 'UNKNOWN' )
   {
      $ProgramOptions{'level'} = 'P4';
   }
}
