#!/usr/bin/env bash

# Destination drive setted in init_method without trailing slashed
DRIVE_DEST=""
# Subdirectory for drive
DRIVE_SUBDIR=""
# Drive destination composed by DRIVE_MOINTPOINT/DRIVE_SUBDIR
DRIVE_REPO=""
# Mounted repo for drive
DRIVE_MOUNTPOINT=""
# Setted true after initialisation
DRIVE_INITED=false
# Check if drive is already mounted before preparation
DRIVE_ALREADY_MOUNTED=false

# Check if method is inited
_check_init() {
    if ! $DRIVE_INITED && ! $CLEANING_UP; then
        abord "Drive method not inited"
    fi
}

### FUNCTION BEGIN
# Mount destination drive
# GLOBALS:
#    DRIVE_DEST
#    DRIVE_MOUNTPOINT : set this var for mount point
#    DRIVE_ALREADY_MOUNTED : set this var if drive have been mounted before
#    DRIVE_REPO : Set this var for destination archives files
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
_mount_drive() {

    log "Mounting drive '${DRIVE_DEST}'..." verbose

    if findmnt --source "${DRIVE_DEST}" >/dev/null 2>&1; then
        # We keep only first line to avoid multimounted drive return
        DRIVE_MOUNTPOINT=$(findmnt --source "${DRIVE_DEST}" --uniq --first-only --output TARGET --noheadings)
        DRIVE_ALREADY_MOUNTED=true
        log "Drive '${DRIVE_DEST}' already mounted for dir '${DRIVE_MOUNTPOINT}' !" verbose
    else
        DRIVE_MOUNTPOINT=$(mktemp --directory --tmpdir=/mnt)

        if ! log_cmd mount "${DRIVE_DEST}" "${DRIVE_MOUNTPOINT}" -t auto; then
            abord "Unable to mount drive '${DRIVE_DEST}' on '${DRIVE_MOUNTPOINT}'."
        fi
        log "Drive '${DRIVE_DEST}' mounted on '${DRIVE_MOUNTPOINT}'" verbose
    fi

    if ! mkdir -p "${DRIVE_MOUNTPOINT}/${DRIVE_SUBDIR}"; then
        abord "Cannot make repository '${DRIVE_MOUNTPOINT}/${DRIVE_SUBDIR}'"
    fi

    # Set destination rights (non blocking)
    chmod o=rt,u=rwx,g=rx "${DRIVE_MOUNTPOINT}/${DRIVE_SUBDIR}" || true

    DRIVE_REPO="${DRIVE_MOUNTPOINT}/${DRIVE_SUBDIR}"
    log "Drive repository '${DRIVE_REPO}' available" verbose

    return 0
}

# Initialisation for the method.
# Get script args to set global variable for this method
init_method() {
    # shellcheck disable=SC2034
    local -A args_array=([r]=repository= [D]=drive=)
    local repository="backups"
    local drive=""
    handle_getopts_args "$@"

    if [[ -z "$drive" ]]; then
        abord "drive is required"
    fi

    drive="${drive%/}" # Clean trailing slash

    if [[ -L "$drive" ]]; then
        drive=$(readlink -f "$drive")
    fi

    if [[ ! -b $drive ]]; then
        abord "drive '$drive' is not a drive"
    fi

    DRIVE_DEST="$drive"
    DRIVE_SUBDIR=${repository%/} # Clean trailing slash

    _mount_drive || return 1

    DRIVE_INITED=true

    return 0
}

### FUNCTION BEGIN
# Umount drive
# GLOBALS:
#    DRIVE_ALREADY_MOUNTED : If drive have been already mounted before launching script
#    DRIVE_DEST
#    DRIVE_MOUNTPOINT : to delete mount point if it have been created by this method
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
cleanup_method() {

    if ! $DRIVE_INITED; then
        return 0
    fi

    if $DRIVE_ALREADY_MOUNTED; then
        log "Drive already mounted before, nothing to do" verbose
        return 0
    fi

    local busy=true
    local cpt=0

    if ! mount | grep -q "${DRIVE_DEST}"; then
        log "Drive '${DRIVE_DEST}' not mounted, nothing to do" verbose
        return 0
    fi

    # Avoid being on mounted drive
    local _mountedDestDir
    _mountedDestDir=$(mount | grep "${DRIVE_DEST}" | awk "{ print \$3 }")
    if pwd | grep -q "$_mountedDestDir"; then
        cd "/tmp" || return 1
    fi

    log "Umount drive '${DRIVE_DEST}'..." verbose
    while $busy; do
        if mountpoint -q "${_mountedDestDir}"; then
            if umount "${DRIVE_DEST}" 2>/dev/null; then
                busy=false
            else
                log "Device busy, waiting 5 seconds before next try..." verbose
                sleep 5
            fi
        else
            busy=false
        fi
        cpt=$((cpt + 1))
        if [[ $cpt -gt 15 ]]; then
            break
        fi
    done

    if $busy; then
        log "Unable to umount '${DRIVE_DEST}'" error
        return 1
    else
        log "Drive '${DRIVE_DEST}' umounted" verbose
    fi

    rm -rf "${DRIVE_MOUNTPOINT}"

    return 0
}

### FUNCTION BEGIN
# Get available space for destination dir
# GLOBALS:
# 	DRIVE_REPO destination dir for archives
# OUTPUTS:
# 	Print available spice in bytes (integer)
### FUNCTION END
get_available_space() {
    _check_init

    findmnt --target "$DRIVE_REPO" --output AVAIL --bytes --noheadings --first-only
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	DRIVE_REPO destination dir for archives
# ARGUMENTS:
# $1 : sort order olderfirt|o for older first,  n|newerfirst for newer first, false for not using it
# $2 : full {true|false} if true print full list with size and date, if false print only names
# $3 : human_readable {true|false} if true print human readable size and date, if false print size in bytes and date as timestamp
# OUTPUTS:
# 	Print list
### FUNCTION END
list_archives() {
    _check_init

    local sort="${1:-false}"
    local full="${2:-false}"
    local human_readable="${3:-false}"
    local output=""

    # Get file list as this format:
    # name0    1231       1748679466.0759510370
    # name2    44477885       1748676862.828793055
    # name1    1254       1748676857.0679573940
    # name1    684654       174867354.7511667510
    output=$(
        find "$DRIVE_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%f\t%s\t%T@\n" |
            sed "s/\(^[^\t]*\)\.tar[^\t]*/\1/"
    )

    # Get file list as this format (ordered by date) :
    # name1    1254       1748676857.0679573940
    # name1    684654       174867354.7511667510
    # name2    44477885       1748676862.828793055
    # name0    1231       1748679466.0759510370
    if [[ $sort != false ]]; then
        case $sort in
        olderfirst)
            output=$(
                echo "${output}" | sort --field-separator=$'\t' --key=3,3
            )
            ;;
        newerfirst)
            output=$(
                echo "${output}" | sort --reverse --field-separator=$'\t' --key=3,3
            )
            ;;
        esac
    fi

    # Delete duplicate names
    output=$(echo "${output}" | awk '!a[$1]++')

    if [[ -z "${output}" ]]; then
        return 1
    fi

    # Echo only names
    if ! $full; then
        echo "${output}" | cut --fields=1
        return 0
    fi

    if ! $human_readable; then
        # Echo Tab header
        printf "Name\tSize\tTimestamp\n"
        # Echo full output without human readable size
        echo "${output}"
        return 0
    fi

    # Echo Tab header
    printf "Name\tSize\tDate\n"

    # Echo full output with human readable size
    while IFS=$'\t' read -r name size date; do
        printf "%s\t%s\t%s\n" "${name}" "$(hrb "${size}")" "$(date -d "@${date}")"
    done <<<"${output}"

    return 0
}

### FUNCTION BEGIN
# Get archive count available on repository
# OUTPUTS:
# 	Print count of archives
### FUNCTION END
count_archives() {
    list_archives false false false | wc -l  || echo 0
}

### FUNCTION BEGIN
# Send archive to dest
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   DRIVE_REPO destination dir for archives
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
send_to_dest() {
    _check_init

    if [[ ${#FILES_TO_TRANSFERT[@]} == 0 ]]; then
        log "No files to transfert" warning
        return 0
    fi

    log "Files to transfert ${FILES_TO_TRANSFERT[*]}" verbose

    local -a transfered_files=()
    for file in "${FILES_TO_TRANSFERT[@]}"; do
        if ! cp "$file" "$DRIVE_REPO"; then
            log "Unable to transfert '$file'" error
            for file_to_delete in "${transfered_files[@]}"; do
                log "Delete transfered file '$file_to_delete'" verbose
                rm -f "$file_to_delete"
            done
            return 1
        fi

        local dest_file_path
        dest_file_path="${DRIVE_REPO}/$(basename "${file}")"
        transfered_files+=("$dest_file_path")
        log "File '$file' transfered to '$DRIVE_REPO'" verbose
    done

    log "${#FILES_TO_TRANSFERT[@]} files transfered" verbose

    return 0
}

### FUNCTION BEGIN
# Delete an archive in repository
# GLOBALS:
#   DRIVE_REPO destination dir for archives
# ARGUMENTS:
# -s, --sort=<sort direction> : olderfirt|newerfirst
# OUTPUTS:
# 	Print list
### FUNCTION END
delete_archive() {
    # shellcheck disable=SC2034
    local -A args_array=([n]=name=)
    local name=""
    handle_getopts_args "$@"

    if [[ -z $name ]]; then
        abord "name is required"
    fi

    for file in "$DRIVE_REPO/${name}".*; do
        [[ -e "$file" ]] || continue
        if ! rm "$file"; then
            log "Error deleting file '$file'" verbose
            return 1
        fi

        log "File '$file' deleted" verbose
    done

    return 0
}

### FUNCTION BEGIN
# Usage help for local method
# OUTPUTS:
# 	Print usage on stdout
### FUNCTION END
usage_method() {
    cat <<USAGE_METHOD
   Local method options :
      -d |--drive=<destination drive> : (mandatory) Drive (partition) to store archives (ex: /dev/sdc1)
      -r |--repository=<subdir> : Subdirectory of the disk to use for storing the archives (default: backups)
USAGE_METHOD
}

### FUNCTION BEGIN
# Fetch archive files to a local destination
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   DRIVE_REPO destination dir for archives
# ARGUMENTS:
#   -n, --name=<archive name> : mandatory
#   -d, --destination=<path> : mandatory destination path to set files
# OUTPUTS:
# 	Print list
### FUNCTION END
fetch_from_dest() {
    # shellcheck disable=SC2034
    local -A args_array=([n]=name= [d]=destination=)
    local name=""
    local destination=""
    handle_getopts_args "$@"

    if [[ -z $name ]]; then
        abord "name is required"
    fi

    if [[ -z "$destination" ]]; then
        abord "destination is required"
    fi

    destination="${destination%/}" # Clean trailing slash

    if [[ ! -d "$destination" ]]; then
        abord "Destination '$destination' doesn't exists or innaccessible"
    fi

    for file in "$DRIVE_REPO/${name}".*; do
        [[ -e "$file" ]] || continue
        log "Fetching file '$file'..." verbose
        if ! cp "$file" "${destination}/"; then
            log "Error getting file '$file'" verbose
            return 1
        fi
        local filename
        filename=$(basename "$file")

        FILES_TO_TRANSFERT+=("${destination}/${filename}")
        log "File '$file' fetched in '${destination}'" verbose
    done

    return 0
}
