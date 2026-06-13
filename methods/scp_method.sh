#!/usr/bin/env bash

# This method needs to have a SSH key configured for the destination host
# ssh-keygen -f file_key
# ssh-copy-id -f file_key user@destination_host
# Example of repository : user@host:/absolute/directory/path

# Destination Host and user setted in init_method
SSH_HOST=""
# SSH port setted in init_method (default 22)
SSH_PORT=22
# Absolute destination dir setted in init_method without trailing slashed
SSH_DIR=""
# Correspond to SSH_HOST:SSH_DIR setted in init_method
SSH_REPO=""
# Setted true after initialisation
SSH_INITED=false

# Check if method is inited
_check_init() {
    if ! $SSH_INITED && ! $CLEANING_UP; then
        abord "Sftp method not inited"
    fi
}

# Send ssh command
_ssh_cmd() {
    ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_HOST" "$@"
    return $?
}

# Send ssh command and log it
_ssh_log_cmd() {
    log_cmd ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_HOST" "$@"
    return $?
}

# Initialisation for the method.
# Get script args to set global variable for this method
init_method() {
    # shellcheck disable=SC2034
    local -A args_array=([r]=repository= [p]=port=)
    local repository=""
    local port=""
    handle_getopts_args "$@"

    if [[ -z "$repository" ]]; then
        abord "repository is required"
    fi

    if [[ ! "$repository" =~ ^([a-zA-Z0-9._-]+@)?[a-zA-Z0-9._-]+:.+ ]]; then
        abord "Repository '$repository' is not a valid ssh repository format ([user@]host:/directory)"
    fi

    # Set SSH port if provided
    if [[ -n "$port" ]]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 || $port -gt 65535 ]]; then
            abord "Invalid port number '$port' (must be between 1 and 65535)"
        fi
        SSH_PORT=$port
    fi

    # Extract part before :/ to get hostpart
    SSH_HOST="${repository%%:*}"
    # Extract part after : to get directory
    SSH_DIR="${repository#*:}"
    SSH_DIR="${SSH_DIR%/}" # Clean trailing slash
    if [[ -z "$SSH_DIR" ]]; then
        SSH_DIR="/"
    fi

    # Check SSH connection (without password prompt and short timeout)
    if ! ssh -o BatchMode=yes -p "$SSH_PORT" -o ConnectTimeout=5 "$SSH_HOST" true 2>/dev/null; then
        abord "Cannot connect to '$SSH_HOST' did you configure a SSH key for this host ?"
    fi

    # Create remote directory if not exists
    if ! _ssh_log_cmd "mkdir -p -- \"$SSH_DIR\""; then
        abord "Cannot create remote repository directory '$SSH_DIR' on host '$SSH_HOST'"
    fi

    SSH_REPO="${SSH_HOST}:${SSH_DIR}"

    SSH_INITED=true
}

# Get available space for destination dir
# GLOBALS:
# 	SSH_REPO destination dir for archives
# OUTPUTS:
# 	Print available spice in bytes (integer)
get_available_space() {
    _check_init

    ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_HOST" "findmnt --target \"$SSH_DIR\" --output AVAIL --bytes --noheadings --first-only"
}

# List available archives names stored in destination
# GLOBALS:
# 	SSH_REPO destination dir for archives
# ARGUMENTS:
# $1 : sort order olderfirt|o for older first,  n|newerfirst for newer first, false for not using it
# $2 : full {true|false} if true print full list with size and date, if false print only names
# $3 : human_readable {true|false} if true print human readable size and date, if false print size in bytes and date as timestamp
# OUTPUTS:
# 	Print list in the format:
#   Name[tab]Size[tab]Timestamp
# RETURNS:
#   0 on success, 1 if there is no archives
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
        _ssh_cmd "find \"$SSH_DIR\" -maxdepth 1 -type f -name \"*.tar*\" -printf \"%f\t%s\t%T@\n\"" |
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
    output=$(echo "${output}" | awk -F '\t' '!a[$1]++')

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

# Get archive count available on repository
# OUTPUTS:
# 	Print count of archives
count_archives() {
    list_archives false false false | wc -l || echo 0
}

# Send archive to dest
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   SSH_REPO destination dir for archives
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
send_to_dest() {
    _check_init

    if [[ ${#FILES_TO_TRANSFERT[@]} == 0 ]]; then
        log "No files to transfert" warning
        return 0
    fi

    log "Files to transfert ${FILES_TO_TRANSFERT[*]}" verbose

    local -a transfered_files=()
    for file in "${FILES_TO_TRANSFERT[@]}"; do
        if ! log_cmd scp -P "$SSH_PORT" "$file" "${SSH_REPO}/"; then
            log "Unable to transfert '$file'" error
            for file_to_delete in "${transfered_files[@]}"; do
                log "Delete transfered file '$file_to_delete'" verbose
                _ssh_log_cmd rm -f "$file_to_delete"
            done
            return 1
        fi

        local dest_file_path
        dest_file_path="${SSH_DIR}/$(basename "${file}")"
        transfered_files+=("$dest_file_path")
        log "File '$file' transfered to '$SSH_REPO'" verbose
    done

    log "${#FILES_TO_TRANSFERT[@]} files transfered" verbose

    return 0
}

# Cleanup destination repository (ex: umount a drive)
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
cleanup_method() {

    return 0
}

# Delete an archive in repository
# GLOBALS:
#   SSH_REPO destination dir for archives
# ARGUMENTS:
# -s, --sort=<sort direction> : olderfirt|newerfirst
# OUTPUTS:
# 	Print list
delete_archive() {
    # shellcheck disable=SC2034
    local -A args_array=([n]=name=)
    local name=""
    handle_getopts_args "$@"

    if [[ -z $name ]]; then
        abord "name is required"
    fi

    _ssh_log_cmd "cd \"$SSH_DIR\" && rm \"${name}\".*"
    return 0
}

# Usage help for local method
# OUTPUTS:
# 	Print usage on stdout
usage_method() {
    cat <<USAGE_METHOD

SCP method use scp command to send archive (copy through ssh protocol)
You need to have a SSH server with key authentication enabled (see ssh-copy-id for more infos)

SCP method options :
    -r |--repository=<destination repository> : (mandatory) repository in the format [user@]host:/absolute/directory/path
    -p |--port=<port number> : (optional) SSH port number (default: 22)
USAGE_METHOD
}

# Fetch archive files to a local destination
# GLOBALS:
# 	FILES_TO_TRANSFERT array of files to transfert to dest
#   SSH_REPO destination dir for archives
# ARGUMENTS:
#   -n, --name=<archive name> : mandatory
#   -d, --destination=<path> : mandatory destination path to set files
# OUTPUTS:
# 	Print list
fetch_from_dest() {
    echo "fetch_from_dest"
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
        abord "Destination '$destination' doesn't exists or inaccessible"
    fi

    if ! log_cmd scp -P "$SSH_PORT" "${SSH_REPO}/${name}.*" "${destination}/"; then
        log "Unable to transfert files" error
        return 1
    fi
}

# Fetch archive snapshot files to a local destination
# Archive snapshot is a .snar file
# GLOBALS:
# 	SSH_REPO destination dir for archives
# ARGUMENTS:
#   $1 : archive name (mandatory)
#   $2 : destination path (mandatory)
# RETURNS:
#   0 on success, 1 otherwise (archive snapshot not found)
fetch_archive_snapshot() {
    _check_init

    local archive_name="$1"
    local destination_path="$2"

    if [[ -z "$archive_name" ]]; then
        abord "archive name is required"
    fi

    if [[ -z "$destination_path" ]]; then
        abord "destination path is required"
    fi

    local snapshot_file
    snapshot_file="${SSH_DIR}/${archive_name}.snar"

    if ! log_cmd scp -P "$SSH_PORT" "$SSH_HOST:${snapshot_file}" "${destination_path}"; then
        log "Unable to transfert '$snapshot_file'" error
        return 1
    fi

    log "Snapshot file '$snapshot_file' transfered to '$destination_path'" verbose

    return 0
}
