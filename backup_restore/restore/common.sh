#! /bin/bash

usage="$(basename "$0") [-h help] | -r host -u user -b path [-k key]

where:
    -r, --remote        Ip address or the hostname of the remote server to restore the backup on
    -u, --user          User to use for remote server connection
    -b, --backup        Folder path with backup for restore
    -k, --key           Optional. ssh key that can be used to connect to the remote server
    -s, --save-hosts    Optional. Save new (ipaddress, hostname) entry to the hosts file on all nodes in the cluster
                        Only needed if previous setup did not have host entries for cluster nodes in the hosts file
"

parse_input() {
    while [[ $# > 1 ]]
    do
    key="$1"

    case $key in
        h)
        echo "$usage"
        exit
        ;;
        -r|--remote)
        REMOTE_HOST="$2"
        REMOTE_IP=$( resolve_hostname $REMOTE_HOST )
        shift # past argument
        ;;
        -u|--user)
        REMOTE_USER="$2"
        shift # past argument
        ;;
        -b|--backupdir)
        LOCAL_BACKUP_DIR=$(sed 's/\/$//' <<< "$2")
        shift # past argument
        ;;
        -k|--key)
        MASTER_SSH_KEY="$2"
        shift # past argument
        ;;
        -s|--save-hosts)
        SAVE_HOSTS=1
        shift # past argument
        ;;
        --default)
        DEFAULT=YES
        shift # past argument with no value
        ;;
        *)
                # unknown option
        ;;
    esac
    shift
    done
}

validate_input() {
    ERROR=0
    if [ -z "$REMOTE_HOST" ]
    then
        color_echo "Remote server address must be provided" "1;31"
        ERROR=1
    fi

    if [ -z "$REMOTE_USER" ]
    then
        color_echo "Remote user name must be provided" "1;31"
        ERROR=1
    fi

    if [ -z "$LOCAL_BACKUP_DIR" ]
    then
        color_echo "PATH to the backup files must be provided" "1;31"
        ERROR=1
    fi

    is_host_resolvable $REMOTE_HOST
    if [ $? != 0 ]
    then
        color_echo "Remote host is not resolvable" "1;31"
        ERROR=1
    fi

    is_host_reachable $REMOTE_USER $REMOTE_HOST
    if [ $? != 0 ]
    then
        color_echo "Remote host is not reachable via ssh" "1;31"
        ERROR=1
    fi

    path_contains_backup $LOCAL_BACKUP_DIR
    if [ $? != 0 ]
    then
        color_echo "Provided path doesn't contain backup files" "1;31"
        ERROR=1
    fi

    if [ $ERROR != 0 ]
    then
        echo "$usage"
        exit 1
    fi
}
