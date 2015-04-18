#!/bin/bash
#===============================================================================
#          FILE: backup_db.sh
#   DESCRIPTION: Backup MariaDB databases, with daily/weekly/monthly backups
#        AUTHOR: Bernd Giegerich (bgi), Bernd.A.Giegerich@gmail.com
#-------------------------------------------------------------------------------
# 2015-04-18  bgi  1.0.0  Initial version
#-------------------------------------------------------------------------------
readonly version='1.0.0'
readonly needed_externals='awk basename date dirname find gzip ln mkdir rm
                           rsync sed mysql mysqldump mysqlshow'
shopt -s extglob
set -o pipefail

#===============================================================================
#  DEFAULTS
#-------------------------------------------------------------------------------
# mysql specific config
mysql_host='localhost'
mysql_port='3306'

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
src_dbs_raw=''
dst_root=''
mysql_creds=''
mysql_dump_opts='
    --add-drop-database
    --add-drop-table
    --allow-keywords
    --create-options
    --dump-date
    --comments
    --events
    --routines
    --triggers
    --add-locks
    --tz-utc
    --extended-insert
    --disable-keys
    --flush-privileges
    --quick
    --single-transaction
'

readonly rc_ok=0
readonly rc_error_source_dbs=1
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

#---[FUNCTION]------------------------------------------------------------------
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
	  or ${script_name} [options] -C </path/to/credentials/file> -d </path/to/backup/root>

	Options:
	  -h                print this usage info and exit with exit code 0

	  -d <directory>    destination directory (backup root, see below)
	  -C <file>         path to the config file holding the credentials

	  -s <list of dbs>  comma separated list of source databases to backup
	                    (defaults to: all but information_ and performance_schema)
	  -H <host name>    MariaDB host to backup (default: [${mysql_host}])
	  -P <port #>       port to connect to (default: [${mysql_port}])
	  -w <week day>     day of the week (1..7; 1=Monday) to do the weekly (default: [$day_weekly])
	  -m <day>          day of the month to do the monthly (default: [$day_monthly])
	  -D <# days>       number of days to keep the daily backups (default: [$keep_days_daily])
	  -W <# days>       number of days to keep the weekly backups (default: [$keep_days_weekly])
	  -M <# days>       number of days to keep the monthly backups (default: [$keep_days_monthly])
	  -t <text>         text added to the "Start" and "Stop" log entries (default: none)
	  -l <facility>     log facility to use (default: [$log_facility])
	  -v                increase verbosity (up to 3x)
	  -z                do a dry-run (automatically sets -vvv)

	  -C and -d are mandatory, all other options have some defaults set.

	Requirements:
	  Bash (not in Posix or sh compatibility mode)
	  ${needed_externals}

	Exit codes:
	   0 - no errors
	   1 - problems getting a list of dbs to backup
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
	  file level (rsync --link-dest), so the weekly and monthly backups
	  don't take up more space than necessary.
	  If called without a list of databases to backup, ${script_name} backs
	  up all databases BUT NOT information_schema and performance_schema.
	  If you want to back them up for any reasons, you have to name them
	  explicitely.
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
#   rc > 100 - rsync error (subtract 100 to get the rsync rc)
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

#---[FUNCTION]------------------------------------------------------------------
# Returns a list of databases on the local MariaDB server
#
# Globals:
#   dryrun      - if set, nothing is copied
#   log_*       - uses standard logging
#   mysql_host  - host to connect to
#   mysql_port  - port to connect to
#   mysql_creds - full path of the file holding username and password
# Arguments:
#   none
# Returns:
#   rc 0 - operation successfull
#   rc > 0 - mysql error (same rc mysql returned)
#   In addition, the function logs errors and some debugging output via log_*
#-----------------------------------------------------------------------------
get_db_list()
{
    local mysqlshow_args
    local sed_args
    local awk_args
    local db_list

    mysqlshow_args+=("--defaults-extra-file=${mysql_creds}") # must be first!
    mysqlshow_args+=("--host=${mysql_host}")
    mysqlshow_args+=("--port=${mysql_port}")
    sed_args+=('-r' '/Databases|information_schema|performance_schema/d')
    awk_args+=('{ print $2 }')

    log_d "Executing [mysqlshow ${mysqlshow_args[@]} | sed ${sed_args[@]} | awk ${awk_args[@]}]"

    db_list=$( mysqlshow "${mysqlshow_args[@]}" |
               sed "${sed_args[@]}"             |
               awk "${awk_args[@]}"             )

    if [[ $? -eq 0 ]]; then
        echo "${db_list}"
        return 0
    else
        return $?
    fi
}

#===============================================================================
#  COMMAND LINE PROCESSING
#-----------------------------------------------------------------------------
OPTIND=1
while getopts C:d:D:hH:m:M:P:s:t:vw:W:z opt; do
    case $opt in
    C) mysql_creds=${OPTARG} ;;
    d) dst_root_raw=${OPTARG} ;;
    D) keep_days_daily=${OPTARG} ;;
    H) mysql_host=${OPTARG} ;;
    h) usage && exit ${rc_ok} ;;
    m) day_monthly=${OPTARG} ;;
    M) keep_days_monthly=${OPTARG} ;;
    P) mysql_port=${OPTARG} ;;
    s) src_dbs_raw=${OPTARG} ;;
    t) infotext=${OPTARG} ;;
    v) log_verbosity=$((log_verbosity + 1)) ;;
    w) day_weekly=${OPTARG} ;;
    W) keep_days_weekly=${OPTARG} ;;
    z) dryrun=true; log_verbosity=3 ;;
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
log_d " -s (source dbs):....[${src_dbs_raw}]"
log_d " -d (backup root):...[${dst_root_raw}]"
log_d " -w (weekly day): ...[${day_weekly}] -> [${day_weekly_name}]"
log_d " -m (monthly day):...[${day_monthly}]"
log_d " -D (keep daily):....[${keep_days_daily}]"
log_d " -W (keep weekly):...[${keep_days_weekly}]"
log_d " -M (keep monthly):..[${keep_days_monthly}]"
log_d " -i (info text):.....[${infotext}]"

# ----------------------------------------------------------------------------
# check for sources and destinations
if [[ -n "${src_dbs_raw}" ]]; then
    OLD_IFS="$IFS"
    IFS=","
    src_dbs=( $src_dbs_raw )
    IFS="$OLD_IFS"
else
    log_n "No databases specified, will backup all but some system DBs"
    if ! src_dbs=$(get_db_list); then
        log_e "No databases specified, and unable to retrieve a list od DBs." \
              "RC returned by mysql: [$?]"
        exit ${rc_error_source_dbs}
    fi
fi
for db in ${src_dbs[@]}; do
    log_d "Will backup:.........[${db}]"
done

dst_root=$(abs_path "${dst_root_raw}") || dst_root=''
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
if ${dryrun}; then
    log_d "   (dry-run, will not create destination)"
else
    mkdir -- "${dst}" || {
        log_e "Unable to create the destination dir [${dst}], mkdir rc [$?]"
        exit ${rc_err_create_backup_dir}
    }
    for db in ${src_dbs[@]}; do
        log_i "Backing up database [${db}]"

        unset dump_args
        dump_args+=("--defaults-extra-file=${mysql_creds}")
        dump_args+=("--host=${mysql_host}")
        dump_args+=("--port=${mysql_port}")
        dump_args+=(${mysql_dump_opts})
        dump_args+=(${db})

        mysqldump "${dump_args[@]}" | gzip > "${dst}/${db}.sql.gz"
        if [[ $? -eq 0 ]]; then
            log_d "Done with [${db}]"
        else
            log_e "Error backing up [${db}]!"
        fi
    done
fi # dryrun?

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

