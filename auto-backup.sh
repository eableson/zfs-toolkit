#!/usr/bin/bash
# auto-backup.sh v0.2
#
# ZFS replication script optimized for local backups
#
# erik@infrageeks.com
# http://infrageeks.com/
#
# The rationale behind this script is to automate backups to some kind of external support
# and include the possibility of intelligently handling multiple rotating destinations.
# Thinking of a scenario where you don't have the bandwidth or ability to maintain a 
# second server online at another site for direct machine to machine replication.
#
# More specifically I'm thinking about the home user with two (or more) external disk
# boxes that are rotated between home and elsewhere. You have one disk plugged into
# your main ZFS server, and the other one at some other location offsite.
#
# On a (semi) regular basis the disks are swapped around.
#
# The script also needs to be forgiving from the point of view that there may be periods 
# where there are no destination disks/pools available and that the rotation schedule is
# subject to the irregularity of any process dependent on unreliable humans. Or there
# may be instances where multiple destination pools are available.
#
# Note: this could also be used to externalize a ZFS file system to an iSCSI or FC
# mounted volume as well. The script will do an import followed by an export so
# the zpool won't be online at all times, and won't be necessarily included in the 
# pools that are automatically mounted on startup.
#
# The script takes the following parameters :
# - source filesystem in pool/filesystem notation
# - any number of destination filesystems
#
# Example:
# auto-backup_0.2.sh data/test backup1 backup2
#
# Error return codes:
# 1 Missing arguments
# 2 Lockfile exists
# 3 Source filesystem does not exist
# 
# Sections borrowed from/inspired by:
# http://blogs.sun.com/constantin/entry/zfs_replicator_script_new_edition
# http://www.brentrjones.com
#
# Prerequisites :
#	ZFS implementation should support the hold feature (>v18)
#
# Additional Notes
# This script is being developed on Solaris 11 Express with a user
# account that has been given the profile for ZFS File Administration
# (in /etc/user_attr). Any feedback for compatibility with other systems
# appreciated.
#
# This is only designed to run against root level filesystems.

###############################################################################
# CHANGE LOG
#  9 sep 2011 : EWA : First version
#  3 aug 2012 : EWA : Added a check for the OS type to support Nexenta in order
#						to set the full pathnames for binaries

###############################################################################
# In progress
# - still waiting on the ability of ZFS to send into an encrypted filesystem

###############################################################################
# User selectable variables
snapstokeep=5 # How many snapshots should be kept on the backup filesystem
contact="root@localhost" # Contact e-mail address - don't forget to change this!

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

isindiana=`uname -a | grep oi_ -i | wc -l`
if [[ $isindiana -gt 0 ]];then
	LZFS="/usr/sbin/zfs"
	LZPOOL="/usr/sbin/zpool"
	GREP="/usr/bin/grep"
	WC="/usr/bin/wc"
	TAIL="/usr/bin/tail"
	TR="/usr/bin/tr"
	CUT="/usr/bin/cut"	
fi

###############################################################################
# Functions
###############################################################################
# Usage information and verification
usage() {
cat <<EOT
usage: auto-backup.ksh [local filesystem] [backup pool] ([backup pool] [backup pool])
        eg. auto-backup.ksh bigpool/datafiles backup1 backup2 ...
EOT
}

# Send incremental updates via send/recv
sendsnaps() {
	echo "The Source snapshot does exist on the Destination, ready to send updates!"
	
	lastsnapname=`$LZFS list -H -o name -s creation -t snapshot | grep ^$sourcefs@ | tail -1 | $CUT -d@ -f2`
	destfinalsnap="$destfs@$lastsnapname"

	echo "Command: $LZFS send -R -I $localstartsnap $locallastsnap | $LZFS recv -vF $destfs"
	$LZFS send -R -I $localstartsnap $locallastsnap | $LZFS recv -vF $destfs || \
	{
		echo "Error when zfs send/receiving.";
		echo "Failed snapshot replication" \
		"\nSource: $localstartsnap $locallastsnap" \
		"\nDestination: $destfsroot" 

		echo "Error when zfs send/receiving.";
		echo "Failed snapshot replication" \
		"\nSource: $localstartsnap $locallastsnap" \
		"\nDestination: $destfsroot" \
		| mailx -s "Failed replication between: $localstartsnap and $locallastsnap" $contact;
	}
}

# Create a new filesystem with send/recv
createfs() {
	echo "Destination filesystem $destfs does not exist - must create"
	echo "Creating remote filesystem based on: $locallastsnap"
	echo "$LZFS send -R $locallastsnap | $LZFS recv $destfs"
	$LZFS send -R $locallastsnap | $LZFS recv $destfs
	echo "Setting $destfs to read only"
	$RZFS set readonly=on $destfs
	echo "Disabling auto-snapshot on $destfs"
	$RZFS set com.sun:auto-snapshot=false $destfs
	`$LZFS hold $destpool $locallastsnap`
}

unmount() {
	echo "Unmounting $destpool"
	`$LZPOOL export $destpool`
}

cleansnaps() {
	currentsnapcount=`$LZFS list -H -o name -s creation -t snapshot | grep ^$destfs@ | $WC -l`
	extrasnaps=$(($currentsnapcount-$snapstokeep))
	
	echo "Number of extra snapshots to be deleted: $extrasnaps"

	###############################################################################
	# Isolate the extra snapshots to be deleted
	if [[ $extrasnaps -gt 0 ]];then
		snapstodelete=`$LZFS list -H -o name -s creation -t snapshot | grep ^$destfs@ | tac | tail -$extrasnaps | tac`
		# the loop is to reverse the sort order so that the oldest are isolated by tail,
		# and then reversed again so that deletion goes oldest to newest
		
		for thissnap in $snapstodelete;do
			  print "$thissnap will be deleted"
			  $LZFS destroy -r $thissnap # -r to handle subordinate filesystems
		done
	else
		echo "No snaps to delete"
	fi
}


###############################################################################
# Verify at least two command line arguments passed in
if [ $# -lt 2 ]; then
  usage
  exit 1
fi

###############################################################################
# Grab command line argument variables and create lockfile. The lockfile is there
# for instances like an initial backup that will take a long time and we don't want
# the same command launched twice on the same data sets. It's specific to the entire
# command do you can manually run multiple in parallel as long as the parameters
# are different.
sourcefs=${BASH_ARGV[$BASH_ARGC-1]}		# source filesystem including root 'mypool/myfiles'
echo "Source filesystem: $sourcefs"
lockfile=$sourcefs

destcount=$((BASH_ARGC-1))
i=0
while [ $i -lt $destcount ]; do
	destpools=( ${destpools[@]-} ${BASH_ARGV[$i]} )
	lockfile=${lockfile}"_"${BASH_ARGV[$i]}
	let i+=1
done
if [[ $TMPDIR = "" ]];then
	TMPDIR="/var/tmp/"
fi

lockfile=$TMPDIR`echo $lockfile | sed 's/\//\-/g'`".lck"

if [[ -e $lockfile ]];then
	echo "Lockfile: $lockfile exists - exiting"
	exit 2
else
	touch $lockfile
fi


###############################################################################
# Main processing
###############################################################################

###############################################################################
# Check for the existence of the source filesystem
echo "Checking for $sourcefs"
localfsnamecheck=`$LZFS list -o name | $GREP ^$sourcefs\$`
if [[ $localfsnamecheck = $sourcefs ]];then
	echo "Source filesystem $sourcefs exists"

	for destpool in "${destpools[@]}"
	do :
		echo
		echo "Checking for backup destination pool $destpool"
		
		#######################################################################
		# Create a destination filesystem variable derived from source filesystem
		# and the destination pool
		destfs=$destpool/`echo $sourcefs | $CUT -d/ -f2,3-`

		#######################################################################
		# Check if pool is mounted
		destpoolstatus=`$LZPOOL list -H -o name | $GREP \^$destpool\$`
		if [[ $destpoolstatus = "" ]];then
			echo "Pool $destpool is not mounted, attempting import"
			`$LZPOOL import $destpool`
			destpoolstatus=`$LZPOOL list -H -o name | $GREP \^$destpool\$`
			if [[ $destpoolstatus = "" ]];then
				destpoolmounted=false
			else
				destpoolmounted=true
			fi
		else
			destpoolmounted=true
		fi
		
		if [[ $destpoolmounted = "true" ]];then
			echo "Pool $destpool is available, starting backup operations"
			
			# Get most recent local snapshot - used either as the baseline for a new transfer
			# or as the last item of an incremental transfer.
			locallastsnap=`$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | grep ^$sourcefs@ | tail -1`	
			
			if [[ $locallastsnap = "" ]]; then
				echo "No local snapshot to use as replication baseline - exiting"
				echo "Unmounting $destpool"
				`$LZPOOL export $destpool`
				continue
			else
	
				#######################################################################
				# Check if destination filesystem exists
				echo "Checking for $destfs"
				destfsnamecheck=`$LZFS list -o name | grep ^$destfs\$`
				if [[ $destfsnamecheck = $destfs ]];then
					echo "Destination filesystem $destfs exists"

			
					#######################################################################
					# Match baseline snapshots
					# Get the most recent snapshot from the remote filesystem.
					destlastsnap=`$LZFS list -H -o name -s creation -t snapshot | grep $destfs@ | tail -1 | $CUT -d/ -f2,3-`
					echo "Most recent destination snapshot: $destlastsnap"
					
					# Match the last remote snapshot with the local one.
					localstartsnap=`$LZFS list -r -o name -s creation -t snapshot $sourcefs | grep $destlastsnap\$`
					echo "Matching source snapshot: $localstartsnap"
					
					destlastsnap="$destfsroot/$destlastsnap"
			
					# If the most recent destination snapshot doesn't match an existing
					# local snapshot, destroy the destination filesystem and start over.
					
					if [ -z "$localstartsnap" ]; then
						#######################################################################
						# If there are no source snapshots that match, destroy the backup
						# filesystem and recreate.
						echo "The Source snapshot doesn't exist on the Destination, recreating fresh backup filesystem"							 
						`$LZFS destroy -r $destfs`
						createfs
					else
						if [[ $localstartsnap = $locallastsnap ]];then
							echo "No new snapshots to send - exiting"
						else
							sendsnaps
							echo "Releasing hold on $localstartsnap"
							`$LZFS release $destpool $localstartsnap`
							echo "Setting hold on $locallastsnap"
							`$LZFS hold $destpool $locallastsnap`
							cleansnaps
						fi
					fi			
					unmount
				else
					createfs
					unmount
				fi
			fi
			
		else
			echo "Pool $destpool is not available, skipping"
			continue
		fi
	done
	
	###############################################################################
	# Maintenance tasks: checking for orphan and very old holds
	for destpool in "${destpools[@]}"
	do :
		snaplist=`zfs list -t snapshot -o name | grep $sourcefs`
		
		holdlist=""
		for snapshot in ${snaplist[@]}
		do : 
			hold=`zfs holds $snapshot`
			holdlist="${holdlist}\n$hold"
		done
		
		holdcount=`echo -e $holdlist | grep $destpool | $WC -l`
		
		if [[ $holdcount -gt 1 ]];then
			echo "Alert: possible orphan hold on a snapshot. There are more than one holds associated with $destpool"
			echo -e $holdlist | grep $destpool
			
			echo -e "Alert: possible orphan hold on a snapshot. There are more than one holds associated with $destpool"\
					$holdlist | grep $destpool\
					 | mailx -s "Possible orphan hold on $sourcefs" $contact;
			
		fi
	done
else
	echo "Source filesystem $sourcefs does not exist - check for typos"
	rm $lockfile
	exit 3;
fi

rm $lockfile