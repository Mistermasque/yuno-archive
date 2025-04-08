#!/usr/bin/env bash

# Setted true after initialisation
EXAMPLE_INITED=false

# Check if method is inited
_check_init() {
    if ! $EXAMPLE_INITED && ! $CLEANING_UP; then
        abord "Example method not inited"
    fi
}


###############################################################################
#                          Functions to be implemented                        #
###############################################################################

# Initialisation for the method.
# Get script args to set global variable for this method
init_method() {
    log "Init example" verbose
    EXAMPLE_INITED=true
}

### FUNCTION BEGIN
# Get available space for destination dir
# GLOBALS:
# 	VAR1
# OUTPUTS:
# 	Print available spice in bytes (integer)
### FUNCTION END
get_available_space() {
    _check_init
    echo 50
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	VAR1
# ARGUMENTS:
# -s, --sort=<sort direction> : olderfirt|newerfirst
# OUTPUTS:
# 	Print list
### FUNCTION END
list_archives() {
    _check_init

    # shellcheck disable=SC2034
    local -A args_array=([s]=sort=)
    local sort=""
    handle_getopts_args "$@"

    local list="2025-01-02_15-30-12
2025-02-02_15-30-12"

    case $sort in
    olderfirt)
        echo "${list}" | sort --reverse
        ;;
    newerfirst)
        echo "${list}" | sort
        ;;
    *)
        echo "${list}"
        ;;
    esac
}

### FUNCTION BEGIN
# Get archive count available on repo
# GLOBALS:
# 	VAR1
# OUTPUTS:
# 	Print value in bytes
### FUNCTION END
count_archives() {
    list_archives "" | wc -l
}

### FUNCTION BEGIN
# Send archive to dest
# GLOBALS:
# 	VAR1
# ARGUMENTS:
# -n, --name=<archive name> : mandatory
# -a, --archive=<archive path> : mandatory archive file path
# -m, --md5=<md5 path> : mandatory md5 file path
# -i, --info=<info files path> : optionnal info files separated by semi-colon
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
send_to_dest() {
    _check_init
    # shellcheck disable=SC2034
    local -A args_array=([n]=name= [a]=archive= [i]=info= [m]=md5=)
    local name=""
    local archive=""
    local info=""
    local md5=""
    local -a info_files=()
    handle_getopts_args "$@"

    log "name : '$name'" info
    log "archive : '$archive'" info
    log "info : '$info'" info
    log "md5 : '$md5'" info

    if [[ -z "$name" ]]; then
        log "Archive name is mandatory" error
        return 1
    fi

    if [[ -z "$archive" ]]; then
        log "Archive path is mandatory" error
        return 1
    fi

    if [[ ! -f "$archive" ]]; then
        log "Archive path '$archive' doesn't exists or is no accessible" error
        return 1
    fi

    if [[ -z "$md5" ]]; then
        log "Md5 path is mandatory" error
        return 1
    fi

    if [[ ! -f "$md5" ]]; then
        log "Md5 path '$md5' doesn't exists or is no accessible" error
        return 1
    fi

    if [[ -n "$info" ]]; then
        IFS=';' read -r -a info_files <<<"$info"
        # loop each file
        for file in "${info_files[@]}"; do
            file="${file#"${file%%[![:space:]]*}"}" # Trim leading spaces
            file="${file%"${file##*[![:space:]]}"}" # Trim trailing spaces

            if [[ ! -f "$file" ]]; then
                log "Info file '$file' doesn't exists or is inaccesible" error
                return 1
            fi
        done
    fi

    log "OK" success

    return 0

}

### FUNCTION BEGIN
# Cleanup destination repo (ex: umount a drive)
# GLOBALS:
# 	VAR1
# OUTPUTS:
# 	Logs
# RETURNS:
#   0 on success, 1 otherwise
### FUNCTION END
cleanup_method() {
    _check_init
    log "Umount dummy drive" verbose
    return 0
}

### FUNCTION BEGIN
# List available archives names stored in dest
# GLOBALS:
# 	VAR1
# ARGUMENTS:
# -s, --sort=<sort direction> : olderfirt|newerfirst
# OUTPUTS:
# 	Print list
### FUNCTION END
delete_archive() {
    _check_init
    # shellcheck disable=SC2034
    local -A args_array=([n]=name=)
    local name=""
    handle_getopts_args "$@"

    log "Delete archive '$name'" verbose
    return 0
}