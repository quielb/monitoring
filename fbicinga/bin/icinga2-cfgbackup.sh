#!/bin/bash

DATETIME=`/bin/date +%m%d%Y-%H%M`
DESTBASE=/root/icinga2-backup/
DEST=$DESTBASE/$DATETIME
SRC="/usr/local/icinga/bin /usr/local/bin/icinga* /etc/icinga2/conf.d/internal"

[ -d $DEST ] || /bin/mkdir -p $DEST

for dir in $SRC; do
   /bin/cp -r $dir $DEST
done


cd $DEST/..
/bin/tar cfz $DATETIME.tar.gz $DATETIME
/bin/rm -rf $DEST

/bin/find $DESTBASE -mtime +30 -type f -name "*tar.gz" -delete
