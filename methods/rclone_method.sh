#!/usr/bin/env bash

# Destination repository setted in init_method without ':' at the end
RCLONE_REPO=""
# Subdirectory for rclone repo
RCLONE_SUBDIR="/"
# Destination dir on remote setted in init_method without trailing slash
RCLONE_DEST=""
# Setted true after initialisation
RCLONE_INITED=false

# Check if method is inited
_check_init() {
    if ! $RCLONE_INITED && ! $CLEANING_UP; then
        abord "Rclone method not inited"
    fi
}

_check_dependencies() {
    if ! command -v "rclone" &>/dev/null; then
        abord "rclone command not found. You need to install it before using this script.
See https://rclone.org/install/ for install instructions."
    fi
}

_is_remote_crypted() {
    rclone listremotes --long | grep -q "^${RCLONE_REPO}:[[:space:]]\+crypt"
    return $?
}

# Check file on remote
# $1 string source file (full path)
# $2 string directory containing destination file
_check_file() {
    local srcFile="$1"
    local destFile="$2"
    local cmd="check"

    if _is_remote_crypted; then
        cmd="cryptcheck"
    fi

    log_cmd rclone $cmd "$srcFile" "$destFile"
    return $?
}

# List files for a specific archive names
# $1 archive name
_list_files() {
    local name="$1"
    rclone lsf "${RCLONE_DEST}/" --max-depth 1 2>/dev/null | grep "^${name}.*"
}

# Initialisation for the method.
# Get script args to set global variable for this method
init_method() {
    _check_dependencies

    # shellcheck disable=SC2034
    local -A args_array=([r]=repository= [p]=path=)
    local repository=""
    local path=""
    handle_getopts_args "$@"

    if [[ -z "$repository" ]]; then
        abord "repository is required"
    fi

    repository="${repository%%:*}"

    if ! rclone listremotes | grep -q "^${repository}:$"; then
        abord "Rclone repository '${repository}' doesn't exists"
    fi

    if [[ -n $path ]]; then
        path="${path#/}" # Clean leading slash
        path="${path%/}" # Clean trailing slash
        RCLONE_SUBDIR="/${path}"
    fi

    RCLONE_REPO="${repository}"
    RCLONE_DEST="${RCLONE_REPO}:${RCLONE_SUBDIR}"
    RCLONE_DEST="${RCLONE_DEST%/}" # Clean trailing slash
    RCLONE_INITED=true
}

### FUNCTION BEGIN
# Get available space for destination dir
# GLOBALS:
# 	RCLONE_REPO destination dir for archives
# OUTPUTS:
# 	Print available spice in bytes (integer)
### FUNCTION END
get_available_space() {
    _check_init

    rclone about --json "${RCLONE_REPO}:" | grep "free" | sed 's/.*"free": *\([^,}]*\).*/\1/'
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	RCLONE_REPO destination dir for archives
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
            rclone lsl "${RCLONE_DEST}/" --max-depth 1 --include "*.tar*" 2>/dev/null |
                sed "s/^ *[0-9][0-9]* //" |
                sort |
                sed "s/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]* //" |
                sed "s/\.tar.*$//" |
                uniq
            return 0
            ;;
        newerfirst | n)
            rclone lsl "${RCLONE_DEST}/" --max-depth 1 --include "*.tar*" 2>/dev/null |
                sed "s/^ *[0-9][0-9]* //" |
                sort --reverse |
                sed "s/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]* //" |
                sed "s/\.tar.*$//" |
                uniq
            return 0
            ;;
        *)
            abord "unkown sort order '$sort'"
            ;;
        esac
    fi

    rclone lsf "${RCLONE_DEST}/" --max-depth 1 --include "*.tar*" 2>/dev/null | sed "s/\.tar.*$//" | uniq
    return 0
}

### FUNCTION BEGIN
# Get archive count available on repository
# GLOBALS:
# 	RCLONE_REPO destination dir for archives
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
#   RCLONE_REPO destination dir for archives
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

    local verbose=""
    [[ "${LOG_VERBOSE:-false}" == "true" ]] && verbose="--verbose"
    local error=false

    local -a transfered_files=()
    for file in "${FILES_TO_TRANSFERT[@]}"; do

        log "Transfering file '${file}'..." verbose
        if ! log_cmd rclone copy "${file}" "${RCLONE_DEST}/" ${verbose}; then
            log "Unable to transfert '$file'" error
            error=true
            break

        fi

        log "Checking file '${file}'..." verbose
        if ! _check_file "${file}" "${RCLONE_DEST}/"; then
            log "Check '$file' failed" verbose
            error=true
            break
        fi

        local dest_file_path
        dest_file_path=$(basename "${file}")
        transfered_files+=("$dest_file_path")
        log "File '$file' transfered to '${RCLONE_DEST}/'" verbose
    done

    # If there is an error, we delete already transfered files
    if $error; then
        for file_to_delete in "${transfered_files[@]}"; do
            log "Delete transfered file '$file_to_delete'" verbose
            log_cmd rclone deletefile "${RCLONE_DEST}/${file_to_delete}" ${verbose}
        done
        return 1
    fi

    log "${#FILES_TO_TRANSFERT[@]} files transfered" verbose

    return 0
}

### FUNCTION BEGIN
# Cleanup destination repository (ex: umount a drive)
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
cleanup_method() {
    return 0
}

### FUNCTION BEGIN
# Delete an archive in repository
# GLOBALS:
#   RCLONE_REPO destination dir for archives
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

    local verbose=""
    [[ "${LOG_VERBOSE:-false}" == "true" ]] && verbose="--verbose"
    local error=false

    # We try to delete maximum files
    while IFS= read -r file; do
        if ! log_cmd rclone deletefile "${RCLONE_DEST}/${file}" ${verbose}; then
            log "Error deleting file '$file'" verbose
            error=true
        fi

        log "File '$file' deleted" verbose
    done < <(_list_files "$name")

    if $error; then
        return 1
    else
        return 0
    fi
}

### FUNCTION BEGIN
# Usage help for local method
# OUTPUTS:
# 	Print usage on stdout
### FUNCTION END
usage_method() {
    cat <<USAGE_METHOD
   Local method options :
      -r |--repository=<rclone repository> : (mandatory) Rclone repository without ':' at the end
      -p |--path=<path> : Directory in rclone repository (default: /)
USAGE_METHOD
}

### FUNCTION BEGIN
# Fetch archive files to a local destination
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   RCLONE_DEST destination dir for archives
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

    local verbose=""
    [[ "${LOG_VERBOSE:-false}" == "true" ]] && verbose="--verbose"

    while IFS= read -r file; do
        if ! log_cmd rclone copy "${RCLONE_DEST}/${file}" "${destination}/" ${verbose}; then
            log "Unable to transfert '$file'" error
            return 1
        fi
        
        local filename
        filename=$(basename "$file")

        FILES_TO_TRANSFERT+=("${destination}/${filename}")
        log "File '$file' fetched" verbose
    done < <(_list_files "$name")

    return 0
}
