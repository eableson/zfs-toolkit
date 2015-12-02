#!/bin/bash -p
#
# ZFS snapshot script
#
# erik@infrageeks.com
# http://blog.infrageeks.com/
#
# The most basic of snapshot scripts - all first level filesystems and volumes 
# other than the root pool are snapshotted if no filesystem is supplied as an argument.
# A filesystem can be supplied as a single argument and it and subordinate filesystems
# will be snapshotted.

# No cleanup - that's up to you to 
# handle elsewhere (snapshot-cleanup.ksh) being a good starting point.
# 
# Note: for the Open Indiana configuration, you'll need to be running the script
# as root or have delegated ZFS responsibilities to the account running the scripts
# 
# Fixed path setup is to ensure that you can run from a cron job without a having to
# setup the path variables.

# 12 dec 2010 - EA - added command line for receiving a specific filesystem to
#                                               snapshot. Takes either 'pool' or 'pool/filesystem' and
#                                               handles all subordinate filesystems
# 22 apr 2011 : EA : Added a filter for syspool for Nexenta based systems
# 5 aug 2012 : EA : Included fixed path commands with check for Nexenta
# 6 aug 2012 : EA : Included fixed path commands with check for Open Indiana
# 8 dec 2014 : EA  : Added fixed path commands with check for OS X (Darwin) for use with OpenZFS
# 6 jan 2015 : EA : Updated to a standard method for handling path selection when $PATH
#						is missing or incomplete
#					Switched to bash
# 2 dec 2015 : EA : fixed a problem where searches for filessytems were open-ended and would
#					find multiple filesystems that started with the same name
#					ie pool/data01 and pool/data01local would both be snapshotted if the
#					first one was selected

###############################################################################
# Fixed path commands for cron launched jobs without $PATH

WHICH="/usr/bin/which"
UNAME=`$WHICH uname`
if [ `$UNAME` = "SunOS" ]; then
	LZFS="pfexec "`$WHICH zfs`
	LZPOOL="pfexec "`$WHICH zpool`
else
	LZFS=`$WHICH zfs`
	LZPOOL=`$WHICH zpool`
fi
GREP=`$WHICH grep`
WC=`$WHICH wc`
TAIL=`$WHICH tail`
TR=`$WHICH tr`
CUT=`$WHICH cut`
ECHO=`$WHICH echo`

sourcefs=$1             # source filesystem

NOW=`date +%Y-%m-%d_%H-%M-%S`

if [ $sourcefs ]; then
        fslist=`$LZFS list -Hr -o name | $GREP -v rpool | $GREP -v syspool | $GREP / | $GREP ^$sourcefs$`

else
        fslist=`$LZFS list -Hr -o name | $GREP -v rpool | $GREP -v syspool | $GREP /`
fi

for thisfs in $fslist;do
	echo "Found: $thisfs"
	$LZFS snapshot $thisfs@$NOW
	echo "creating snapshot $thisfs@$NOW"
done