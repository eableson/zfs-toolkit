zfs-toolkit
===============

A collection of tools for my day to day work with zfs servers:

- auto-backup.sh
- auto-replicate.ksh
- auto-snap-cleanup.ksh
- simple-snap.ksh

For more details, with pictures check out https://www.infrageeks.com/projects

## auto-backup.sh ##

Quick start

- Create a zpool (e.g. backup1) on an external device
- Ensure that you have a snapshot on your source filesystem
- Launch the script with the arguments “sourcepool/filesystem backup1”
- That’s it. Step 2 is adding a second zpool (backup2) on another external device.

Launch the script with the arguments “sourcepool/filesystem backup1 backup2” It will backup to whichever of the two backup destinations are available.

The objective: simple rotating backup solution

I’m going back to the basics here with a rotating offsite backup approach. The idea is simple. I have two big external disks that I want to rotate between home and the office. But I need a solution that’s as simple and robust as possible and that minimizes the dependency on the weakest point of the backup chain: me.

Similar to the auto-replicate script, the idea is that you should be able to pop this into a cron job and pretty much forget about it. You plug and unplug in your disks whenever seems appropriate to your needs (just checking that there’s no blinking lights on them when you do so).

Fixed schedules and rotation plans are pretty on paper, but break down in the face of the real world. So the script is designed to handle whatever it finds automatically and gracefully.

The syntax is simple: the source filesystem followed by as many destinations as you like. This is not designed for online replication like the auto-replicate script but you can use it with FC or iSCSI mounted remote disks. It works with the assumption that the destinations will be locally connected disks. In order to enhance the overall reliability and stability of the backups, it mounts and unmounts them for each session. This means that if you’re using an external USB disk you’re pretty safe unplugging it even if you forget to check if the pool is mounted or you’re in a hurry rushing out the door.

The script will happily backup to multiple destinations if they are all available. One after the other though, not in parallel. If no destinations are available, it will simply note the fact and exit.

In order to handle the fact that your off-site copy may stay off-site longer than your normal snapshot retention period, a zfs hold is placed on the last snapshot copied to your backup destination. This saves you from the situation where you miss the weekly disk swap because of a holiday and the dependent snapshot is deleted from the source. The hold will prevent the snapshot from being deleted automatically and requires that you release it or force the deletion manually. See ZFS Holds in the ZFS Administrators Guide for more information.

But even if this should happen, the script will automatically reset the backup and recopy everything automatically if it should find itself in a situation where there are no matching snapshots. There is also a bit of maintenance code in there to alert you by mail if you end up with an orphan hold on a snapshot that blocks the deletion of the snapshot.

## auto-replicate.ksh ##

The idea was to have a simple one liner that would replicate a source filesystem to a remote filesystem with a minimum of options to deal with. It does not create any snapshots itself - you have to take them yourself - Time Slider or some other snapshot scheduling method that works for you.

The idea is that you should be able to pop the script into a cron job and leave it alone. It will create the destination filesystem if required and then keep it up to date.

The other thing this script doesn’t do is delete any snapshots. It’s up to you to define your own cleanup policy on the remote copy.

The other thing I did test out to verify is that you can use a temporary copy to move big data sets from one datacenter to another so that you’re not sending terabytes across the WAN. Using the same script to send data from the master to a laptop or a portable ZFS NAS, you can then integrate it on a remote server and it will properly establish the links between the snapshots.

Comments welcome, feel free to use and modify it for your own environment, although I tried to make it as generically useful as possible. I’m more of a Perl hand than shell scripter so any recommendations for more elegant methods are definitely welcome and any other improvements that seem useful.

## auto-snap-cleanup.ksh ##

A simple structure to automate the cleanup of replicated snapshots taking into account the dependency and locked flags of a filesystem being replicated.

No attention to the names of the snaps is done so they can be from TimeSlider, your own custom snapshot naming system or manual snapshots.  The idea is a very simple "keep the last $x snapshots of all top level filesystems or of this filesystem (except rpool)

Note: for the Open Indiana configuration, you'll need to be running the script as root or have delegated ZFS responsibilities to the account running the scripts


## simple-snap.ksh ##

Takes none or one argument.

	simple-snap.ksh 

results in creating snapshots on all available zfs filesystems other than boot zfs filesystems (rpool & syspool)

	simple-snap.ksh <pool>/<filesystem>

will snaphot the filesystem (and children)

### Snapshot Naming ###

Snapshots are named with the date in the following format:
"+%Y-%m-%d_%H-%M-%S"" which translates to "2013-04-08_07-11-19"

