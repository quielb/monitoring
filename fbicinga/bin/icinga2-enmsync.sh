#!/bin/bash
PATH=$PATH:/usr/sbin
ICINGA2SYNC=/usr/local/icinga/bin/icinga2-addDevice.pl
ICINGA2LOG=/var/log/icinga2/startup.log

ADDDEVICE=`$ICINGA2SYNC 2>&1`

if [ $? -eq 0 ]; then
   icinga2 daemon -C 2>&1 > $ICINGA2LOG
   if [ $? -ne 0 ]; then
      ERRLOG=`/bin/egrep "^Config error:|critical" $ICINGA2LOG`
      ERRMSG="There is an error in the Icinga configs.  The service was not reloaded.\n\n$ERRLOG"
      SUBJECT="[CRITICAL] Icinga2 ENM SYNC"
      echo -e "$ERRMSG" | /bin/mail -s "$SUBJECT" -r alert\@somecompany.internal
   else
      STATUS=`/sbin/service icinga2 status`
      if [[ "$STATUS" =~ "not running" ]]; then
         /sbin/service/icinga2 start 2>&1 >/dev/null
      else
         #/sbin/service icinga2 reload 2>&1 > /dev/null
         /sbin/service icinga2 stop  > /dev/null 2>&1
         /sbin/service icinga2 start  > /dev/null 2>&1
      fi
   fi
fi

