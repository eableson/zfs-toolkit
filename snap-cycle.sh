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
# on physically separate storage systems.
#
# The snaps retention policy can be different by site, so that an external copy can be
# used for something closer to an archive with a longer retention period that the primary
# storage system

###############################################################################
# Usage 
# The script is designed to be called once per day in a cron job so the snapshot
# naming convention is by date with the "sc-daily", "sc-weekly" or "sc-monthly" suffix to 
# aid in identifying the source visually and for identifying newly transferred snapshots 
# on a backup system where we will need to pose the holds in accordance with the local
# policy
# 
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

# Sample scenario
# Primary storage bay has snap-cycle running once per day via a cron job
# A separate job handles hourly snapshots. Hourly snapshots are used to provide local 
# granularity for recovering files, but also so that when transferring data to the 
# secondary disaster recovery system over a relatively small link, an interruption will
# not force the restart of the transmission from the previous day, but only an hourly
# increment.
# On the primary system the following policy is applied:
# d10 w1 m1
#
# This ensures that weekly and monthly snapshots are taken on the primary system. On the 
# secondary system the copy flag is used so that it will not create any snapshots, but 
# simply pose the holds on the replicated snapshots:
# d30 w8 m12
# 
# so that using slower larger disks, we can retain 30 days of daily snapshots, 8 weeks
# and a year's worth of monthly snapshots.
#
# Since the source system is sending hourly snapshots, we need to get rid of these, so I
# would use the auto-snap-cleanup script with a maximum set to more than the number of
# anticipated snapshots for the retention policy. Since they will have holds, they will
# never be deleted by the auto-snap-cleanup script.
#

#
# 09 jan 2015 - EA - Initial version
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
TAC=`$WHICH tac`
if [ "$TAC" == "" ]; then
	TAC="$TAIL -r"
fi

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

echo ""
echo "#################################################################"
echo "### Starting check of $sourcefs: " `date +%Y-%m-%d_%H-%M-%S` "###"



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
SNAPSHOTTYPES=( "daily" "weekly" "monthly" )

if [ $fstype = "master" ]; then
	echo "Creating snapshots on master filesystem"
	if [[ `$LZFS list -t snapshot -o name -r $sourcefs | grep $DAYSNAP | wc -l` -gt 0 ]]; then
		echo "  Daily snapshot $sourcefs@$DAYSNAP already exists. No action necessary"
	else
		echo "  Creating daily snapshot: $LZFS snapshot $sourcefs@$DAYSNAP"
		$LZFS snapshot $sourcefs@$DAYSNAP
		$LZFS hold sc-daily $sourcefs@$DAYSNAP
	fi
	# If weekday=7, set weekly hold
	if [ `date +%u` -eq 7 ]; then
		# It's sunday, so take a snapshot
		if [[ `$LZFS list -t snapshot -o name -r $sourcefs | grep $WEEKSNAP | wc -l` -gt 0 ]]; then
			echo "  Weekly snapshot $sourcefs@$WEEKSNAP already exists. No action necessary"
		else
			echo "  Creating weekly snapshot:$LZFS snapshot $sourcefs@$WEEKSNAP"
			$LZFS snapshot $sourcefs@$WEEKSNAP
			$LZFS hold sc-weekly $sourcefs@$WEEKSNAP	
		fi
	fi
	# If monthday=1, set monthly hold
	if [ `date +%d` -eq 1 ]; then
		if [[ `$LZFS list -t snapshot -o name -r $sourcefs | grep $MONTHSNAP | wc -l` -gt 0 ]]; then
			echo "  Weekly snapshot $sourcefs@$MONTHSNAP already exists. No action necessary"
		else
			echo "  Creating monthly snapshot:$LZFS snapshot $sourcefs@$MONTHSNAP"
			$LZFS snapshot $sourcefs@$MONTHSNAP
			$LZFS hold sc-monthly $sourcefs@$MONTHSNAP
		fi
	fi
fi

######### Copy filesystem creates the holds only ############
if [ $fstype = "copy" ]; then
	echo "Controlling snapshots on a copy"
	# First, add holds to newly received snapshots
	for thissnaptype in ${SNAPSHOTTYPES[@]}; do
		echo "Checking for new $thissnaptype snapshots to retain"
		SNAPSTOCHECK=`$LZFS list -t snapshot -o name -r $sourcefs | $GREP sc-$thissnaptype\$`
		# echo "$LZFS list -t snapshot -o name -r $sourcefs | $GREP sc-$thissnaptype\$"
		for THISSNAP in	$SNAPSTOCHECK;do
			scregex=sc-$thissnaptype
			#echo $scregex
			holdlist=`$LZFS holds $THISSNAP`
			# echo $holdlist
			#echo ""
			if [[ $holdlist =~ $scregex ]]; then
				echo "  snap $THISSNAP already has hold"
			else
				$LZFS hold sc-$thissnaptype $THISSNAP
				echo "  applying hold to $THISSNAP"
			fi
		done
	done
fi

# now in both cases we will clear the extra holds and delete the associated snapshots

for thissnaptype in ${SNAPSHOTTYPES[@]}; do
	echo "Purging expired $thissnaptype snapshots."
	declare -i currentsnapcount
	snapstocount=$thissnaptype"count"
	snapstokeep=${!snapstocount}
	# echo $snapstokeep
	scregex=sc-$thissnaptype
	currentsnapcount=`$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | grep $scregex | $WC -l`
	# echo "$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | grep $scregex | $WC -l"
	extrasnaps=$(($currentsnapcount-$snapstokeep))
	if [ $extrasnaps -lt 0 ]; then
		extrasnaps=0;
	fi
	echo "  Found $currentsnapcount snapshots.  $extrasnaps $thissnaptype snapshot(s) over the retention policy of $snapstokeep."
	if [ $extrasnaps -gt 0 ];then
		snapstodelete=`$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | grep $scregex | $TAC | $TAIL -$extrasnaps | $TAC`
		#echo "$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | grep $scregex | $TAC | $TAIL -$extrasnaps | $TAC"
		#echo $snapstodelete
		# the loop is to reverse the sort order so that the oldest are isolated by tail, and then reversed again so
		# that deletion goes oldest to newest
	
		for thissnap in $snapstodelete;do
			  echo "  $thissnap will be deleted"
			  $LZFS release $scregex $thissnap
			  $LZFS destroy $thissnap
		   #fi
		done
	else
		echo "  No snaps to delete"
	fi
done
echo "### Finished checking $sourcefs: " `date +%Y-%m-%d_%H-%M-%S` "###"
echo "#################################################################"
echo ""

exit


