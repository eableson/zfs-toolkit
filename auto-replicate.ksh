#!/bin/bash -p
# auto-replicate.ksh v0.99
#
# ZFS snapshot replication script
#
# erik@infrageeks.com
# http://infrageeks.com/
#
# The rationale behind this script is to isolate the send/receive operations from the
# snapshot scheduling.  In many cases where we're using multiple layers of
# snapshots (VSS, VMware, etc.) we need to coordinate the application and file-system
# snapshots, or for simplicity's sake, we stick to TimeSlider and don't want to complicate
# the snapshot taking mechanisms with other activities. But the snapshot scheduling
# doesn't necessarily line up nicely with our remote replication bandwidth windows.
#
# This approach permits scheduling of transfers out of band from snapshot mechanics, ie
# hourly snapshots done via Time Slider that are transferred offsite in the evenings
# or on 8 hour cycles for example.
#
# Additionally the script can manage the three step process of using some kind of
# transportable ZFS NAS when doing the initial data loads from a main site to a disaster
# recovery site. Ideal for preloading a remote copy without having to transfer huge datasets
# across WAN links. eg local -> temp, temp -> remote, local -> remote
# 
# This can even be done from a virtual machine. Initial tests were using an OpenSolaris VM
# on a 500Gb portable drive attached to a MacBook for the 'temp' zpool.
#
# Example:
# auto-replicate tank/mydata temp osol-laptop # from the master local copy
# auto-replicate temp/mydata remote osol-backup # from the laptop temporary copy
# auto-replicate tank/mydata remote osol-backup # from the master local copy

# Sections borrowed from/inspired by:
# http://blogs.sun.com/constantin/entry/zfs_replicator_script_new_edition
# http://www.brentrjones.com
#
# Prerequisites :
#	ZFS implementation must support the incremental snapshot rollup option (-I)
#	ssh key exchange so that the password is not required to log onto the destination
#	if you want to automate the process
#
# Additional Notes
# The latest versions of the script are being developed on Solaris 11 Express with a user
# account that has been given the profile for ZFS File Administration (in /etc/user_attr).
# netcat has been added manually (pkg install netcat)
# 
# 


###############################################################################
# CHANGE LOG
#  16 oct 2009 : EA : First version
#						basic send receive of all existing snapshots, matching on 
#						source and destination
#
#  29 oct 2009 : EA : Added automatic destination creation if required
#						checks for destination, creates and locks it down and sends 
#						initial package
#
#  30 oct 2009 : EA : Verified three way transfer - local to temporary to final
#						zpools, followed by local to final incremental transfers
#					  Disabled automatic snapshots on destination filesystems
#					  Added check for new snapshots since the last transfer
#					  Fixed missing lock code
#
#  1 nov 2009 : EA : Fixed a bug with the dependency setting on the remote final
#						snapshot
#
# 22 jan 2010 : EA : Added a check to verify that the source filesystem exists
#						Previously, the errors produced are not clear at all
#
# 25 jan 2010 : EA : Added a check for the existence of a snapshot on the source
#						filesystem - without it, it would continue along without a
#						valid value for the source snapshot.
#					 Corrected the grep syntax for matching the last known destination
#						snapshot
# 2 mar 2011 : EA : Added in code to trap on localhost as the destination. In this
#						case, the remote ZFS commands are mapped to the local
#						zfs command and don't pass through ssh
#
# 22 apr 2011 : EA : Removed the option -d in the ZFS recv command. It appears that
#						this option causes problems with the reception of incremental
#						streams in the current versions of ZFS (Solaris Express 11 and
#						Nexenta 3 and possibly some BSD releases). Thanks to Lars B%kmark
#						for helping spot this one.
#
# 8 june 2011 : EA : Fixed a missing $ as identified by Jesse.
#
# 15 sept 2011 : EA : Added some refinements:
#						The replication:locked has been changed to replication:locked:remotehost
#						This should ensure that you can send multiple outbound streams
#						from the same source dataset simultaneously
#
# 25 sept 2012 : EA : Finally got around to adding in the zfs holds on the source
#						snapshots. This should ensure that the source and
#						destination mismatch should not be possible. Source snapshots that
#						were used to replicate will have a hold attached with the name of
#						the destination pool. Once a new replication transaction is complete,
#						the older hold will be removed, freeing the snapshot for deletion
#						according to whatever deletion process is in place.
#
# 11 dec 2014 : EA : Added control for darwin as an OS type to setup the command shortcuts
#						appropriate for use with ZFS on OS X 
#
#
# 5 jan 2015 : EA : Minor corrections and inclusion of OS checks from the backup script.
#						Added more explanation to the file system replication lock checking
#						to make it clearer what needs to be done.
#
# 6 jan 2015 : EA : Replaced the fixed path check code with a more sensible solution.
#						Validate correctly for different operating systems on the send and
#						receive (include pfexec for SunOS based environments)
#						force to bash as the shell

###############################################################################
# In progress/to do
# - fix attribute checks to react properly for NULL values (true|false|NULL)
# - Add a netcat option for sites not requiring ssh
# - review the other OS types for ZFS on Linux to ensure proper paths to commands


###############################################################################
# Grab commandline argument variables
sourcefs=$1		# source filesystem including root 'mypool/myfiles'
destfsroot=$2	# destination root filesystem - just the poolname
RHOST=$3		# remote host

# Usage information and verification
usage() {
cat <<EOT
usage: auto-replicate.ksh [local filesystem] [remote target pool] [remote host address]
        eg. replicate.ksh tank remotetank 192.168.1.100
EOT
}

if [ $# -lt 3 ]; then
  usage
  exit 1
fi

###############################################################################
# Contact e-mail address - don't forget to change this!
contact="root@localhost"

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

# Create a dest fs variable derived from source fs
destfs=$destfsroot/`$ECHO $sourcefs | $CUT -d/ -f2,3-`
srcpool=`$ECHO $sourcefs | $CUT -d/ -f1`
LHOST=`hostname`

# Establish a ZFS user property to store replication settings/locking
# This gives you a mechanism for checking for conflicts on actions currently 
# running. remote host has been added to the property so that you can have
# multiple concurrent replication sessions to different destinations
# The following is deprecated and replaced with zfs holds which prevent 
# snapshot deletion 
# - Also adds a "dependency" field, so you can check for this value in your
# - snapshot management/deletion scripts.

repllock="replication:locked:$RHOST"
repllocklocal="replication:sendingto:$RHOST:$destfsroot"
repllockremote="replication:receivingfrom:$LHOST:$srcpool"
replconfirmed="replication:confirmed"

# Define local and remote ZFS commands and SSH param
# you can modify the ssh parameters to choose an encryption method that's
# a little easier on the CPU if you want to.

if [[ $RHOST = "localhost" ]]; then
	RZFS=$LZFS
else
	REMOTEOS=`ssh $RHOST uname`
	if [ $REMOTEOS = "SunOS" ]; then
		RZFS="ssh -C $RHOST pfexec zfs"
	else
		RZFS="ssh -C $RHOST zfs"
	fi
fi


###############################################################################
# Check for the existence of the source filesystem
echo "Checking for $sourcefs"
localfsnamecheck=`$LZFS list -o name | $GREP ^$sourcefs\$`
if [[ $localfsnamecheck = $sourcefs ]];then
	echo "Source filesystem $sourcefs exists"

	###############################################################################
	# Check for the existence of the destination filesystem
	echo "Checking for $destfs"
	remotefsnamecheck=`$RZFS list -o name | $GREP ^$destfs\$`
	
	# Get most recent local snapshot - used either as the baseline for a new transfer
	# or as the last item of an incremental transfer.
	locallastsnap=`$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | $TAIL -1`	
	
	if [[ $locallastsnap = "" ]]; then
		echo "No local snapshot to use as replication baseline - exiting"
	else	

		if [[ $remotefsnamecheck = $destfs ]];then
			echo "Destination filesystem $destfs exists"
			
			# Check the local and remote filesystems for locks from other jobs so we don't run
			# into conflicts - especially useful when large transfers overflow the transfer window
			# or when running cleanup actions on the destination filesystem
			localfslocked=`$LZFS get -H $repllocklocal $sourcefs | cut -f3`
			remotefslocked=`$RZFS get -H $repllockremote $destfs | cut -f3`
			
			if [[ $localfslocked = "true" || $remotefslocked = "true" ]];then
				echo "Filesystem locked, quitting..."
				echo "  $sourcefs is locked: $localfslocked"
				echo "  $destfs is locked: $remotefslocked"
				echo "Check for a hung background send/recv task or:"
				echo "	Set $repllocklocal to false to unlock the sending side"
				echo "	Set $repllockremote to false to unlock the receiving side"				
				echo "\nFilesystem locked" \
				"\n$sourcefs : $repllocklocal : $localfslocked" \
				"\n$destfs : $repllockremote : $remotefslocked" \
				| mailx -s "Failed access: $sourcefs" $contact;
				exit 1;
			  else
				$LZFS set $repllocklocal=true $sourcefs
			fi
			
			# Get the most recent snapshot from the remote filesystem.
			remotelastsnap=`$RZFS list -Hr -o name -s creation -t snapshot $destfs | $TAIL -1 | $CUT -d/ -f2,3-`
			echo "Most recent destination snapshot: $remotelastsnap"
			
			# Match the last remote snapshot with the local one.
			localstartsnap=`$LZFS list -r -o name -s creation -t snapshot $sourcefs | $GREP $remotelastsnap\$`
			echo "Matching source snapshot: $localstartsnap"
			
			remotelastsnap="$destfsroot/$remotelastsnap"
				
			# If the remote most recent snapshot doesn't match an existing local snapshot, give up
			# However if it does, attempt to send an incremental snapshot
			# from the last known remote snapshot and the most current local snapshot
			
			if [ -z "$localstartsnap" ]; then
				echo "The Source snapshot doesn't exist on the Destination, manual intervention required!"\
					 "\nSource: $localstartsnap $locallastsnap"\
					 "\nDestination: $RHOST - $destfsroot" \
					 | mailx -s "Last known remote snapshot: $remotelastsnap has no matching source snapshot" $contact;
			else
				if [[ $localstartsnap = $locallastsnap ]];then
					echo "No new snapshots to send - unlocking $sourcefs and exiting"
					$LZFS set $repllocklocal=false $sourcefs
				else
					# check if $localstartsnap $locallastsnap are the same - no point in sending
					echo "The Source snapshot does exist on the Destination, ready to send updates!"
					
					
					lastsnapname=`$LZFS list -Hr -o name -s creation -t snapshot $sourcefs | $TAIL -1 | $CUT -d@ -f2`
					remotefinalsnap="$destfs@$lastsnapname"
			
					echo "Locking remote filesystem: $destfs"
					$RZFS set $repllockremote=true $destfs
					echo "Command: $LZFS send -I $localstartsnap $locallastsnap | $RZFS recv $destfs"
					$LZFS send -I $localstartsnap $locallastsnap | $RZFS recv -vF $destfs || \
					{
						echo "Error when zfs send/receiving.";
						echo "Failed snapshot replication" \
						"\nSource: $localstartsnap $locallastsnap" \
						"\nDestination: $RHOST - $destfsroot" \
						| mailx -s "Failed replication between: $localstartsnap and $locallastsnap" $contact;
						$LZFS set $repllockremote=false $sourcefs
						exit 1;
					}
					  
					# Reset all of the filesystem locks and status flags
					$LZFS set $replconfirmed=true $locallastsnap
					
					$LZFS set $repllocklocal=false $sourcefs
					#$RZFS set $replconfirmed=true $remotefinalsnap
					$RZFS set $repllockremote=false $destfs
					#echo "$RZFS set $replconfirmed=true $remotefinalsnap"
					#echo "$RZFS set $repllock=false $destfs"
					echo "Releasing hold on $localstartsnap"
					`$LZFS release $destfsroot $localstartsnap`
					echo "Setting hold on $locallastsnap"
					`$LZFS hold $destfsroot $locallastsnap`

				fi
			fi
		else
			echo "Destination filesystem $destfs does not exist - must create"
			echo "Creating remote filesystem based on: $locallastsnap"
			echo "$LZFS send $locallastsnap | $RZFS recv $destfs"
			$LZFS send $locallastsnap | $RZFS recv $destfs
			echo "Setting hold on $locallastsnap"
			`$LZFS hold $destfsroot $locallastsnap`
			echo "Setting $destfs to read only"
			$RZFS set readonly=on $destfs
			echo "Disabling auto-snapshot on $destfs"
			$RZFS set com.sun:auto-snapshot=false $destfs
			
		fi
	fi

	###############################################################################
	# Maintenance tasks: checking for orphan and very old holds
	snaplist=`$LZFS list -t snapshot -o name | $GREP $sourcefs`
	
	holdlist=""
	for snapshot in ${snaplist[@]}
	do : 
		hold=`$LZFS holds $snapshot | grep -v .send`
		holdlist="${holdlist}\n$hold"
	done
	
	holdcount=`echo -e $holdlist | $GREP $destfsroot | $WC -l`
	
	if [[ $holdcount -gt 1 ]];then
		echo "Alert: possible orphan hold on a snapshot. There are more than one holds associated with $destfsroot"
		echo -e $holdlist | $GREP $destfsroot
		
		echo -e "Alert: possible orphan hold on a snapshot. There are more than one holds associated with $destfsroot"\
				$holdlist | $GREP $destfsroot\
				 | mailx -s "Possible orphan hold on $sourcefs" $contact;
		
	fi

else
	echo "Source filesystem $sourcefs does not exist - check for typos"
	exit 1;
fi

exit