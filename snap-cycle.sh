#!/bin/bash -p
#
# ZFS Pseudo backup retention cycle
#
# erik@infrageeks.com
# http://blog.infrageeks.com/
#
# This script is designed to simulate the old school backup retention cycle using snapshots.
# 
# Obviously, this is *NOT* a backup all by itself, but can be exploited by using send/recv
# to another environment to work as a backup locally, assuming your production storage is
# available, and still have a second (or third, or n) copy with the same or similar history
# on a physically separate storage system.
#
# The snaps retention policy can be different by site, so that on external copy can be
# used for something closer to an archive with a longer retention period that the primary
# storage system

###############################################################################
# Usage 
# The script is designed to be called once per day in a cron job so the snapshot
# naming convention is by date 
# It takes 4 arguments in the following format and order :
# - filesystem : tank/mydata
# - (master|copy) : denotes whether this is running on the master copy and snapshots
#					should be created or a copy where the snapshots arrive via send/recv
#					and we are just applying the cleanup policy
# - d(\d) : number of daily snapshots to retain
# - w(\d) : number of weekly snapshots to retain
# - m(\d) : number of monthly snapshots to retain
# The structure of including the letter prefixes is to remove any ambiguity when
# running the script or looking at the options selected


#
# 09 dec 2015 - EA - Initial version
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

###############################################################################
# Grab commandline argument variables
sourcefs=$1		# source filesystem including root 'mypool/myfiles'
fstype=$2		# (master|copy)
dailysrc=$3		# d + number of monthly snaps to keep
weeklysrc=$4	# w + number of weekly snaps to keep
monthlysrc=$5	# m + number of monthly snaps to keep



# Usage information and verification
usage() {
cat <<EOT
usage: snap-cycle [local filesystem] [(master|copy] [d(\d)] [w(\d)] [m(\d)]
        eg. snap-cycle tank/data master d7 w8 m12
EOT
}

# right number of arguments ?
if [ $# -ne 5 ]; then
  usage
  exit 1
fi

# type check for allowed values
if [ $fstype != "master" ] && [ $fstype != "copy" ]; then
	usage
	exit 1
fi

# prefixes in the right order?
if [ ${dailysrc:0:1} != "d" ] || [ ${weeklysrc:0:1} != "w" ] || [ ${monthlysrc:0:1} != "m" ]; then
	usage
	exit 1
fi


# verify suffixes correctly entered and integers are associated
d='^[0-9]+$'
if [ ${#dailysrc} -gt 1 ] && [ ${#weeklysrc} -gt 1 ] && [ ${#monthlysrc} -gt 1 ]; then
	if [[ ${dailysrc:1} =~ $d ]] && [[ ${weeklysrc:1} =~ $d ]] || [[ ${monthlysrc:1} =~ $d ]]; then
		dailycount=${dailysrc:1}
		weeklycount=${weeklysrc:1}
		monthlycount=${monthlysrc:1}
	else
		usage
		exit 1
	fi
else 
	usage
	exit 1
fi


# Check for existence of the requested filesystem
localfsnamecheck=`$LZFS list -o name | $GREP ^$sourcefs\$`
if [[ $localfsnamecheck = $sourcefs ]];then
	echo "Source filesystem $sourcefs exists"
else
	echo "Source filesystem $sourcefs does not exist. Exitting."
	exit 2
fi


######### Master filesystem creates the snapshots ############
NOW=`date +%Y-%m-%d`
DAYSNAP=`date +%Y-%m-%d`"_sc-daily"
WEEKSNAP=`date +%Y-%m-%d`"_sc-weekly"
MONTHSNAP=`date +%Y-%m-%d`"_sc-monthly"

if [ $fstype = "master" ]; then
	$LZFS snapshot $sourcefs@$DAYSNAP
	echo "  $LZFS snapshot $sourcefs@$DAYSNAP"
	$LZFS hold sc-daily $sourcefs@$DAYSNAP
	# If weekday=7, set weekly hold
	if [ `date +%u` -eq 7 ]; then
		# It's sunday, so take a snapshot
		$LZFS snapshot $sourcefs@$WEEKSNAP
		echo "  $LZFS snapshot $sourcefs@$WEEKSNAP"
	
	fi
	# If monthday=1, set monthly hold
	if [ `date +%d` -eq 1 ]; then
		$LZFS snapshot $sourcefs@$MONTHSNAP
		echo "  $LZFS snapshot $sourcefs@$MONTHSNAP"
	fi
fi




exit


