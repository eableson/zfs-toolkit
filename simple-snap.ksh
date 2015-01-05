#!/bin/ksh -p
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

###############################################################################
# Fixed path commands for cron launched jobs without $PATH
# Defaults are for Solaris 11 environments
LZFS="pfexec /sbin/zfs"
LZPOOL="pfexec /sbin/zpool"
GREP="/usr/gnu/bin/grep"
WC="/usr/gnu/bin/wc"
TAIL="/usr/gnu/bin/tail"
TR="/usr/gnu/bin/tr"
CUT="/usr/gnu/bin/cut"

isnexenta=`uname -a | grep Nexenta -i | wc -l`
if [[ $isnexenta -gt 0 ]];then
	LZFS="/usr/sbin/zfs"
	LZPOOL="/usr/sbin/zpool"
	GREP="/usr/bin/grep"
	WC="/usr/bin/wc"
	TAIL="/usr/bin/tail"
	TR="/usr/bin/tr"
	CUT="/usr/bin/cut"	
fi

isindiana=`uname -a | grep indiana -i | wc -l`
if [[ $isindiana -gt 0 ]];then
	LZFS="sudo /usr/sbin/zfs"
	LZPOOL="sudo /usr/sbin/zpool"
	GREP="/usr/gnu/bin/grep"
	WC="/usr/gnu/bin/wc"
	TAIL="/usr/gnu/bin/tail"
	TR="/usr/gnu/bin/tr"
	CUT="/usr/gnu/bin/cut"	
fi

isdarwin=`uname -a | grep darwin -i | wc -l`
if [[ $isdarwin -gt 0 ]];then
	LZFS="sudo /usr/sbin/zfs"
	LZPOOL="sudo /usr/sbin/zpool"
	GREP="/usr/bin/grep"
	WC="/usr/bin/wc"
	TAIL="/usr/bin/tail"
	TR="/usr/bin/tr"
	CUT="/usr/bin/cut"	
fi


sourcefs=$1             # source filesystem

NOW=`date +%Y-%m-%d_%H-%M-%S`

if [ $sourcefs ]; then
        fslist=`$LZFS list -Hr -o name | $GREP -v rpool | $GREP -v syspool | $GREP / | $GREP ^$sourcefs`

else
        fslist=`$LZFS list -Hr -o name | $GREP -v rpool | $GREP -v syspool | $GREP /`
fi

for thisfs in $fslist;do
	echo "Found: $thisfs"
	$LZFS snapshot $thisfs@$NOW
	echo "creating snapshot $thisfs@$NOW"
done