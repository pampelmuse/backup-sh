#!/bin/bash

# ############################################################################
# Defaults (can be overwritten by options)
# ############################################################################

# for how long (in days) should we keep daily, weekly and
# monthly backups
keep_days_daily=14
keep_days_weekly=190
keep_days_monthly=36500

# Infotext appended to the "Start" and "Finished" log entries
infotext=''

# logging. Select facility, the tag to add and how verbose
# logging should be.
# 0 == errors / 1 == notice / 2 == info / 3 == debug
log_facility='local7'
log_tag=`basename $0`
log_verbosity=0

# don't do the real backup, add '--dry-run' to the rsync call
dryrun=false

# source directory to backup
src_root=''

# destination root - backups will go to $dst_root/daily
# (and copies to $dst_root/weekly and $dst_root/monthly)
dst_root=''

# ############################################################################
# Nothing to configure beyond this point
# ############################################################################

# ----------------------------------------------------------------------------
# short usage info
help ()
{
cat <<End_Of_Help
Usage:
    $(basename $0) -h
 or $(basename $0) [options]

Options:
 -h              print this usage info and exit with exit code 1
 -l <facility>   log facility to use (default: [$log_facility])
 -v              increase verbosity (up to 3x)
 -s <directory>  source directory
 -d <directory>  destination directory (backup root, see below)
 -D <# days>     number of days to keep the daily backups (default: [$keep_days_daily])
 -W <# days>     number of DAYS to keep the weekly backups (default: [$keep_days_weekly])
 -M <# days>     number of DAYS to keep the monthly backups (default: [$keep_days_monthly])
 -i <text>       infotext added to the "Start" and "Stop" log entries (default: none)
 -z              do a dry-run (adds '--dry-run' to the rsync call and sets -vvv)

 -s and -d are mandatory, all other options have some defaults set.

Exit codes:
   0 - no errors

   1 - called with -h, help printed
   2 - called with illigal/unknown option(s)
   3 - source directory does not exist, is not a dir or not readable to me
   4 - backup root does not exist, is not a dir or not writable to me
   5 - daily, weekly or monthly backup subdir doesn't exist, and we can't create it
   6 - daily, weekly or monthly backup subdir does exist, but is not writable
   7 - unable to create the directory for this backup
   8 - rsync not found
   9 - error removing the outdated "latest" link
  10 - error creating the "latest" link

  >100 are rsync errors. Substract 100 to get the rsync returncode.

How does it work:
 $(basename $0) will create subdirs in the (-d) backup root
 to hold daily, weekly and monthly backups.
 
 Then it will create a subdir in "daily" for the backup it is about
 to make and does the backup. Once the backup is completed, it will
 create a "latest" symlink in "daily" pointing to the backup just
 taken.

 As the next step, $(basename $0) deletes daily backups older than
 the configured holding time for daily backups.

 For all backups being made on Mondays, $(basename $0) creates copies
 in the "weekly" subdir, and for all backups taken on the 1st of a 
 month a copy is placed in "monthly".

 And again weekly and monthly backups older than the holding time
 will be removed.

 Resulting directory structure looks like

 <Backup Root>
 |
 +--daily
 |   +--latest --> ./2015-04-02.223000
 |   +--2015-03-30.223000
 |   +--2015-03-31.223000
 |   +--2015-04-01.223000
 |   +--2015-04-02.223000
 |
 +--weekly
 |   +--2015-03-30.223000 (2015-03-30 is a Monday)
 |
 +--monthly
     +--2015-04-01.223000

 $(basename $0) uses rsync's "hard link" feature to deduplicate on
 file level (rsync --link-dest). If a file didn't change since the
 last backup, it will not copy it over again, but create a hard link
 to the already  existing backup copy. Same for the weekly and monthly
 backups.

End_Of_Help
}

# ############################################################################
# some aux functions
# ############################################################################

# ----------------------------------------------------------------------------
# removes trailing slashes
Clean_Dir_Name ()
{
    local extglob_not_set=false
    [ ! -o extglob ] && { extglob_not_set=true; shopt -s extglob; }
    echo ${1%%+(/)}
    $extglob_not_set && shopt -u extglob
}

# ----------------------------------------------------------------------------
# simple logging.
# Uses logger if available, does simple print to stderr otherwise
if bin_logger=$(which logger); then
    my_logger ()
    {
        local log_prio=$1
        shift
        $bin_logger --stderr --tag $log_tag --priority ${log_facility}.${log_prio} "$*"
    }
else
    my_logger ()
    {
        local log_prio=$1
        shift
        printf '[%s] %s - %s: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$log_tag" "$log_prio" "$*" >&2
    }
fi
log_e () {                             my_logger "err"    "$*" ; }
log_n () { [ $log_verbosity -ge 1 ] && my_logger "notice" "$*" ; }
log_i () { [ $log_verbosity -ge 2 ] && my_logger "info"   "$*" ; }
log_d () { [ $log_verbosity -ge 3 ] && my_logger "debug"  "$*" ; }

# ----------------------------------------------------------------------------
# clean out old backup dirs
Remove_Outdated_Dirs ()
{
    local search_root="$1"
    local keep_days="$2"
    log_d "Removing outdated backups in [$search_root], older then [$keep_days] days"
    for dir_to_remove in $( find $search_root -maxdepth 1 -mindepth 1 -type d -mtime "+$keep_days" ); do
        log_d " - $dir_to_remove"
        rm -rf "$dir_to_remove" || {
            rc_rm=$?
            log_e "Error removing [$dir_to_remove], rm returned rc [$rc_rm]"
        }
    done
}

# ############################################################################
# main functionality
# ############################################################################

# ----------------------------------------------------------------------------
# get our options
OPTIND=1
while getopts hvs:d:D:W:M:i:z opt; do
    case $opt in
    h)
        help
        exit 1
        ;;
    \?)
        # set by getopts in case of an unknown parameter
        help
        exit 2
        ;;
    v)
        log_verbosity=$((log_verbosity + 1))
        ;;
    s)
        src_root=$OPTARG
        ;;
    d)
        dst_root=$OPTARG
        ;;
    D)
        keep_days_daily=$OPTARG
        ;;
    W)
        keep_days_weekly=$OPTARG
        ;;
    M)
        keep_days_monthly=$OPTARG
        ;;
    i)
        infotext=$OPTARG
        ;;
    z)
        dryrun=true
        log_verbosity=$((log_verbosity + 3))
        ;;
  esac
done
shift $((OPTIND - 1))

# ----------------------------------------------------------------------------
# log parameters
if [ -z "$infotext" ]; then
    log_n "Start..."
else 
    log_n "Start $infotext..."
fi
log_d "Options for this run:"
log_d " -s (source dir):....[$src_root]"
log_d " -d (backup root):...[$dst_root]"
log_d " -D (keep daily):....[$keep_days_daily]"
log_d " -W (keep weekly):...[$keep_days_weekly]"
log_d " -M (keep monthly):..[$keep_days_monthly]"
log_d " -i (info text):.....[$infotext]"

# ----------------------------------------------------------------------------
# check for directories
src_root=$(Clean_Dir_Name "$src_root")
dst_root=$(Clean_Dir_Name "$dst_root")
if [ ! -d "$src_root" ]; then
    log_e "Source directory [$src_root] does not exist or is not a directory"
    exit 3
fi
if [ ! -r "$src_root" ]; then
    log_e "Source directory [$src_root] exists, but is not readable to me"
    exit 3
fi

if [ ! -d "$dst_root" ]; then
    log_e "Backup root [$dst_root] does not exist or is not a directory"
    exit 4
fi
if [ ! -w "$dst_root" ]; then
    log_e "Backup root [$dst_root] exists, but is not writable to me"
    exit 4
fi

dst_daily="${dst_root}/daily"
dst_weekly="${dst_root}/weekly"
dst_monthly="${dst_root}/monthly"
log_d "Daily backups dir:...[$dst_daily]"
log_d "Weekly backups dir:..[$dst_weekly]"
log_d "Monthly backups dir:.[$dst_monthly]"

if [ ! -d "$dst_daily" ]; then
    log_n "Daily backup subdir [$dst_daily] does not yet exist, creating..."
    mkdir "${dst_daily}" || {
        log_e "Unable to create the daily backup subdir [$dst_daily], mkdir rc [$?]"
        exit 5
    }
fi
if [ ! -w "$dst_daily" ]; then
    log_e "Daily backup subdir [$dst_daily] exists, but is not writable to me"
    exit 6
fi

if [ ! -d "$dst_weekly" ]; then
    log_n "Weekly backup subdir [$dst_weekly] does not yet exist, creating..."
    mkdir "${dst_weekly}" || {
        log_e "Unable to create the weekly backup subdir [$dst_weekly], mkdir rc [$?]"
        exit 5
    }
fi
if [ ! -w "$dst_weekly" ]; then
    log_e "Weekly backup subdir [$dst_weekly] exists, but is not writable to me"
    exit 6
fi

if [ ! -d "$dst_monthly" ]; then
    log_n "Monthly backup subdir [$dst_monthly] does not yet exist, creating..."
    mkdir "${dst_monthly}" || {
        log_e "Unable to create the monthly backup subdir [$dst_monthly], mkdir rc [$?]"
        exit 5
    }
fi
if [ ! -w "$dst_monthly" ]; then
    log_e "Monthly backup subdir [$dst_monthly] exists, but is not writable to me"
    exit 6
fi

dst="${dst_daily}/$(date +'%Y-%m-%d.%H%M%S')"
log_d "Backup destination:..[$dst]"
mkdir "${dst}" || {
    log_e "Unable to create the dir for this backup [$dst], mkdir rc [$?]"
    exit 7
}

dst_link=''
if [ -e "$dst_daily/latest/" ]; then
    dst_link="$dst_daily/latest/"
fi

# ----------------------------------------------------------------------------
# ok, do the backup
if ! bin_rsync=$(which rsync); then
    log_e "Unable to find rsync!"
    exit 8
fi

rsync_parms=""
rsync_parms+=('-A')   # Archive
rsync_parms+=('-a')   # with acls
rsync_parms+=('-x')   # with extended attributes
if [ ! -z $dst_link ]; then
    rsync_parms+=("--link-dest=$dst_link" )
fi
$dryrun && rsync_parms+=("--dry-run")
rsync_parms+=("$src_root/")
rsync_parms+=("$dst/")

log_d "Command is [" "$bin_rsync" ${rsync_parms[@]} "]"
"$bin_rsync" ${rsync_parms[@]} || {
    rsync_rc=$?
    log_e "Rsync reported an error, rc [$rsync_rc]!"
    exit $(( rsync_rc + 100 ))
}

# ----------------------------------------------------------------------------
# creating/updating "latest" link
link_destination="$dst_daily/latest"
if [ -e "$link_destination" ]; then
    rm "$link_destination" || {
        rm_rc=$?
        log_e "error removing the 'latest' link, rc [$rm_rc]!"
        exit 9
    }
fi
link_source=$(basename $dst)
ln_parms=""
ln_parms+=('-s')   # symlink
ln_parms+=("$link_source/")
ln_parms+=("$link_destination")
log_d "Command is [" "ln" ${ln_parms[@]} "]"
ln ${ln_parms[@]} || {
    ln_rc=$?
    log_e "ln reported an error, rc [$ln_rc]!"
    exit 10
}

# ----------------------------------------------------------------------------
# remove outdated daily backups
Remove_Outdated_Dirs "$dst_daily" "$keep_days_daily"

# ----------------------------------------------------------------------------
# copy backups to weekly dir on Mondays
weekday=`date +%u`
if [ "$weekday" -eq "1" ]; then
    log_d "Monday - creating a copy in weekly"

    wdst="${dst_weekly}/$(basename $dst)"
    log_d "Weekly backup dir:..[$wdst]"
    if mkdir "${wdst}"; then
        unset rsync_parms
        rsync_parms=""
        rsync_parms+=('-A')   # Archive
        rsync_parms+=('-a')   # with acls
        rsync_parms+=('-x')   # with extended attributes
        if [ ! -z $dst_link ]; then
            rsync_parms+=("--link-dest=$dst" )
        fi
        $dryrun && rsync_parms+=("--dry-run")
        rsync_parms+=("$dst/")
        rsync_parms+=("$wdst/")

        log_d "Command is [" "$bin_rsync" ${rsync_parms[@]} "]"
        "$bin_rsync" ${rsync_parms[@]} || {
            rsync_rc=$?
            log_e "Rsync reported an error, rc [$rsync_rc]!"
        }
    else
        log_e "Unable to create the weekly dir [$wdst], mkdir rc [$?]"
    fi
else
    log_d "Not a Monday, no weekly backups today"
fi

# ----------------------------------------------------------------------------
# remove outdated weekly backups
Remove_Outdated_Dirs "$dst_weekly" "$keep_days_weekly"

# ----------------------------------------------------------------------------
# copy backups to monthly dir each first
day_of_month=`date +%d`
if [ "$day_of_month" -eq "1" ]; then
    log_d "First day in month - creating a copy in monthly"

    mdst="${dst_monthly}/$(basename $dst)"
    log_d "Monthly backup dir:..[$mdst]"
    if mkdir "${mdst}"; then
        unset rsync_parms
        rsync_parms=""
        rsync_parms+=('-A')   # Archive
        rsync_parms+=('-a')   # with acls
        rsync_parms+=('-x')   # with extended attributes
        if [ ! -z $dst_link ]; then
            rsync_parms+=("--link-dest=$dst" )
        fi
        $dryrun && rsync_parms+=("--dry-run")
        rsync_parms+=("$dst/")
        rsync_parms+=("$mdst/")

        log_d "Command is [" "$bin_rsync" ${rsync_parms[@]} "]"
        "$bin_rsync" ${rsync_parms[@]} || {
            rsync_rc=$?
            log_e "Rsync reported an error, rc [$rsync_rc]!"
        }
    else
        log_e "Unable to create the monthly dir [$mdst], mkdir rc [$?]"
    fi
else
    log_d "Not the first of a month, no monthly backups today"
fi

# ----------------------------------------------------------------------------
# remove outdated monthly backups
Remove_Outdated_Dirs "$dst_monthly" "$keep_days_monthly"

# ----------------------------------------------------------------------------
# done
if [ -z "$infotext" ]; then
    log_n "Finished..."
else
    log_n "Finished $infotext..."
fi

