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

    if mount | grep -q "${DRIVE_DEST}"; then
        DRIVE_MOUNTPOINT=$(mount | grep "${DRIVE_DEST}" | awk "{ print \$3 }")
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
            if umount "${DRIVE_DEST}" 2> /dev/null; then
                busy=false
            else
                log "Device busy, waiting 5 seconds before next try..." verbose
                sleep 5
            fi
        else
            busy=false
        fi
        cpt=$(( cpt + 1 ))
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

    local mount_point
    mount_point=$(findmnt -T "$DRIVE_REPO" -o SOURCE -n)
    df -B1 --output="source,avail" "$mount_point" | awk "{ if (\$1 == \"$mount_point\") { print \$2 } }"
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	DRIVE_REPO destination dir for archives
# ARGUMENTS:
# -s, --sort=<sort direction> : olderfirt|o for older first,  n|newerfirst for newer first
# OUTPUTS:
# 	Print list
### FUNCTION END
list_archives() {
    _check_init

    # shellcheck disable=SC2034
    local -A args_array=([s]=sort=)
    local sort=""
    handle_getopts_args "$@"

    if [[ -n $sort ]]; then
        case $sort in
        olderfirst | o)
            find "$DRIVE_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%T@ %f\n" \
            | sort --numeric-sort \
            | sed "s/\.tar.*$//" \
            | sed "s/^[0-9][0-9\.]* //" \
            | uniq
            return 0
            ;;
        newerfirst | n)
            find "$DRIVE_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%T@ %f\n" \
            | sort --numeric-sort --reverse \
            | sed "s/\.tar.*$//" \
            | sed "s/^[0-9][0-9\.]* //" \
            | uniq
            return 0
            ;;
        *)
            abord "unkown sort order '$sort'"
            ;;
        esac
    fi

    find "$DRIVE_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%f\n" | sed "s/\.tar.*$//" | uniq
    return 0
}

### FUNCTION BEGIN
# Get archive count available on repository
# GLOBALS:
# 	DRIVE_REPO destination dir for archives
# OUTPUTS:
# 	Print value in bytes
### FUNCTION END
count_archives() {
    list_archives "" | wc -l
}

### FUNCTION BEGIN
# Send archive to dest
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   DRIVE_REPO destination dir for archives
# ARGUMENTS:
#   -n, --name=<archive name> : mandatory
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
send_to_dest() {
    _check_init

    # shellcheck disable=SC2034
    local -A args_array=([n]=name=)
    local name=""
    handle_getopts_args "$@"

    if [[ -z "$name" ]]; then
        log "Archive name is mandatory" error
        return 1
    fi

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
      -d |--drive=<destination drive> : Drive (partition) to store archives (ex: /dev/sdc1)
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