#! /bin/bash

. ./common.sh
. ./restore_master.sh
. ./restore_minion.sh

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
        REMOTE_IP=$( get_ip_from_hostname $REMOTE_HOST )
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

    if [ "$ERROR" == "1" ]
    then
        echo "$usage"
        exit 1
    fi
}

parse_input $@
validate_input

exec > >(tee >(sed -u -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g' > $LOCAL_BACKUP_DIR/restore.log))
exec 2>&1

extract_configs_from_backup
if [ $ClusterMembership != "Slave" ]
then
    # ************************************************************************************************#
    # **************************** Open the connection to the new vm *********************************#
    # ************************************************************************************************#
    color_echo "-------- Master configuration is found in the backup path ---------------------------"
    color_echo "-------- Connecting to the remote machine -------------------------------------------"
    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $MASTER_SSH_KEY
    remote_conn=$last_conn
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Copying backup files to the remote server *************************#
    # ************************************************************************************************#
    copy_backup_to_remote $remote_conn

    # ************************************************************************************************#
    # **************************** Installing CB Server if needed ************************************#
    # ************************************************************************************************#
    if [ ! $( remote_exec $remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        install_master $remote_conn
    fi

    # ************************************************************************************************#
    # **************************** Stopping CB server if needed **************************************#
    # ************************************************************************************************#
    command=/usr/share/cb/cbcluster
    echo
    color_echo "-------- CB Server is installed on the remote machine -------------------------------"
    if [ $ClusterMembership == "Standalone" ]
    then
        command="service cb-enterprise"
        color_echo "-------- Remote machine is in standalone mode ---------------------------------------"
    else
        color_echo "-------- Remote machine is in cluster mode ------------------------------------------"
    fi
    echo
    color_echo "-------- Stopping CB Server on the remote machine -----------------------------------"
    remote_exec $remote_conn "$command stop"
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Stopping iptables *************************************************#
    # ************************************************************************************************#
    echo
    color_echo "-------- Stopping iptables ----------------------------------------------------------"
    remote_exec $remote_conn "service iptables stop"
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Extracting backup files *******************************************#
    # ************************************************************************************************#
    extract_backup $remote_conn

    # ************************************************************************************************#
    # **************************** Generating new server token ***************************************#
    # ************************************************************************************************#
    regenerate_server_token $remote_conn

    # ************************************************************************************************#
    # **************************** Re-init the database **********************************************#
    # ************************************************************************************************#
    re_init_db $remote_conn

    ret_val=$( read_cluster_config "Master" )
    OLD_HOST=$( get_tail_element "$ret_val" '|' 3 )
    NEW_HOST=$REMOTE_HOST

    # ************************************************************************************************#
    # **************************** Updating master with new master information ***********************#
    # ************************************************************************************************#
    echo
    color_echo "-------- Updating master configs to have new master address -------------------------"
    udpate_remote_server $remote_conn $OLD_HOST $NEW_HOST
    color_echo "--- Done"
    echo

    # ************************************************************************************************#
    # **************************** Removing shards on the new master that are not in the config ******#
    # ************************************************************************************************#
    remove_shards $remote_conn

    # ************************************************************************************************#
    # **************************** Starting iptables service *****************************************#
    # ************************************************************************************************#
    echo
    color_echo "-------- Starting iptables service --------------------------------------------------"
    remote_exec $remote_conn "service iptables start"
    color_echo "--- Done"


    # ************************************************************************************************#
    # **************************** Updating slaves with new master information ***********************#
    # ************************************************************************************************#
    if [ $ClusterMembership == "Master" ]
    then
        echo
        color_echo "-------- Updating all slaves to have new master address -----------------------------"

        # ********************************************************************************************#
        # **************************** Copying erlang.cookie from the master *************************#
        # ********************************************************************************************#
        remote_copy $remote_conn "/var/cb/.erlang.cookie" "$LOCAL_BACKUP_DIR/" 1

        # ********************************************************************************************#
        # **************************** Copying cluster.conf ******************************************#
        # ********************************************************************************************#
        remote_copy $remote_conn "/etc/cb/cluster.conf" "$LOCAL_BACKUP_DIR/" 1

        # ************************ extracting ssh key for accessing slaves ***************************#
        slave_ssh_key="$LOCAL_BACKUP_DIR/cb_ssh"
        tar xf $LOCAL_BACKUP_DIR/cbconfig.tar -P -C $LOCAL_BACKUP_DIR/ /etc/cb/cb_ssh --strip-components 2
        chmod 0400 $slave_ssh_key
        # ********************************************************************************************#

        update_all_slaves_with_new_master $OLD_HOST $NEW_HOST $slave_ssh_key
        color_echo "--- Done"
        echo
    fi

    # ************************************************************************************************#
    # **************************** Starting cluster or just the server *******************************#
    # ************************************************************************************************#
    color_echo "-------- Starting CB Server on the remote machine -----------------------------------"
    remote_exec $remote_conn "$command start"
    color_echo "--- Done"
    echo

    # ************************************************************************************************#
    # **************************** Cleaning up temp files and closing the connection *****************#
    # ************************************************************************************************#
    cleanup_tmp_files
    close_ssh_tunnel $remote_conn
    # ************************************************************************************************#

    echo
    color_echo "-------- Master node is succesfully restored ----------------------------------------"
    echo
else
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Slave configuration is found in the backup path"
    color_echo "--------------------------------------------------------------------------------------"
    echo

    # ************************************************************************************************#
    # **************************** Getting slave node from the backup ********************************#
    # ************************************************************************************************#
    color_echo "-------- Getting slave information from the backup -----------------------------------"
    slave_host=$( parse_slave_host_from_backup "$LOCAL_BACKUP_DIR" )
    ret_val=$( read_cluster_config "Slave*" "Host" $slave_host )
    slave_shards=$(get_tail_element "$ret_val" '|' 1)
    slave_shards=$(sed -r 's/shards(=|\s)//g' <<< "$slave_shards")
    slave_name=$( get_tail_element "$ret_val" '|' 4 )
    slave_node_id=$( get_tail_element "$ret_val" '|' 5 )

    # ************************************************************************************************#
    # **************************** Getting master node information from the backup *******************#
    # ************************************************************************************************#
    color_echo "-------- Getting master information --------------------------------------------------"
    ret_val=$( read_cluster_config "Master" )
    MASTER_HOST=$( get_tail_element "$ret_val" '|' 3 )
    MASTER_USER=$( get_tail_element "$ret_val" '|' 2 )
    MASTER_BACKUPDIR="$(dirname $LOCAL_BACKUP_DIR)/$MASTER_HOST"
    color_echo "--- Done"

    echo
    # ************************************************************************************************#
    # **************************** Connecting to the master node *************************************#
    # ************************************************************************************************#
    color_echo "-------- Connecting to the master [\e[0m$MASTER_HOST\e[1;32m] ---------------------------------------"
    open_ssh_tunnel $MASTER_USER $MASTER_HOST $MASTER_SSH_KEY
    master_conn=$last_conn

    # ************************************************************************************************#
    # **************************** Opening the connection to the remote host using slave_ssh_key *****#
    # ************************************************************************************************#
    color_echo "-------- Connecting to the new node [\e[0m$REMOTE_HOST\e[1;32m] -------------------------------------"
    slave_ssh_key="$LOCAL_BACKUP_DIR/cb_ssh"
    if [  -f $MASTER_BACKUPDIR/cbconfig.tar ];
    then
        tar xf $MASTER_BACKUPDIR/cbconfig.tar -P -C $LOCAL_BACKUP_DIR/ /etc/cb/cb_ssh --strip-components 2
    fi

    if [ ! -f $slave_ssh_key ]
    then
        color_echo "-------- SSH Key is not present in the backup. Getting it from the master ---------"
        remote_copy $master_conn "/etc/cb/cb_ssh" "$LOCAL_BACKUP_DIR/" 1
    else
        chmod 0400 $slave_ssh_key
    fi

    if [ $(ssh -q -o "BatchMode yes" $REMOTE_USER@$REMOTE_HOST -i $slave_ssh_key "echo 1 && exit " || echo "0") == "0" ];
    then
        color_echo "-------- SSH Key is not yet authorized on the remote machine. Copying the key. -------"
        remote_copy $master_conn "/etc/cb/cb_ssh.pub" "$LOCAL_BACKUP_DIR/" 1
        ssh-copy-id -i "$slave_ssh_key.pub" $REMOTE_USER@$REMOTE_HOST
    fi

    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $slave_ssh_key
    remote_conn=$last_conn
    color_echo "--- Done"

    echo
    # ************************************************************************************************#
    # **************************** Stopping the cluster **********************************************#
    # ************************************************************************************************#
    color_echo "-------- Stopping the cluster --------------------------------------------------------"
    remote_exec $master_conn "/usr/share/cb/cbcluster stop"
    color_echo "--- Done"

    echo
    # ************************************************************************************************#
    # **************************** Copying backup files to the remote machine ************************#
    # ************************************************************************************************#
    color_echo "-------- Copying the backup to the remote machine -------------------------------------"
    remote_exec $remote_conn "mkdir -p $REMOTE_RESTORE_DIR"
    remote_copy $remote_conn "$LOCAL_BACKUP_DIR/*" "$REMOTE_RESTORE_DIR" 0 -r
    color_echo "--- Done"

    echo
    # ************************************************************************************************#
    # **************************** Installing new cb-enterprise if needed ****************************#
    # ************************************************************************************************#
    install_cb_enterprise $remote_conn "$REMOTE_RESTORE_DIR"

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "CB Server is installed on the remote machine "
    color_echo "--------------------------------------------------------------------------------------"

    echo
    # ************************************************************************************************#
    # **************************** Initializing slave node *******************************************#
    # ************************************************************************************************#
    color_echo "-------- Initializing CB Server in slave node ----------------------------------------"
    # ************************************************************************************************#
    # **************************** Generating config file for slave node to use for init *************#
    # ************************************************************************************************#
    generate_init_conf $master_conn $remote_conn "$LOCAL_BACKUP_DIR" "$REMOTE_RESTORE_DIR"
    init_slave_node $master_conn $remote_conn "$LOCAL_BACKUP_DIR" "$REMOTE_RESTORE_DIR" "$slave_host" "$REMOTE_HOST" $slave_node_id
    color_echo "--- Done"

    echo
    # ************************************************************************************************#
    # **************************** Restoring backup files ********************************************#
    # ************************************************************************************************#
    color_echo "-------- Restoring backup files on the remote slave ----------------------------------"
    restore_slave_backup $remote_conn
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Regenerating server token *****************************************#
    # ************************************************************************************************#
    regenerate_server_token $remote_conn

    echo
    # ************************************************************************************************#
    # **************************** Updating master with new slave node information *******************#
    # ************************************************************************************************#
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Updating MASTER [\e[0m$MASTER_HOST\e[1;32m] with new slave information "
    color_echo "--------------------------------------------------------------------------------------"
    update_master_with_new_slave "$master_conn" "$LOCAL_BACKUP_DIR" "$slave_host" $slave_node_id "$REMOTE_HOST"
    color_echo "--- Done"

    echo
    echo
    # ************************************************************************************************#
    # **************************** Updating slaves with new slave node information *******************#
    # ************************************************************************************************#
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Updating \e[0mALL SLAVES\e[1;32m with new slave information "
    color_echo "--------------------------------------------------------------------------------------"
    update_all_slaves_with_new_slave $master_conn $LOCAL_BACKUP_DIR $slave_ssh_key $slave_host $REMOTE_HOST $SAVE_HOSTS

    echo
    # ************************************************************************************************#
    # **************************** Starting the cluster again ****************************************#
    # ************************************************************************************************#
    color_echo "-------- Starting the cluster --------------------------------------------------------"
    remote_exec $master_conn "/usr/share/cb/cbcluster start"
    color_echo "--- Done"

    cleanup_tmp_files
    close_ssh_tunnel $remote_conn
    close_ssh_tunnel $master_conn
fi





