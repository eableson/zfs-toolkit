#!/bin/bash -p
# reset-replicate-locks.sh v0.1
#
# ZFS script for releasing locks after a dropped connection during a replication session
#
# erik@infrageeks.com
# http://infrageeks.com/
#
# In some cases, when using the auto-replicate script over unreliable lines, the
# send/recv session will be interrupted and leave the lock properties in place


###############################################################################
# CHANGE LOG
#  10 dec 2012 : EA : First version



###############################################################################
# Grab commandline argument variables
sourcefs=$1		# source filesystem including root 'mypool/myfiles'
destfsroot=$2	# destination root filesystem - just the poolname
RHOST=$3		# remote host

# Usage information and verification
usage() {
cat <<EOT
usage: reset-replicate-locks.sh [local filesystem] [remote target pool] [remote host address]
        eg. reset-replicate-locks.sh tank remotetank 192.168.1.100
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
	if [[ $remotefsnamecheck = $destfs ]];then
		echo "Destination filesystem $destfs exists"

		echo "Unlocking $sourcefs : $LZFS set $repllocklocal=false $sourcefs"
		$LZFS set $repllocklocal=false $sourcefs
		echo "Unlocking $destfs : $RZFS set $repllockremote=false $destfs"
		$RZFS set $repllockremote=false $destfs

	else
		echo "Destination filesystem $destfs does not exist - check for typos"
		exit 1
	fi

else
	echo "Source filesystem $sourcefs does not exist - check for typos"
	exit 1
fi

exit