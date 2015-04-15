#!/bin/bash
#===============================================================================
#
#          FILE: backup_file.sh
#
#         USAGE: ./backup_file.sh -s /path/to/source -d /path/to/backup/root
#
#   DESCRIPTION: Backup using rsync, with daily/weekly/monthly backup support
#
#       OPTIONS: backup_file.sh -h will tell
#  REQUIREMENTS: find, rm, rsync, mkdir, rm, logger (optional)
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Bernd Giegerich (bgi), Bernd.A.Giegerich@gmail.com
#       CREATED: 12.04.2015 14:34:43 CEST
#      REVISION: 1.0.0
#===============================================================================

#===============================================================================
#  DEFAULTS
#===============================================================================
# for how long (in days) should we keep daily, weekly and monthly backups
keep_days_daily=14
keep_days_weekly=190
keep_days_monthly=36500

# Day of the week to do the weekly backups (1..7; 1 is Monday)
day_weekly=1

# Day of the month to do the monthly backups
day_monthly=1

# Infotext appended to the "Start" and "Finished" log entries
infotext=''

# logging. Select facility, the tag to add and how verbose
# logging should be.
# 0 == errors / 1 == notice / 2 == info / 3 == debug
log_facility='local7'
log_tag=$(basename "$0")
log_verbosity=0

#===============================================================================
#  OTHER GLOBAL DECLARATIONS
#===============================================================================
readonly needed_externals="find rm basename rsync"
readonly VERSION='1.0.0'
shopt -s extglob

dryrun=false
src_root=''
dst_root=''

#===============================================================================
#  FUNCTION DEFINITIONS
#===============================================================================
#---  FUNCTION  ----------------------------------------------------------------
#          NAME:  help
#   DESCRIPTION:  prints a short usage info
#    PARAMETERS:  none
#       RETURNS:  nothing
#-------------------------------------------------------------------------------
help ()
{
    local script_name=$(basename "$0")
    cat <<-End_Of_Help
	Usage:
	     ${script_name} -h
	  or ${script_name} [options] -s </directory/to/backup> -d </backup/root>

	Options:
	  -h              print this usage info and exit with exit code 1

	  -s <directory>  source directory
	  -d <directory>  destination directory (backup root, see below)

	  -l <facility>   log facility to use (default: [$log_facility])
	  -v              increase verbosity (up to 3x)
	  -D <# days>     number of days to keep the daily backups (default: [$keep_days_daily])
	  -W <# days>     number of days to keep the weekly backups (default: [$keep_days_weekly])
	  -M <# days>     number of days to keep the monthly backups (default: [$keep_days_monthly])
	  -i <text>       infotext added to the "Start" and "Stop" log entries (default: none)
	  -w <week day>   day of the week (1..7; 1=Monday) to do the weekly (default: [$day_weekly])
	  -m <day>        day of the month to do the monthly (default: [$day_monthly])
	  -z              do a dry-run (automatically sets -vvv)

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
	  If they don't exist, ${script_name} creates subdirs in the (-d) backup root
	  to hold daily, weekly and monthly backups.

	  Then it creates a subdir in "daily" for the backup it is about to take,
	  and does the backup.

	  Once the backup is done, it creates/updates a "latest" symlink in "daily",
	  pointing to the backup just taken.

	  For all backups being made on the "weekly backup day", ${script_name}
	  creates copies in the "weekly" subdir, and for all backups taken
	  on the "monthly backup day" in "monthly".

      In the next step, ${script_name} deletes backups (daily, weekly and monthly)
	  older than the configured holding time for the different backup types.

	Resulting directory structure

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

	  ${script_name} uses rsync's "hard link" feature to deduplicate on
	  file level (rsync --link-dest). If a file didn't change since the
	  last backup, it will not copy it over again, but create a hard link
	  to the already existing backup copy. Same for the weekly and monthly
	  backups.
End_Of_Help
}

#---  FUNCTION  ----------------------------------------------------------------
#          NAME:  purge_outdated_backups
#   DESCRIPTION:  Deletes direct subdirs older than the given number of days
#    PARAMETERS:  $1 - string, directory to search for sub dirs in
#                 $2 - int, min age (in days) of directories to delete
#                 $dryrun - bool, will not delete anything if dryrun == <true>
#       RETURNS:  nothing
#-------------------------------------------------------------------------------
purge_outdated_backups ()
{
    local search_root="$1"
    local keep_days="$2"
    log_d "Removing outdated backups in [${search_root}] older than [${keep_days}] days"
    for dir_to_remove in $( find "${search_root}" -maxdepth 1 -mindepth 1 -type d -mtime "+${keep_days}" ); do
        log_d " - ${dir_to_remove}"
        if ${dryrun}; then
            log_d "   (dry-run, will not remove)"
        else
            if ! bgi_safe_remove_dir "${dir_to_remove}"; then
                log_e "Error removing [${dir_to_remove}], rm returned rc [$?]"
            fi
        fi
    done
}

#---  FUNCTION  ----------------------------------------------------------------
#          NAME:  copy_by_rsync_link
#   DESCRIPTION:  Uses rsync to copy a directory, can make use of rsync's
#                 --link-dest de-duplication functionality
#    PARAMETERS:  $1 - string, source dir
#                 $2 - string, destination dir (MUST NOT exist yet)
#                 $3 - string, optional, link destination dir
#                 $dryrun - bool, will not copy anything if dryrun == <true>
#       RETURNS:  0 - success
#                 1 - error creating destintaion dir
#              101+ - rsync error (rsync rc + 100)
#-------------------------------------------------------------------------------
function copy_by_rsync_link ()
{
    local src_dir=$(clean_dirname "$1")
    local dst_dir=$(clean_dirname "$2")
    local lnk_dir=$(clean_dirname "$3")
    local args
    local program='rsync'

    if ${dryrun}; then
        log_d "   (dry-run, will not create destination)"
    else
        mkdir -- "${dst_dir}" || {
            log_e "Unable to create the destination dir [${dst_dir}], mkdir rc [$?]"
            return 1
        }
        args+=('-A')   # Archive
        args+=('-a')   # with acls
        args+=('-x')   # with extended attributes
        [[ -n ${lnk_dir} ]] && args+=("--link-dest=$lnk_dir" )
        args+=("$src_dir/")
        args+=("$dst_dir/")

        log_d "Command is [${program} ${args[@]}]"

        if "${program}" "${args[@]}"; then
            log_d "Backup successfully created"
        else
            rsync_rc=$?
            log_e "Rsync reported an error, rc [$rsync_rc]!"
            return $(( $rsync_rc + 100 ))
        fi
    fi
    return 0
}

#---  FUNCTION  ----------------------------------------------------------------
#          NAME:  create_staging_directory
#   DESCRIPTION:  Used to create the daily/weekly/monthly sub dirs
#    PARAMETERS:  $1 - directory to create
#       RETURNS:  0 - everything ok
#                 5 - Unable to create the directory
#                 6 - Directory exists, but is not writable
#-------------------------------------------------------------------------------
function create_staging_directory ()
{
    local dir_to_create=$(clean_dirname "$1");

    if [[ ! -d "${dir_to_create}" ]]; then
        log_n "Backup subdir [${dir_to_create}] does not yet exist, creating..."
        if ! mkdir -- "${dir_to_create}"; then
            log_e "Unable to create the daily backup subdir [${dir_to_create}], mkdir rc [$?]"
            return 5
        fi
    fi
    if [ ! -w "${dir_to_create}" ]; then
        log_e "Backup subdir [${dir_to_create}] exists, but is not writable to me"
        return 6
    fi
}

. 'bgi_helpers' || {
    log_e "Helper lib 'bgi_helper' not found"
    exit 1
}

missing_externals=$(bgi_check_for_externals ${needed_externals})
if [[ $? -gt 0 ]]; then
    >&2 echo "Needed externals not found: ${missing_externals}"
    exit 1
fi

#===============================================================================
#  COMMAND LINE PROCESSING
#===============================================================================
OPTIND=1
while getopts hvs:d:D:W:M:w:m:i:z opt; do
    case $opt in
    v)
        log_verbosity=$((log_verbosity + 1))
        ;;
    s)
        src_root_raw=$OPTARG
        ;;
    d)
        dst_root_raw=$OPTARG
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
    w)
        day_weekly=$OPTARG
        ;;
    m)
        day_monthly=$OPTARG
        ;;
    z)
        dryrun=true
        log_verbosity=$((log_verbosity + 3))
        ;;
    h)
        help
        exit 1
        ;;
    *)
        help
        exit 2
        ;;
  esac
done
shift $(( OPTIND - 1 ))

day_weekly_name=$(name_of_weekday "${day_weekly}")
log_d "Options for this run:"
log_d " -z (dry-run):.......[${dryrun}]"
log_d " -s (source dir):....[${src_root_raw}]"
log_d " -d (backup root):...[${dst_root_raw}]"
log_d " -w (weekly day): ...[${day_weekly}] -> [${day_weekly_name}]"
log_d " -m (monthly day):...[${day_monthly}]"
log_d " -D (keep daily):....[${keep_days_daily}]"
log_d " -W (keep weekly):...[${keep_days_weekly}]"
log_d " -M (keep monthly):..[${keep_days_monthly}]"
log_d " -i (info text):.....[${infotext}]"

#===============================================================================
#  MAIN SCRIPT
#===============================================================================
if [ -z "${infotext}" ]; then
    log_n "Start..."
else 
    log_n "Start $infotext..."
fi

# BGI CONTINUE HERE

# ----------------------------------------------------------------------------
# check for root directories
src_root=$(abs_path "$src_root_raw") || src_root=''
dst_root=$(abs_path "$dst_root_raw") || dst_root=''
if [ ! -d "$src_root" ]; then
    log_e "Source directory [$src_root_raw] does not exist or is not a directory"
    exit 3
fi
if [ ! -r "$src_root" ]; then
    log_e "Source directory [$src_root_raw] exists, but is not readable to me"
    exit 3
fi

if [ ! -d "$dst_root" ]; then
    log_e "Backup root [$dst_root_raw] does not exist or is not a directory"
    exit 4
fi
if [ ! -w "$dst_root" ]; then
    log_e "Backup root [$dst_root_raw] exists, but is not writable to me"
    exit 4
fi

# ----------------------------------------------------------------------------
# check for (and create if necessary) backup staging directories
dst_daily="${dst_root}/daily"
dst_weekly="${dst_root}/weekly"
dst_monthly="${dst_root}/monthly"
log_d "Daily backups dir:...[$dst_daily]"
log_d "Weekly backups dir:..[$dst_weekly]"
log_d "Monthly backups dir:.[$dst_monthly]"
create_staging_directory "$dst_daily"   || exit $?
create_staging_directory "$dst_weekly"  || exit $?
create_staging_directory "$dst_monthly" || exit $?

# ----------------------------------------------------------------------------
# do the backup
dst="${dst_daily}/$(date +'%Y-%m-%d.%H%M%S')"
log_d "Backup destination:..[$dst]"

dst_link=''
[ -e "$dst_daily/latest/" ] && dst_link="$dst_daily/latest/"

copy_by_rsync_link "$src_root" "$dst" "$dst_link" || {
    rc_backup=$?
    log_e "Error backing up, check the logs!"
    [ $rc_backup -ge 100 ] && exit $rc_backup
    exit 7
}

# ----------------------------------------------------------------------------
# creating/updating "latest" link
link_destination="$dst_daily/latest"
log_d "Updating 'latest' link in daily"

if [ -e "$link_destination" ]; then
    log_d "Old link found, removing"
    if ! $dryrun; then
        rm "$link_destination" || {
            rm_rc=$?
            log_e "error removing the 'latest' link, rc [$rm_rc]!"
            exit 9
        }
    else
        log_d "   (dry-run, will not delete old link)"
    fi
else
    log_d "No old link found"
fi

link_source=$(basename "$dst")
unset ln_parms
ln_parms+=('-s')   # symlink
ln_parms+=("$link_source")
ln_parms+=("$link_destination")
log_d "Command is [ln ${ln_parms[@]}]"
if ! $dryrun; then
    ln "${ln_parms[@]}" || {
        ln_rc=$?
        log_e "ln reported an error, rc [$ln_rc]!"
        exit 10
    }
else
    log_d "   (dry-run, will not create new link)"
fi

# ----------------------------------------------------------------------------
# copy backups to weekly dir on the "weekly" day
if [ $(date +%u) -ne "$day_weekly" ]; then
    log_d "Not a $day_weekly_name, no weekly backups today"
else
    log_d "$day_weekly_name - creating a copy in weekly"

    wdst="${dst_weekly}/$(basename "$dst")"
    log_d "Weekly backup dir:..[$wdst]"

    copy_by_rsync_link "$dst" "$wdst" "$dst" || {
        log_e "Error creating weekly backup"
    }
fi

# ----------------------------------------------------------------------------
# copy backups to monthly dir on the "monthly" day
if [ $(date +%d) -ne "$day_monthly" ]; then
    log_d "Not the ${day_monthly}., no monthly backups today"
else
    log_d "${day_monthly}. day in month - creating a copy in monthly"

    mdst="${dst_monthly}/$(basename "$dst")"
    log_d "Monthly backup dir:..[$mdst]"

    copy_by_rsync_link "$dst" "$mdst" "$dst" || {
        log_e "Error creating monthly backup"
    }
fi

# ----------------------------------------------------------------------------
# Purge old backups
purge_outdated_backups "$dst_daily"   "$keep_days_daily"
purge_outdated_backups "$dst_weekly"  "$keep_days_weekly"
purge_outdated_backups "$dst_monthly" "$keep_days_monthly"

#===============================================================================
#  STATISTICS AND CLEAN-UP
#===============================================================================
if [ -z "$infotext" ]; then
    log_n "Finished..."
else
    log_n "Finished $infotext..."
fi

