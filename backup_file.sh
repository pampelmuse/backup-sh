#!/bin/bash
#===============================================================================
#          FILE: backup_file.sh
#   DESCRIPTION: Backup using rsync, with daily/weekly/monthly backup support
#        AUTHOR: Bernd Giegerich (bgi), Bernd.A.Giegerich@gmail.com
#-------------------------------------------------------------------------------
# 2015-04-16  bgi  1.0.0  Initial version
#-------------------------------------------------------------------------------
readonly version='1.0.0'
readonly needed_externals='basename date dirname find ln rm rsync'
shopt -s extglob

#===============================================================================
#  DEFAULTS
#-------------------------------------------------------------------------------
# for how long (in days) should we keep daily, weekly and monthly backups
keep_days_daily=14
keep_days_weekly=63
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
#-------------------------------------------------------------------------------
dryrun=false
src_root=''
dst_root=''

readonly rc_ok=0
readonly rc_err_source_dir=1
readonly rc_err_destination_dir=2
readonly rc_err_staging_dir=3
readonly rc_err_create_backup_dir=4
readonly rc_err_latest_link=5
readonly rc_err_missing_dependencies=98
readonly rc_err_unknown_options=99

#===============================================================================
#  LOAD HELPER
#-------------------------------------------------------------------------------
if ! . bgi_helpers; then
    >&2 echo "Helper lib 'bgi_helper' not found"
    exit ${rc_err_missing_dependencies}
fi

#===============================================================================
#  BASE SANITY CHECKS
#-------------------------------------------------------------------------------
if [[ -z "${BASH}" ]]; then
    >&2 echo "Other shells than BASH in native mode are not supported"
    exit ${rc_err_missing_dependencies}
fi

if ! missing_externals=$(bgi_check_for_externals ${needed_externals}); then
    >&2 echo "Needed externals not found: ${missing_externals}"
    exit ${rc_err_missing_dependencies}
fi

#===============================================================================
#  FUNCTION DEFINITIONS
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Prints usage information
#
# Globals:
#   none
# Arguments:
#   none
# Returns:
#   STDOUT - usage and invocation informtion
#-------------------------------------------------------------------------------
usage()
{
    local script_name=$(basename "$0")
    cat <<-End_Of_Help
	Usage:
	     ${script_name} -h
	  or ${script_name} [options] -s </directory/to/backup> -d </backup/root>

	Options:
	  -h              print this usage info and exit with exit code 0

	  -s <directory>  source directory
	  -d <directory>  destination directory (backup root, see below)

	  -w <week day>   day of the week (1..7; 1=Monday) to do the weekly (default: [$day_weekly])
	  -m <day>        day of the month to do the monthly (default: [$day_monthly])
	  -D <# days>     number of days to keep the daily backups (default: [$keep_days_daily])
	  -W <# days>     number of days to keep the weekly backups (default: [$keep_days_weekly])
	  -M <# days>     number of days to keep the monthly backups (default: [$keep_days_monthly])
	  -t <text>       text added to the "Start" and "Stop" log entries (default: none)
	  -l <facility>   log facility to use (default: [$log_facility])
	  -v              increase verbosity (up to 3x)
	  -z              do a dry-run (automatically sets -vvv)

	  -s and -d are mandatory, all other options have some defaults set.

	Requirements:
	  Bash (not in Posix or sh compatibility mode)
	  ${needed_externals}

	Exit codes:
	   0 - no errors
	   1 - source dir does not exist, is not a dir or is not readable)
	   2 - destination dir does not exist, is not a dir or is not writable)
	   3 - daily, weekly or monthly staging dirs are not writable, 
	       or they don't exist and we can't create them
	   4 - unable to create the directory for this backup
	       (or the weekly/monthly copy)
	   5 - error creating/updating the "latest" link
	  98 - needed external programs missing or not running in BASH
	  99 - called with illegal/unknown option(s)

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
	  +--daily
	  |   +--latest --> ./2015-04-02.223000
	  |   +--2015-03-30.223000
	  |   +--2015-03-31.223000
	  |   +--2015-04-01.223000
	  |
	  +--weekly
	  |   +--2015-03-30.223000
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

#---[FUNCTION]------------------------------------------------------------------
# Deletes outdated backups
#
# Globals:
#   dryrun - if set, no deletions are executed
#   log_*  - uses standard logging
# Arguments:
#   $1 - root directory (e.g. "daily" or "monthly") to look for outdated backups
#   $2 - number of days backups should be kept
# Returns:
#   nothing (loggs errors and some debugging output)
#-------------------------------------------------------------------------------
purge_outdated_backups()
{
    local search_root="$1"
    local keep_days="$2"
    local removed_count=0

    log_i "Removing outdated backups in [${search_root}]" \
          "older than [${keep_days}] days"

    program='find'
    args=( "${search_root}"         )
    args+=('-maxdepth' 1            )
    args+=('-mindepth' 1            )
    args+=('-type' 'd'              )
    args+=('-mtime' "+${keep_days}" )

    for dir_to_remove in $( "${program}" "${args[@]}" ); do
        log_d " - ${dir_to_remove}"
        (( removed_count++ ))
        if ${dryrun}; then
            log_d "   (dry-run, will not remove)"
        else
            if ! bgi_safe_remove_dir "${dir_to_remove}"; then
                log_e "Error removing [${dir_to_remove}], rm returned rc [$?]"
            fi
        fi
    done
    if [[ "${removed_count}" -gt 0 ]]; then
        log_i "Removed [${removed_count}] backups"
    else
        log_i "No outdated backups found"
    fi
}

#---[FUNCTION]------------------------------------------------------------------
# Uses rsync to copy directories. Makes use of rsync's --link-dest option
# to deduplicate on file level
#
# Globals:
#   dryrun - if set, nothing is copied
#   log_*  - uses standard logging
# Arguments:
#   $1 - source directory which's content will be copied
#   $2 - destination directory
#   $3 - OPTIONAL: Directory to point rsync's --link-dest to.
#        If omitted, rsync will be called completely without --link-dest
# Returns:
#   rc 0     - operation successfull
#   rc > 100 - rsync error (substact 100 to get the rsync rc)
#   In addition, the function logs errors and some debugging output via log_*
#-------------------------------------------------------------------------------
copy_by_rsync_link()
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
            return ${rc_err_create_backup_dir}
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
    return ${rc_ok}
}

#---[FUNCTION]------------------------------------------------------------------
# Creates staging directories (daily, weekly and monthly) a hopefully safe way
#
# Globals:
#   dryrun - if set, nothing is copied
#   log_*  - uses standard logging
# Arguments:
#   $1 - full path of the directory to create
# Returns:
#   rc 0 - operation successfull
#   rc 3 - some kind of problem creating the dir (checl the logs for details)
#   In addition, the function logs errors and some debugging output via log_*
#-----------------------------------------------------------------------------
create_staging_directory()
{
    local dir_to_create=$(clean_dirname "$1");

    if ${dryrun}; then
        log_d "   (dry-run, will not create directories)"
    else
        if [[ ! -d "${dir_to_create}" ]]; then
            log_n "Backup subdir [${dir_to_create}] does not yet exist, creating..."
            if ! mkdir -- "${dir_to_create}"; then
                log_e "Unable to create the backup subdir [${dir_to_create}], mkdir rc [$?]"
                return ${rc_err_staging_dir}
            fi
        fi
        if [[ ! -w "${dir_to_create}" ]]; then
            log_e "Backup subdir [${dir_to_create}] exists, but is not writable to me"
            return ${rc_err_staging_dir}
        fi
    fi
}

#===============================================================================
#  COMMAND LINE PROCESSING
#-----------------------------------------------------------------------------
OPTIND=1
while getopts hvs:d:D:W:M:w:m:t:z opt; do
    case $opt in
    s) src_root_raw=${OPTARG} ;;
    d) dst_root_raw=${OPTARG} ;;
    D) keep_days_daily=${OPTARG} ;;
    W) keep_days_weekly=${OPTARG} ;;
    M) keep_days_monthly=${OPTARG} ;;
    t) infotext=${OPTARG} ;;
    w) day_weekly=${OPTARG} ;;
    m) day_monthly=${OPTARG} ;;
    v) log_verbosity=$((log_verbosity + 1)) ;;
    z) dryrun=true; log_verbosity=3 ;;
    h) usage && exit ${rc_ok} ;;
    *) usage && exit ${rc_err_unknown_options} ;;
    esac
done
shift $(( OPTIND - 1 ))

#===============================================================================
#  MAIN SCRIPT
#-----------------------------------------------------------------------------
message_start="Start..."
message_end="Finished..."
if [[ -n "${infotext}" ]]; then
    message_start="Start ${infotext}"
    message_end="Finished ${infotext}"
fi

log_n "${message_start}"

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

# ----------------------------------------------------------------------------
# check for root directories
src_root=$(abs_path "${src_root_raw}") || src_root=''
dst_root=$(abs_path "${dst_root_raw}") || dst_root=''
if [[ ! -d "${src_root}" ]]; then
    log_e "Source directory [${src_root_raw}] does not exist or is not a directory"
    exit ${rc_err_source_dir}
fi
if [[ ! -r "${src_root}" ]]; then
    log_e "Source directory [${src_root_raw}] exists, but is not readable to me"
    exit ${rc_err_source_dir}
fi

if [[ ! -d "${dst_root}" ]]; then
    log_e "Backup root [${dst_root_raw}] does not exist or is not a directory"
    exit ${rc_err_destination_dir}
fi
if [[ ! -w "${dst_root}" ]]; then
    log_e "Backup root [$dst_root_raw] exists, but is not writable to me"
    exit ${rc_err_destination_dir}
fi

# ----------------------------------------------------------------------------
# check for (and create if necessary) backup staging directories
dst_daily="${dst_root}/daily"
dst_weekly="${dst_root}/weekly"
dst_monthly="${dst_root}/monthly"
log_d "Daily backups dir:...[${dst_daily}]"
log_d "Weekly backups dir:..[${dst_weekly}]"
log_d "Monthly backups dir:.[${dst_monthly}]"
create_staging_directory "${dst_daily}"   || exit ${rc_err_staging_dir}
create_staging_directory "${dst_weekly}"  || exit ${rc_err_staging_dir}
create_staging_directory "${dst_monthly}" || exit ${rc_err_staging_dir}

# ----------------------------------------------------------------------------
# prepare for the backup
dst="${dst_daily}/$(date +'%Y-%m-%d.%H%M%S')"
log_d "Backup destination:..[${dst}]"

dst_link=''
[[ -e "${dst_daily}/latest/" ]] && dst_link="${dst_daily}/latest/"


# ----------------------------------------------------------------------------
# do the backup
# - create the directory $dst
# - put your files in there
# - in case of problems, exit with a meaningful rc (and document this)
# In case of file system backups, the first two steps are handled by
# copy_by_rsync_link, which also already returns with a good rc we simply
# forward.
if copy_by_rsync_link "$src_root" "$dst" "$dst_link"; then
    log_i "Backup successfull"
else
    rc_backup=$?
    log_e "Error backing up, check the logs!"
    exit ${rc_backup}
fi

# ----------------------------------------------------------------------------
# create/update "latest" link
link_destination="${dst_daily}/latest"
log_d "Updating 'latest' link in daily"

if [[ -e "${link_destination}" ]]; then
    log_d "Old link found, removing"
    if ! ${dryrun}; then
        bgi_safe_remove_file "${link_destination}" || {
            rm_rc=$?
            log_e "error removing the 'latest' link, rc [${rm_rc}]!"
            exit ${rc_err_latest_link}
        }
    else
        log_d "   (dry-run, will not delete old link)"
    fi
else
    log_d "No old link found"
fi

link_source=$(basename "${dst}")
program='ln'
args=('-s')   # symlink
args+=("${link_source}")
args+=("${link_destination}")
log_d "Command is [${program} ${args[@]}]"
if ${dryrun}; then
    log_d "   (dry-run, will not create new link)"
else
    "${program}" "${args[@]}" || {
        ln_rc=$?
        log_e "ln reported an error, rc [${ln_rc}]!"
        exit ${rc_err_latest_link}
    }
fi

# ----------------------------------------------------------------------------
# on "weekly" day, copy backups to weekly dir
if [[ $(date +%u) -ne "${day_weekly}" ]]; then
    log_d "Not a ${day_weekly_name}, no weekly backups today"
else
    log_d "${day_weekly_name} - creating a copy in weekly"

    wdst="${dst_weekly}/$(basename "${dst}")"
    log_d "Weekly backup dir:..[${wdst}]"

    if ! copy_by_rsync_link "${dst}" "${wdst}" "${dst}"; then
        log_e "Error creating weekly backup"
    fi
fi

# ----------------------------------------------------------------------------
# on "monthly" day, copy backups to monthly dir
if [[ $(date +%d) -ne "${day_monthly}" ]]; then
    log_d "Not the ${day_monthly}., no monthly backups today"
else
    log_d "${day_monthly}. day in month - creating a copy in monthly"

    mdst="${dst_monthly}/$(basename "${dst}")"
    log_d "Monthly backup dir:..[${mdst}]"

    if ! copy_by_rsync_link "${dst}" "${mdst}" "${dst}"; then
        log_e "Error creating monthly backup"
    fi
fi

# ----------------------------------------------------------------------------
# Purge old backups
purge_outdated_backups "${dst_daily}"   "${keep_days_daily}"
purge_outdated_backups "${dst_weekly}"  "${keep_days_weekly}"
purge_outdated_backups "${dst_monthly}" "${keep_days_monthly}"

log_n "${message_end}"

