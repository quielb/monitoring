# monitoring
 
This is code I wrote at a previous employer for a monitoring system based on [Icinga](www.icinga.org).

## Contents
..* Perl scripts to monitor devices.
..* Multi-threaded Perl script to sync from SOT, collect data about what to monitor, and generate valid [Icinga](www.icinga.org) config.
..* Bash script that wraps sync from SOT, captures errors, and notify.
..* Bash script to backup config.  It doesn't really serve much purpose.  All config is either stored in source control or dynmically generated.