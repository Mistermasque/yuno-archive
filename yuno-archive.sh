#!/usr/bin/env bash
# Fail on error
set -Eeuo pipefail

###############################################################################
#                             INIT GLOBAL VARS                                #
###############################################################################
# Script dir
declare ROOT_DIR
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
declare -r ROOT_DIR
# Available methods
declare -a METHODS
mapfile -t METHODS < <(find "$ROOT_DIR/methods" -maxdepth 1 -name "*_method.sh" -type f -printf '%f\n' | sed 's/_method.sh//g')
declare -r METHODS

# shellcheck disable=SC2155
declare -r TMP_DIR=$(mktemp -d)

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
   backup : backup a dir to a repo
   delete : delete a backup on repo
   help : print help message. If you want help for a method type help <Method>
   list : list available backups on repo   
   restore : restore a backup

<Method> : method to used to send archive. Available methods are :
$(for method in "${METHODS[@]}"; do
    echo "   - $method"
done)

Options :
   General options :
      -l |--log=<log file> : send messages to <log file>
      -q |--quiet : do not print messages on stdout/stderr
      -v |--verbose : be more verbose

   Backup action options :
      -c |--compress=<type> : compress archive before send it <type> can be : gzip|bzip2|xz
      -i |--info=<info file> : Additionnal file to send with archive (sent unaltered). Possibility to add multiple files separated by spaces
      -n |--name=<archive name> : archive name. If not set, use datetime
      -s |--source=<dir> : (mandatory) source dir or files to backup.
      -k |--keep=all|<number to keep> : (default: all) how many exisiting backup do you want to keep if thereis not enough space on dest (all: do not prune old archives, 0 can prune all archives if necessary)

   List action options :
      -s |--sort=<sort order> : sort backup list. <sort order> can be : olderfirt|o for older first, n|newerfirst for newer first
   
   Restore action options :
      -d |--destination=<dir> : (mandatory) destination dir to restore archive
      -n |--name=<archive name> : (mandatory) archive name to restore

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
    if [[ $availableSpace -gt $space ]]; then
        return 0
    fi

    log "Not enough space on disk (available space = $(hrb "${availableSpace}"). Trying to make room..." "warning"

    local archives
    archives=$(list_archives --sort=olderFirst)
    
    for archive in $archives; do
        backupsCount=$(count_archives)
        if [[ $backupsCount -le $keep ]]; then
            log "Cannot delete more archives (number to keep = $keep, archives number = $backupsCount)." "error"
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

        log "Not enough free space (available space  = $(hrb "${availableSpace}"). Continuing..."
    done


    log "Cannot make enough space on disk" "error"
    return 1
}


do_backup() {
    local -A args_array=([n]=name= [s]=source= [c]=compress= [k]=keep= [i]=info=)
    local name
    name=$(date "+%Y-%m-%d_%H-%M-%S")
    local source=""
    local compress=""
    local keep="all"
    local info=""
    handle_getopts_args "${ARGS[@]}"

    # Check inputs
    if [[ -z $source ]]; then
        log "source is required" error
        usage
        exit 1
    fi

    source="${source%/}" # Clean trailing slash

    if [[ ! -f $source && ! -d $source ]]; then
        abord "source '$source' is not a file, a directory or is not accessible"
    fi
    
    name=${name//./-}

    local tar_file="${TMP_DIR}/${name}.tar"
    local md5_content_file="${TMP_DIR}/${name}.content.md5"
    local md5_file="${TMP_DIR}/${name}.md5"
    local compress_cmd=""

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

    # Initialisation
    load_method "$METHOD"
    init_method "${ARGS[@]}"

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
            abord "Not enough space"
        fi
        log "There is enough space to store new archive" success
    fi

    # send archive
    log "Send archive files to repo..."
    if ! send_to_dest --name="$name" --archive="$tar_file" --md5="$md5_content_file"; then
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
    local -A args_array=([s]=sort=)
    local sort=""
    handle_getopts_args "${ARGS[@]}"

    # Initialisation
    load_method "$METHOD"
    init_method "${ARGS[@]}"

    list_archives --sort="$sort"
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

do_restore() {
    local -A args_array=([n]=name= [d]=destination=)
    local name=""
    local destination=""

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

###############################################################################
#                                     MAIN                                    #
###############################################################################

# Check TMP DIR
if [[ ! -d "$TMP_DIR" ]]; then
    abord "Temp dir '${TMP_DIR}' inaccessible or inexistent"
fi

# Get action parameter
if [[ $# -ge 1 ]]; then
    declare -r ACTION="$1"
    shift
else
    log "Action is required." error
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

*)
    abord "Unkown action '$ACTION'"
    ;;
esac
