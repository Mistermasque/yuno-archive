#!/usr/bin/env bash

source ./helpers/helpers 2

###############################################################################
#                             INIT GLOBAL VARS                                #
###############################################################################
# Script dir
declare -r ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
# Available methods
declare -a METHODS
mapfile -t METHODS < <(ls "$ROOT_DIR/methods" | grep "_method.sh*" | sed 's/_method.sh//g')
declare -r METHODS
# Get action parameter
declare -r ACTION="$1"
shift
# Get args for ACTION
declare -r METHOD_REGEX=$(echo "${METHODS[*]}" | sed 's/ /|/g')
declare -r ACTION_ARGS=$(echo "$@" |  sed -E "s/(${METHOD_REGEX}).*//")
# Get Method called NB : this could be inexistent if method is not correctly written
declare -r METHOD=$(echo "$@" |  sed -E "s/.*(${METHOD_REGEX}).*/\1/")
# Get args for Method
declare -r METHOD_ARGS=$(echo "$@" |  sed -E "s/.*(${METHOD_REGEX})//")

###############################################################################
#                             SCRIPT FUNCTIONS                                #
###############################################################################

usage() {
    cat << USAGE
Script used to create an archive in tar format from dir and send it to a repo.
The destination repo depends on method used

Usage  :
   $(basename $0) <Action> [Action options] <Method> [Method options]

<Action> :
   backup : backup a dir to a repo
   delete : delete a backup on repo
   help : print help message. If you want help for a method type help <Method>
   list : list available backups on repo   
   restore : restore a backup

<Method> : method to used to send archive. Available methods are :
$(echo ${METHODS[@]} )

Options :
   General options :
      -l |--log=<log file> : send messages to <log file>
      -q |--quiet : do not print messages on stdout/stderr
      -v |--verbose : be more verbose

   Backup action options :
      -c |--compress=<type> : compress archive before send it <type> can be : gzip|bz2
      -C |--crypt : crypt archive before send it. You need to define a passphrase
      -n |--name=<archive name> : archive name. If not set, use datetime
      -p |--passphrase=<passphrase> : mandatory if crypt is set
      -s |--source=<dir> : (mandatory) source dir or files to backup. Can be values separated with comma for multiple dirs/files
      -k |--keep=all|<number to keep> : (default: all) how many exisiting backup do you want to keep if thereis not enough space on dest (all: do not prune old archives, 0 can prune all archives if necessary)

   List action options :
      -s |--sort=<sort order> : sort backup list. <sort order> can be : olderfirst|newerfirst
   
   Restore action options :
      -d |--destination=<dir> : (mandatory) destination dir to restore archive
      -n |--name=<archive name> : (mandatory> archive name to restore

USAGE
}

load_method() {

    if [[ -z $METHOD ]]; then
        log "No method provided !" error
        exit 2
    fi

    local method="$1"
    
    log "Loading method '${method}'..." verbose
    
    if [[ ${METHODS[@]} =~ $method ]]; then
        source "${ROOT_DIR}/methods/${method}_method.sh"

        if [[ $(type -t list_archives) != function ]]; then
            log "Method file '${method}_method.sh' doesn't contain 'list_archives' function" error
            exit 127
        fi

        if [[ $(type -t getRemoteInfo) != function ]]; then
            msg "Le fichier de méthode '${method}_method.sh' ne contient pas la fonction 'getRemoteInfo'" 'error'
            exit 127
        fi
        
        if [[ $(type -t backupToDest) != function ]]; then
            msg "Le fichier de méthode '${method}_method.sh' ne contient pas la fonction 'backupToDest'" 'error'
            exit 127
        fi

        if [[ $(type -t prepare_dest) != function ]]; then
            log "Method file '${method}_method.sh' doesn't contain 'prepare_dest' function" error
            exit 127
        fi

        if [[ $(type -t cleanup_dest) != function ]]; then
            log "Method file '${method}_method.sh' doesn't contain 'cleanup_dest' function" error
            exit 127
        fi
    else
        msg "Unknown method '${method}'" error
        usage
        exit 1
    fi

    METHOD="$method"
}


do_backup() {
    local -A args_array=( [n]=name= [s]=source= [c]=compress=  )
    local name
    local source
    local compress
    local crypt
    local passphrase
    local keep

    ynh_handle_getopts_args "$ACTION_ARGS"
   
   
    # Create tar archive
    if ! tar czf "${archiveFile}" * >> "$YEB_LOG_FILE" 2>&1; then
        yeb_log "Error creating archive ${archiveFile} !" "error"
        return 
    # Compress if needed

    # crypt if needed

    # Check space and prune old archive if possible
    # - list_archives
    # - get_available_space
    # - delete_archive

    # send archive
    send_archive --name=$name --archive=$archive --info=$info --md5=$md5 $METHOD_ARGS
}

do_delete() {
    delete_archive --name=$name
}

do_list() {
    list_archives --sort=$sort
}

do_help() {
    if [[ -n $METHOD ]]; then
        load_method $METHOD
        usage_method
        exit 0
    fi

    usage
    exit 0
}

do_restore() {

}

###############################################################################
#                                     MAIN                                    #
###############################################################################

log_init $ACTION_ARGS

case $ACTION in

    backup)
    do_backup
    ;;
    delete)
    echo -n "Italian"
    ;;
    help)
    do_help
    ;;
  list)
    echo -n "Romanian"
    ;;

  restore)
    echo -n "Italian"
    ;;

  *)
    echo -n "unknown"
    ;;
esac

