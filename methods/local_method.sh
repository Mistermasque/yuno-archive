#!/usr/bin/env bash

# Destination repository setted in init_method without trailing slashed
LOCAL_REPO=""
# Setted true after initialisation
LOCAL_INITED=false

# Check if method is inited
_check_init() {
    if ! $LOCAL_INITED && ! $CLEANING_UP; then
        abord "Local method not inited"
    fi
}

# Initialisation for the method.
# Get script args to set global variable for this method
init_method() {
    # shellcheck disable=SC2034
    local -A args_array=([r]=repository=)
    local repository=""
    handle_getopts_args "$@"

    if [[ -z "$repository" ]]; then
        abord "repository is required"
    fi

    repository="${repository%/}" # Clean trailing slash


    if [[ ! -d "$repository" ]]; then
        if ! mkdir -p "$repository"; then
            abord "Cannot make repository '$repository'"
        fi
    fi

    LOCAL_REPO="$repository"
    LOCAL_INITED=true
}

### FUNCTION BEGIN
# Get available space for destination dir
# GLOBALS:
# 	LOCAL_REPO destination dir for archives
# OUTPUTS:
# 	Print available spice in bytes (integer)
### FUNCTION END
get_available_space() {
    _check_init

    findmnt --target "$LOCAL_REPO" --output AVAIL --bytes --noheadings --first-only
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	LOCAL_REPO destination dir for archives
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
            find "$LOCAL_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%T@ %f\n" \
            | sort --numeric-sort \
            | sed "s/\.tar.*$//" \
            | sed "s/^[0-9][0-9\.]* //" \
            | uniq
            return 0
            ;;
        newerfirst | n)
            find "$LOCAL_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%T@ %f\n" \
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

    find "$LOCAL_REPO" -maxdepth 1 -type f -name "*.tar*" -printf "%f\n" | sed "s/\.tar.*$//" | uniq
    return 0
}

### FUNCTION BEGIN
# Get archive count available on repository
# GLOBALS:
# 	LOCAL_REPO destination dir for archives
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
#   LOCAL_REPO destination dir for archives
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
        if ! mv "$file" "$LOCAL_REPO"; then
            log "Unable to transfert '$file'" error
            for file_to_delete in "${transfered_files[@]}"; do
                log "Delete transfered file '$file_to_delete'" verbose
                rm -f "$file_to_delete"
            done
            return 1
        fi

        local dest_file_path
        dest_file_path="${LOCAL_REPO}/$(basename "${file}")"
        transfered_files+=("$dest_file_path")
        log "File '$file' transfered to '$LOCAL_REPO'" verbose
    done

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
#   LOCAL_REPO destination dir for archives
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

    for file in "$LOCAL_REPO/${name}".*; do
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
      -r |--repository=<destination repository> : (mandatory) Directory to store files
USAGE_METHOD
}

### FUNCTION BEGIN
# Fetch archive files to a local destination
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   LOCAL_REPO destination dir for archives
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

    for file in "$LOCAL_REPO/${name}".*; do
        [[ -e "$file" ]] || continue
        if ! ln -sfn "$file" "${destination}/"; then
            log "Error creating symbolic link to file '$file'" verbose
            return 1
        fi
        local filename
        filename=$(basename "$file")

        FILES_TO_TRANSFERT+=("${destination}/${filename}")
        log "Symbolic link to file '$file' created" verbose
    done

    return 0
}