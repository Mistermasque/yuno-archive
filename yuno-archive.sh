#!/usr/bin/env bash
# Fail on error
set -Eeuo pipefail

###############################################################################
#                             INIT GLOBAL VARS                                #
###############################################################################
# Script version
declare -r VERSION="0.2.0"

# Script dir
declare ROOT_DIR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
declare -r ROOT_DIR
# Available methods
declare -a METHODS
mapfile -t METHODS < <(find "$ROOT_DIR/methods" -maxdepth 1 -name "*_method.sh" -type f -printf '%f\n' | sed 's/_method.sh//g')
declare -r METHODS

# root temp dir used for creating TMP_DIR
# Used exported variable if setted
declare -r YARCH_TMPDIR=${YARCH_TMPDIR-/tmp}

# Files to transfert (before they will be tranfered)
declare -a FILES_TO_TRANSFERT=()

###############################################################################
#                               LOAD HELPERS                                  #
###############################################################################

source "${ROOT_DIR}/helpers/log"
source "${ROOT_DIR}/helpers/getopts"
source "${ROOT_DIR}/helpers/utils"

###############################################################################
#                             SCRIPT FUNCTIONS                                #
###############################################################################

usage() {
    cat <<USAGE
Script used to create an archive in tar format from dir and send it to a repo.
The destination repo depends on method used

Usage  :
   $(basename "$0") <Action> <Method> [Action options] [Method options]

<Action> :
   backup:  Backup a dir to a repo
   delete:  Delete a backup on repo
   help:    Print help message. If you want help for a method type help <Method>
   list:    List available backups on repo   
   restore: Restore a backup
   send:    Send local archives to remote repo
            It will send all archives that are not already present in the
            remote repository. It will also check if there is enough space on
            the remote repository to store the archives and delete as much as
            necessary.
   version: Print version and exit

<Method> : Method to used to send archive. Available methods are :
$(for method in "${METHODS[@]}"; do
    echo "   - $method"
done)

Options :
   General options :
      -l |--log=<log file> : Send messages to <log file>
      -q |--quiet : Do not print messages on stdout/stderr
      -v |--verbose : Be more verbose

   Backup action options :
      -c |--compress=<type> : Compress archive before send it <type> can be : gzip|bzip2|xz (if type not set, use gzip)
      -C |--check_size : Check if there is enough space in temp dir to create archive (compare source size to available space in root temp dir)
      -h |--hook=<script file> : Execute this script file before and after doing backup
      -i |--info=<info file> : Additionnal file to send with archive (sent unaltered). Possibility to add multiple files separated by spaces
      -n |--name=<archive name> : Archive name. If not set, use datetime
      -s |--source=<dir> : (mandatory) Source dir or files to backup.
      -k |--keep=all|<number to keep> : (default: all) How many exisiting backup do you want to keep if thereis not enough space on dest (all: do not prune old archives, 0 can prune all archives if necessary)

   List action options :
      -s |--sort=<sort order> : Sort backup list. <sort order> can be : olderfirst|o for older first, n|newerfirst for newer first
   
   Restore action options :
      -D |--destination=<dir> : (mandatory) Destination dir to restore archive
      -h |--hook=<script file> : Execute this script file before and after doing restoration
      -n |--name=<archive name> : (mandatory) Archive name to restore

   Send action options :
      -s |--source=<dir> : (mandatory) Source dir to send archives from

Global variables
   YARCH_TMPDIR : Export this variable to change root temp dir (default /tmp)

Hook file
    This file as to be an executable bash script. It will be called with this options :
    {before|after} {backup|restore}  [Action options] [Method options]

USAGE
}

load_method() {
    local method="$1"

    if [[ -z "$method" ]]; then
        abord "No method provided !" error
    fi

    log "Loading method '${method}'..." verbose

    if [[ ${METHODS[*]} =~ $method ]]; then
        # shellcheck source=./methods/${method}_method.sh
        # shellcheck disable=SC1091
        source "${ROOT_DIR}/methods/${method}_method.sh"

        if [[ $(type -t init_method) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'init_method' function"
        fi
        
        if [[ $(type -t get_available_space) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'get_available_space' function"
        fi

        if [[ $(type -t list_archives) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'list_archives' function"
        fi

        if [[ $(type -t count_archives) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'count_archives' function"
        fi

        if [[ $(type -t send_to_dest) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'send_to_dest' function"
        fi

        if [[ $(type -t delete_archive) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'delete_archive' function"
        fi

        if [[ $(type -t cleanup_method) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'cleanup_method' function"
        fi

        if [[ $(type -t usage_method) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'usage_method' function"
        fi

        if [[ $(type -t fetch_from_dest) != function ]]; then
            abord "Method file '${method}_method.sh' doesn't contain 'fetch_from_dest' function"
        fi
        
    else
        log "Unknown method '${method}'" error
        usage
        exit 1
    fi
}

### FUNCTION BEGIN
# Check if there is sufficent space on device to store archive
# Delete old archive if not
# ARGUMENTS: 
# 	$1 (integer) archive size (this size should be lower than available space on disk)
#   $2 (integer) min number of archives to keep.
# RETURN: 
# 	0 if thereis sufficent space to store archive size (after prune), 1 otherwise
### FUNCTION END
check_space_and_prune_old_archives() {
    local -A args_array=([s]=space=  [k]=keep=)
    local space=0
    local keep=0
    handle_getopts_args "$@"

    if echo "$space" | grep -qv "^[0-9][0-9]*$"; then
        abord "check_space_and_prune_old_archives : Archive size '$space' is not an integer"
    fi

    local availableSpace
    availableSpace=$(get_available_space)
    if echo "$availableSpace" | grep -qv "^[0-9][0-9]*$"; then
        abord "check_space_and_prune_old_archives : Cannot determine available space on destination ('$availableSpace' is not an integer)"
    fi
    if [[ $availableSpace -gt $space ]]; then
        return 0
    fi

    log "Not enough space on destination (available space = $(hrb "${availableSpace}")). Trying to make room..." "warning"

    local archives
    archives=$(list_archives olderfirst)
    
    for archive in $archives; do
        backupsCount=$(count_archives)
        if [[ $backupsCount -le $keep ]]; then
            log "Cannot delete more archives (number to keep = ${keep}, archives number = ${backupsCount})." "error"
            return 1
        fi

        log "Deleting archive ${archive}..."
        if ! delete_archive --name="$archive"; then
            log "Error deleting archive ${archive} !" "error"
            continue
        else
            log "Archive ${archive} deleted !"
        fi

        availableSpace=$(get_available_space)
        if [[ $availableSpace -gt $space ]]; then
            log "Enough space has been freed on the drive (available space = $(hrb "${availableSpace}"))" "success"
            return 0
        fi

        log "Not enough free space (available space  = $(hrb "${availableSpace}")). Continuing..."
    done


    log "Cannot make enough space on destination" "error"
    return 1
}

do_backup() {
    local -A args_array=([n]=name= [s]=source= [c]=compress= [k]=keep= [i]=info= [C]=check_size [h]=hook=)
    local name
    name=$(date "+%Y-%m-%d_%H-%M-%S")
    local source=""
    local compress=false
    local keep="all"
    local info=""
    local check_size=""
    local hook=""
    handle_getopts_args "${ARGS[@]}"

    # Check inputs
    if [[ -z $source ]]; then
        log "source is required" error
        usage
        exit 1
    fi

    source="${source%/}" # Clean trailing slash

    if [[ ! -f $source && ! -d $source ]]; then
        abord "Source '$source' is not a file, a directory or is not accessible"
    fi
    
    name=${name//./-}

    local tar_file="${TMP_DIR}/${name}.tar"
    local md5_content_file="${TMP_DIR}/${name}.content.md5"
    local md5_file="${TMP_DIR}/${name}.md5"
    local compress_cmd=""

    # Set default value for compress method
    if [[ $compress == false ]]; then
        compress=""
    elif [[ -z $compress ]]; then
        compress="gzip"
    fi
    
    if [[ -n $compress ]]; then
        case "$compress" in
        bzip2 | xz | gzip)
            compress_cmd="--${compress}"
            tar_file="${tar_file}.${compress}"
            ;;
        *)
            log "Unkown compress format '${compress}'" error
            exit 1
            ;;
        esac
    fi

    if [[ $keep != "all" && ! $keep =~ ^[0-9]+$ ]]; then
        log "Invalid keep value '${keep}'" error
        usage
        exit 1
    fi

    # Check if there is enough space to create archive file
    if [[ $check_size == '1' ]]; then
        log "Check source size ('${source}') according to available space in tmp dir ('${TMP_DIR}')..." verbose
        local source_size
        local available_space_in_temp
        source_size=$(du --bytes --total "$source" 2> /dev/null | tail --lines=1 | cut -f1)
        available_space_in_temp=$(findmnt --target "$source" --output AVAIL --bytes --noheadings --first-only)
        if [[ $source_size -gt $available_space_in_temp ]]; then
            abord "Not enough space to create temp archive (space neeeded = $(hrb "${source_size}") available space in temp = $(hrb "${available_space_in_temp}"))"
        fi
        log "OK source size = $(hrb "${source_size}") available space = $(hrb "${available_space_in_temp}")" verbose
    fi
    
    # Initialisation
    load_method "${METHOD}"
    init_method "${ARGS[@]}"

    # Use hook script
    if [[ -n "$hook" ]]; then
        init_hook "$hook" backup
    fi

    log "Start backup '$METHOD'" info
    log "args ${ARGS[*]}" verbose

    # Check info files and copy to tmp dir
    if [[ -n "$info" ]]; then
        log "Getting info files '$info'..." verbose
        OLD_IFS="$IFS"
        IFS=';' read -r -a info_files <<<"$info"
        IFS="$OLD_IFS"
        for file in "${info_files[@]}"; do
            file="${file#"${file%%[![:space:]]*}"}" # Trim leading spaces
            file="${file%"${file##*[![:space:]]}"}" # Trim trailing spaces

            log "Add info file '$file' to transfert"
            if [[ ! -f "$file" ]]; then
                abord "Info file '$file' doesn't exists or is inaccesible"
            fi

            local filename
            filename=$(basename "$file")
            local new_filename="${name}.${filename}"
            local dest_file_path="${TMP_DIR}/${new_filename}"

            if ! cp "$file" "${dest_file_path}"; then
                abord "Unable to copy info file '$file' to '$TMP_DIR'"
            fi

            FILES_TO_TRANSFERT+=("$dest_file_path")
            log "Info file '$file' copied to '${dest_file_path}'" verbose
        done
        
    fi

    # Create md5 content file
    log "Create md5 content sum file"
    find "${source}" -type f -exec md5sum {} \; | sed "s#${source}/##g" > "$md5_content_file"
    
    log "Add md5 content file '$md5_content_file' to transfert"
    FILES_TO_TRANSFERT+=("$md5_content_file")

    # Create tar archive
    log "Create archive file"
    
    local verbose=""
    [[ "${LOG_VERBOSE:-false}" == "true" ]] && verbose="--verbose"
    if ! log_cmd tar --create --file="${tar_file}" ${compress_cmd} ${verbose} --directory="${source}" .; then
        abord "Cannot create archive '${tar_file}' !"
    fi
    
    # Check compression
    if [[ -n $compress ]]; then
        if ! log_cmd "$compress" -t "${tar_file}"; then
            abord "Error creating archive ${tar_file}, file is corrupted !"
        fi
    fi

    log "Add archive file '${tar_file}' to transfert"
    FILES_TO_TRANSFERT+=("$tar_file")

    # Create md5 file
    log "Create md5 sum file"
    for file in "${FILES_TO_TRANSFERT[@]}"; do
        md5sum "$file" | sed "s#${TMP_DIR}/##" >> "$md5_file"
    done

    log "Add md5 file '$md5_file' to transfert"
    FILES_TO_TRANSFERT+=("$md5_file")

    # Check space and prune old archive if possible
    if [[ $keep != "all" ]]; then
        log "Check space and prune old archives..."
        local tar_size
        tar_size=$(du --byte "${tar_file}" | cut -f1)
        if ! check_space_and_prune_old_archives --space="$tar_size" --keep=$keep; then
            abord "We cannot proceed due to a lack of space in destination"
        fi
        log "There is enough space to store new archive" success
    fi

    # send archive
    log "Send archive files to repo..."
    if ! send_to_dest; then
        abord "Error while sending archive"
    fi

    log "Archive '$name' files sent" success
    
    cleanup
    log "End backup '$METHOD'" info
    return 0
}

do_delete() {
    local -A args_array=([n]=name=)
    local name=""
    handle_getopts_args "${ARGS[@]}"

    # Check inputs
    if [[ -z $name ]]; then
        log "name is required" error
        usage
        return 1
    fi

    # Initialisation
    load_method "$METHOD"
    init_method "${ARGS[@]}"
    
    local list
    list=$(list_archives)
    if ! echo "$list" | grep -q "$name"; then
        log "Archive '$name' not found'" warning
        cleanup
        return 0
    fi

    log "Delete archive '$name'..." info
    if ! delete_archive --name="$name"; then
        abord "Error while deleting archive '$name'"
    fi

    log "Archive '$name' deleted" success

    cleanup
    return 0
}

do_list() {
    local -A args_array=([s]=sort= [f]=full [h]=human_readable)
    local sort=false
    local full=false
    local human_readable=false
    handle_getopts_args "${ARGS[@]}"

    # Check inputs
    if [[ $sort != false ]]; then
        case $sort in
        olderfirst | o)
            sort="olderfirst"
            ;;
        newerfirst | n)
            sort="newerfirst"
            ;;
        *)
            abord "unkown sort order '$sort'"
            ;;
        esac
    fi

    # Convert input flags to true/false values
    if [[ $full == "1" ]]; then
        full=true
    elif [[ $full == "0" ]]; then
        full=false
    fi

    if [[ $human_readable == "1" ]]; then
        human_readable=true
    elif [[ $human_readable == "0" ]]; then
        human_readable=false
    fi

    # Initialisation
    load_method "$METHOD"
    init_method "${ARGS[@]}"

    # Ensure that cleanup is called on exit
    if ! list_archives "$sort" "$full" "$human_readable"; then
        log "No archives on remote" warning
    fi

    cleanup
    return 0
}

do_help() {
    usage
    if [[ -n $METHOD ]]; then
        load_method "$METHOD"
        usage_method
        cleanup
    fi
    exit 0
}

do_version() {
    echo "yuno-archive version : ${VERSION}"
    cleanup
    exit 0
}

do_restore() {
    local -A args_array=([n]=name= [D]=destination= [h]=hook=)
    local name=""
    local destination=""
    local hook=""

    handle_getopts_args "${ARGS[@]}"
    
    # Check inputs
    if [[ -z $name ]]; then
        log "name is required" error
        usage
        return 1
    fi

    if [[ -z $destination ]]; then
        log "destination is required" error
        usage
        return 1
    fi

    if [[ ! -d $destination ]]; then
        abord "destination '$destination' is not a directory or is not accessible"
    fi
    
    # Initialisation
    load_method "$METHOD"
    init_method "${ARGS[@]}"

    # Use hook script
    if [[ -n "$hook" ]]; then
        init_hook "$hook" restore
    fi

    local list
    list=$(list_archives)
    if ! echo "$list" | grep -q "$name"; then
        abord "Archive '$name' not found"
    fi

    log "Fetching archive..." info
    if ! fetch_from_dest --name="$name" --destination="$TMP_DIR"; then
        abord "Error while fetching archive"
    fi
    log "archive fetched" success

    log "Check archive..." info
    local actual_path
    actual_path=$(pwd)
    local md5_file="${name}.md5"
    cd "${TMP_DIR}"
    if ! log_cmd md5sum --check "$md5_file"; then
        abord "Archive check failed, files are corrupted"
    fi
    log "Archive checked " success
    cd "$actual_path"

    
    local verbose=""
    [[ "${LOG_VERBOSE:-false}" == "true" ]] && verbose="--verbose"

    for tar_file in "$TMP_DIR/${name}".tar*; do
        [[ -e "$tar_file" ]] || continue
        log "Restore archive file '${tar_file}..." info
        if ! log_cmd tar --extract --file="${tar_file}" --auto-compress ${verbose} --directory="${destination}" .; then
            abord "Cannot restore archive '${tar_file}' !"
        fi
        log "Archive file '${tar_file} restored" success
    done

    log "Checking extracted files..." info
    local md5_content_file="${TMP_DIR}/${name}.content.md5"
    cd "${destination}"
    if ! log_cmd md5sum --check "$md5_content_file"; then
        abord "Restored files check failed, files are corrupted"
    fi
    log "Restored files checked" success

    cleanup
    return 0
}

do_send() {
    local -A args_array=([s]=source=)
    local source=""

    handle_getopts_args "${ARGS[@]}"
    
   # Check inputs
    if [[ -z $source ]]; then
        log "source is required" error
        usage
        exit 1
    fi

    source="${source%/}" # Clean trailing slash

    if [[ ! -f $source && ! -d $source ]]; then
        abord "Source '$source' is not a file, a directory or is not accessible"
    fi
    
    # Initialisation
    load_method "${METHOD}"
    init_method "${ARGS[@]}"

    log "Start sending '$METHOD'" info
    log "args ${ARGS[*]}" verbose

    declare -a local_archives
    mapfile -t local_archives < <( ${BASH_SOURCE[0]} list local --sort=newerfirst --repository="${source}" --full | tail --lines=+2)
    if [[ ${#local_archives[@]} -eq 0 ]]; then
        log "No local archives found in '${source}'" warning
        cleanup
        return 0
    fi
    log "Found ${#local_archives[@]} local archives in '${source}'"

    declare -a remote_archives
    mapfile -t remote_archives < <( list_archives olderfirst )
    log "Found ${#remote_archives[@]} remote archives in destination repository"

    declare -a archives_to_send=()

    for archive in "${local_archives[@]}"; do
        name=$( echo  "${archive}" | cut -f1 )
        size=$( echo  "${archive}" | cut -f2 )
        
        # We stop if local archive exists on remote
        if  [[ " ${remote_archives[*]} " =~ " ${name} " ]]; then
            break;
        fi

        archives_to_send+=("${name}\t${size}")
    done

    # log "Archives to send:\n $( printf '%s\n' "${my_array[@]} )" verbose

    if [[ ${#archives_to_send[@]} -eq 0 ]]; then
        log "No archives to send" warning
        cleanup
        return 0
    fi

    local keep=0
    local cannot_send=false

    for archive in "${archives_to_send[@]}"; do
        name=$( echo -e "${archive}" | cut -f1 )
        size=$( echo -e "${archive}" | cut -f2 )
        
        # We stop if local archive exists on remote
        if  [[ " ${remote_archives[*]} " =~ " ${name} " ]]; then
            break;
        fi

        log "Check space and prune old archives..."
        if ! check_space_and_prune_old_archives --space="$size" --keep=$keep; then
            cannot_send=true
            log "We cannot proceed due to a lack of space in destination" warning
            # We continue because we want to send as much as possible archives
            continue
        fi
        log "There is enough space to store new archive" success

        log "Sending archive '$name' to remote..."
        mapfile -t FILES_TO_TRANSFERT < <(find "${source}" -maxdepth 1 -type f -name "${name}.*")
        
        if ! send_to_dest; then
            log "Error while sending archive" error
            cannot_send=true
            continue
        fi
        log "Archive '${name}' sent" success

        keep=$((keep + 1))
    done

    log "End sending '$METHOD' number archives sent = ${keep}" info
    cleanup

    if $cannot_send; then
        log "Some archives were not sent" warning
        return 1
    else
        log "All archives sent successfully" success
        return 0
    fi
}

###############################################################################
#                                     MAIN                                    #
###############################################################################

# Check TMP DIR
if [[ ! -d "$YARCH_TMPDIR" ]]; then
    abord "Temp dir '${YARCH_TMPDIR}' inaccessible or inexistent"
fi

declare TMP_DIR
TMP_DIR=$(mktemp --directory --tmpdir="$YARCH_TMPDIR")
declare -r TMP_DIR

# Get action parameter
if [[ $# -ge 1 ]]; then
    declare -r ACTION="$1"
    shift
else
    log "Action is required." error
    cleanup
    usage
    exit 1
fi

# Get method parameter (optionnal)
if [[ $# -ge 1 ]]; then
    declare -r METHOD="$1"
    shift
else
    declare -r METHOD=""
fi

declare -ra ARGS=("$@")

# Trap interruption to quit properly
trap handle_sigterm_sigint INT TERM

log_init "$@"

case $ACTION in

backup)
    do_backup
    ;;
delete)
    do_delete
    ;;
help)
    do_help "$METHOD"
    ;;
list)
    do_list
    ;;

restore)
    do_restore
    ;;

send)
    do_send
    ;;

version)
    do_version
    ;;

*)
    log "Unkown action '$ACTION'" error
    cleanup
    usage
    exit 1
    ;;
esac
