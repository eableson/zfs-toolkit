#!/bin/bash -p
# auto-snap-cleanup.ksh v0.92
#
# ZFS snapshot cleanup script - a companion to the auto-replicate script
#
# A simple structure to automate the cleanup of replicated snapshots taking into account the
# dependency and locked flags of a filesystem being replicated.
#
# No attention to the names of the snaps is done so they can be from TimeSlider, your own
# custom snapshot naming system or manual snapshots.  The idea is a very simple "keep the last
# $x snapshots of all top level filesystems or of this filesystem (except rpool)
#
# Note: for the Open Indiana configuration, you'll need to be running the script
# as root or have delegated ZFS responsibilities to the account running the scripts

#
# Prerequisites :
#	Top level filesystems only - no idea what this will do if you feed it nested filesystems
#	Does not treat root 
#
# TO DO
#
# Add in a space management option x% of the pool should be free and go destroying snapshots
# in a round robin manner on all filesystems
#
# CHANGE LOG
#  25 jan 2010 : AG : Initial version
#
#  4 feb 2010  : AG : Corrected greater than comparison for number of snaps to be deleted
#
#  29 sep 2010 : AG : Corrected a bare zfs command with the $LZFS
#						
#  5 aug 2012  : EA : Added fixed paths for Nexenta.
#
#  6 aug 2012  : EA : Included fixed path commands with check for Open Indiana
#
#  6 jan 2015  : EA : updated to standard path code for the set

###############################################################################
# Grab commandline argument variables
snapstokeep=$1	# how many snapshots should be kept
fs=$2			# optional argument - filesystem to cleanup, without this
				#	option, all localfilesystems will be cleaned
percentfree=$3	# currently unused optional argument for trimming a pool to a given
				#	amount of usage. Worst case will clear out all snapshots
				#	other than those marked as dependencies
				

# Usage information and verification
usage() {
cat <<EOT
usage: auto-snap-cleanup.ksh [number of snaps to keep] [optional - filesystem to clean, otherwise all pools will be cleaned except rpool] [optional: percentage free on the pool, recursive cleanup until arrived at or only locked or dependent snapshots exist]
        eg. auto-snap-cleanup.ksh 7 tank 80
EOT
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi


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
# Get filesystem list

if [[ $fs = "" ]]; then
	print "No filesystem specified, checking all"
	fslist=`$LZFS list -Hr -o name | grep -v rpool | grep /`
	echo "Found: $fslist"
else
	print "Checking $fs"
	localfsnamecheck=`$LZFS list -o name | grep ^$fs\$`
	if [[ $localfsnamecheck = $fs ]];then
		echo "Source filesystem $fs exists"
		fslist=$fs
	else
		echo "Source filesystem $fs does not exist"
		exit 1
	fi
fi


for thisfs in $fslist;do

	###############################################################################
	# Check source pool state
	
	islocked=`$LZFS get -Hr -o value replication:locked $thisfs | $TAIL -1`
	until [[ $islocked = "false" ]];do
		echo "Filesystem $thisfs is currently locked for replication - check status of current replication jobs and clear lock if necessary (zfs set replication:locked=false $thisfs)"
		exit 1
#		sleep $PAUSE
#		islocked=`$LZFS get -Hr -o value replication:locked $thisfs | $TAIL -1`
	done
	
	currentsnapcount=`$LZFS list -Hr -o name -s creation -t snapshot $thisfs | $WC -l`
	extrasnaps=$(($currentsnapcount-$snapstokeep))
	
	echo "Number of extra snapshots to be deleted: $extrasnaps"


	###############################################################################
	# Isolate the extra snaphots to be deleted, check for the dependency flag
	if [[ $extrasnaps -gt 0 ]];then
		snapstodelete=`$LZFS list -Hr -o name -s creation -t snapshot $thisfs | grep -v ^rpool | tac | tail -$extrasnaps | tac`
		# the loop is to reverse the sort order so that the oldest are isolated by tail, and then reversed again so
		# that deletion goes oldest to newest
		
		for thissnap in $snapstodelete;do
		   #if [[ `$LZFS get -Hr -o value replication:depend $thissnap` = "true" ]];then
			#  print "$thissnap should not be deleted" 
		   #else
			  print "$thissnap will be deleted"
			  $LZFS destroy $thissnap
		   #fi
		done
	else
		echo "No snaps to delete"
	fi
done



###############################################################################
# Check for filesystem full status

###############################################################################
# Get all non dependent snapshots

###############################################################################
# Delete - check for space, exit if under percentfree, keep going otherwise



