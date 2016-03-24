#! /bin/bash

. ./common/common.sh
. ./restore/common.sh
. ./restore/restore_master.sh
. ./restore/restore_minion.sh

parse_input $@
validate_input

LOG_FILE="$LOCAL_BACKUP_DIR/restore_$DATE.log"

exec > >(tee >(sed -u -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g' > $LOG_FILE))
exec 2>&1

color_echo "Backup folder: $LOCAL_BACKUP_DIR/" "1;33"
color_echo "Log File: $LOG_FILE" "1;33"

extract_configs_from_backup

# ************************************************************************************************#
# **************************** $ClusterMembership Configuration is found *************************#
# ************************************************************************************************#
color_echo "--------------------------------------------------------------------------------------"
color_echo "$ClusterMembership configuration is found in the backup"
color_echo "--------------------------------------------------------------------------------------"

if [ $ClusterMembership != "Slave" ]
then
    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Restoring \e[0mMASTER\e[1;32m on the new server [\e[0m$REMOTE_HOST\e[1;32m]"
    color_echo "--------------------------------------------------------------------------------------"

    # ************************************************************************************************#
    # **************************** Open the connection to the new vm *********************************#
    # ************************************************************************************************#
    color_echo "-------- Connecting to the new server [\e[0m$REMOTE_USER@$REMOTE_HOST\e[1;32m]"
    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $MASTER_SSH_KEY
    exit_if_error $? "-------- Could not connect to the $REMOTE_USER@$REMOTE_HOST"
    remote_conn=$last_conn

    check_host_time $remote_conn
    exit_if_error $? "-------- Time on the remote server [\e[0m$REMOTE_HOST\e[1;31m] is not synced. Try to sync time first."

    # ************************************************************************************************#
    # **************************** Copying backup files to the remote server *************************#
    # ************************************************************************************************#
    copy_backup_to_remote $remote_conn
    exit_if_error $? "-------- Could not copy the backup to the $REMOTE_USER@$REMOTE_HOST"

    # ************************************************************************************************#
    # **************************** Installing CB Server if needed ************************************#
    # ************************************************************************************************#
    color_echo "-------- Checking if CB Server is installed"
    if [ ! $( remote_exec_get_output $remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        install_master $remote_conn
    fi

    if [ ! $( remote_exec_get_output $remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        exit_if_error 1 "-------- Something went wrong during CB Server installation"
    fi

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "CB Server is installed on the remote machine "
    color_echo "--------------------------------------------------------------------------------------"

    # ************************************************************************************************#
    # **************************** Stopping CB server if needed **************************************#
    # ************************************************************************************************#
    command=/usr/share/cb/cbcluster
    if [ $ClusterMembership == "Standalone" ]
    then
        command="service cb-enterprise"
    fi
    color_echo "-------- Stopping CB Server on the remote machine"
    remote_exec $remote_conn "$command stop"

    # ************************************************************************************************#
    # **************************** Stopping iptables *************************************************#
    # ************************************************************************************************#
    color_echo "-------- Stopping iptables"
    remote_exec $remote_conn "service iptables stop"

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
    color_echo "-------- Updating master configs to have new master address"
    udpate_remote_server $remote_conn $OLD_HOST $NEW_HOST

    # ************************************************************************************************#
    # **************************** Removing shards on the new master that are not in the config ******#
    # ************************************************************************************************#
    remove_shards $remote_conn

    # ************************************************************************************************#
    # **************************** Starting iptables service *****************************************#
    # ************************************************************************************************#
    color_echo "-------- Starting iptables service"
    remote_exec $remote_conn "service iptables start"

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Restore of the MASTER is done"
    color_echo "--------------------------------------------------------------------------------------"

    # ************************************************************************************************#
    # **************************** Updating slaves with new master information ***********************#
    # ************************************************************************************************#
    if [ $ClusterMembership == "Master" ]
    then
        echo
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Updating \e[0mALL SLAVES\e[1;32m with new master"
        color_echo "--------------------------------------------------------------------------------------"

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
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Update of ALL SLAVES is done"
        color_echo "--------------------------------------------------------------------------------------"
    fi

    echo
    # ************************************************************************************************#
    # **************************** Starting cluster or just the server *******************************#
    # ************************************************************************************************#
    color_echo "-------- Starting CB Server on the remote machine"
    remote_exec $remote_conn "$command start"
    echo

    # ************************************************************************************************#
    # **************************** Cleaning up temp files and closing the connection *****************#
    # ************************************************************************************************#
    cleanup_tmp_files
    close_ssh_tunnel $remote_conn
    # ************************************************************************************************#
else
    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Restoring \e[0mSLAVE\e[1;32m on the new server [\e[0m$REMOTE_HOST\e[1;32m]"
    color_echo "--------------------------------------------------------------------------------------"

    # ************************************************************************************************#
    # **************************** Getting slave node from the backup ********************************#
    # ************************************************************************************************#
    color_echo "-------- Getting slave information from the backup"
    slave_host=$( parse_slave_host_from_backup "$LOCAL_BACKUP_DIR" )
    ret_val=$( read_cluster_config "Slave*" "Host" $slave_host )
    slave_shards=$(get_tail_element "$ret_val" '|' 1)
    slave_user=$(get_tail_element "$ret_val" '|' 2)
    slave_shards=$(sed -r 's/shards(=|\s)//g' <<< "$slave_shards")
    slave_name=$( get_tail_element "$ret_val" '|' 4 )
    slave_node_id=$( get_tail_element "$ret_val" '|' 5 )

    # ************************************************************************************************#
    # **************************** Getting master node information from the backup *******************#
    # ************************************************************************************************#
    color_echo "-------- Getting master information"
    ret_val=$( read_cluster_config "Master" )
    MASTER_HOST=$( get_tail_element "$ret_val" '|' 3 )
    MASTER_USER=$( get_tail_element "$ret_val" '|' 2 )
    MASTER_BACKUPDIR="$(dirname $LOCAL_BACKUP_DIR)/$MASTER_HOST"

    # ************************************************************************************************#
    # **************************** Connecting to the master node *************************************#
    # ************************************************************************************************#
    color_echo "-------- Connecting to the master [\e[0m$MASTER_HOST\e[1;32m]"
    open_ssh_tunnel $MASTER_USER $MASTER_HOST $MASTER_SSH_KEY
    exit_if_error $? "-------- Could not connect to the master [\e[0m$MASTER_HOST\e[1;31m]. Try restoring master first"
    master_conn=$last_conn

    # ************************************************************************************************#
    # **************************** Opening the connection to the remote host using slave_ssh_key *****#
    # ************************************************************************************************#
    color_echo "-------- Connecting to the new server [\e[0m$REMOTE_HOST\e[1;32m]"
    slave_ssh_key="$LOCAL_BACKUP_DIR/cb_ssh"
    if [  -f $MASTER_BACKUPDIR/cbconfig.tar ];
    then
        tar xf $MASTER_BACKUPDIR/cbconfig.tar -P -C $LOCAL_BACKUP_DIR/ /etc/cb/cb_ssh --strip-components 2
    fi

    if [ ! -f $slave_ssh_key ]
    then
        color_echo "-------- SSH Key is not present in the backup. Getting it from the master"
        remote_copy $master_conn "/etc/cb/cb_ssh" "$LOCAL_BACKUP_DIR/" 1
    fi

    if [ -f $slave_ssh_key ];
    then
        chmod 0400 $slave_ssh_key
    fi

    if [ $(ssh -q -o "BatchMode yes" $slave_user@$REMOTE_HOST -i $slave_ssh_key "echo 1 && exit " || echo "0") == "0" ];
    then
        color_echo "-------- SSH Key is not yet authorized on the remote machine. Copying the key"
        remote_copy $master_conn "/etc/cb/cb_ssh.pub" "$LOCAL_BACKUP_DIR/" 1
        ssh-copy-id -i "$slave_ssh_key.pub" $slave_user@$REMOTE_HOST
        exit_if_error $? "-------- Could not connect to the new server [\e[0m$REMOTE_HOST\e[1;31m]"
    fi

    open_ssh_tunnel $slave_user $REMOTE_HOST $slave_ssh_key
    exit_if_error $? "-------- Could not connect to the new server [\e[0m$REMOTE_HOST\e[1;31m]"
    remote_conn=$last_conn
    check_host_time $remote_conn
    exit_if_error $? "-------- Time on the remote server [\e[0m$REMOTE_HOST\e[1;31m] is not synced. Try to sync time first"


    if [ $( remote_exec_get_output $remote_conn "test -e /etc/cb/gunicorn.conf && echo 1 || echo 0" ) == 1 ]
    then
        # ************************************************************************************************#
        # **************************** Stopping the cluster **********************************************#
        # ************************************************************************************************#
        color_echo "-------- Stopping the cluster"
        remote_exec $master_conn "/usr/share/cb/cbcluster stop"
    else
        _new_install=1
    fi

    # ************************************************************************************************#
    # **************************** Copying backup files to the remote machine ************************#
    # ************************************************************************************************#
    color_echo "-------- Copying the backup to the remote machine"
    remote_exec $remote_conn "mkdir -p $REMOTE_RESTORE_DIR"
    remote_copy $remote_conn "$LOCAL_BACKUP_DIR/*" "$REMOTE_RESTORE_DIR" 0 -r
    exit_if_error $? "-------- Could not copy bakup to the new server"

    # ************************************************************************************************#
    # **************************** Installing new cb-enterprise if needed ****************************#
    # ************************************************************************************************#
    install_cb_enterprise $remote_conn "$REMOTE_RESTORE_DIR"
    if [ ! $( remote_exec_get_output $remote_conn "test -e /etc/cb/gunicorn.conf && echo 1 || echo 0" ) == 1 ]
    then
        exit_if_error 1 "-------- Something went wrong during CB Server installation"
    fi

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "CB Server is installed on the remote machine "
    color_echo "--------------------------------------------------------------------------------------"

    # ************************************************************************************************#
    # **************************** Initializing slave node *******************************************#
    # ************************************************************************************************#
    color_echo "-------- Initializing CB Server in slave mode"
    # ************************************************************************************************#
    # **************************** Generating config file for slave node to use for init *************#
    # ************************************************************************************************#
    generate_init_conf $master_conn $remote_conn "$LOCAL_BACKUP_DIR" "$REMOTE_RESTORE_DIR"
    init_slave_node $master_conn $remote_conn "$LOCAL_BACKUP_DIR" "$REMOTE_RESTORE_DIR" "$slave_host" "$REMOTE_HOST" $slave_node_id

    if [ ! $( remote_exec_get_output $remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        exit_if_error 1 "-------- Something went wrong during CB Server initialization"
    fi

    # ************************************************************************************************#
    # **************************** Restoring backup files ********************************************#
    # ************************************************************************************************#
    color_echo "-------- Restoring backup files on the remote slave"
    restore_slave_backup $remote_conn

    if [[ $_new_install == 1 ]]
    then
        # ************************************************************************************************#
        # **************************** Stopping the cluster **********************************************#
        # ************************************************************************************************#
        color_echo "-------- Stopping the cluster"
        remote_exec $master_conn "/usr/share/cb/cbcluster stop"
    fi

    # ************************************************************************************************#
    # **************************** Regenerating server token *****************************************#
    # ************************************************************************************************#
    regenerate_server_token $remote_conn
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Restore of the SLAVE is done"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    # ************************************************************************************************#
    # **************************** Updating master with new slave node information *******************#
    # ************************************************************************************************#
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Updating MASTER [\e[0m$MASTER_HOST\e[1;32m] with new slave information "
    color_echo "--------------------------------------------------------------------------------------"
    update_master_with_new_slave "$master_conn" "$LOCAL_BACKUP_DIR" "$slave_host" $slave_node_id "$REMOTE_HOST"
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Update of MASTER is done"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    # ************************************************************************************************#
    # **************************** Updating slaves with new slave node information *******************#
    # ************************************************************************************************#
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Updating \e[0mALL SLAVES\e[1;32m with new slave information "
    color_echo "--------------------------------------------------------------------------------------"
    update_all_slaves_with_new_slave $master_conn $LOCAL_BACKUP_DIR $slave_ssh_key $slave_host $REMOTE_HOST $SAVE_HOSTS
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Update of ALL SLAVES is done"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    # ************************************************************************************************#
    # **************************** Starting the cluster again ****************************************#
    # ************************************************************************************************#
    color_echo "-------- Starting the cluster"
    remote_exec $master_conn "/usr/share/cb/cbcluster start"

    cleanup_tmp_files
    close_ssh_tunnel $remote_conn
    close_ssh_tunnel $master_conn
fi


echo
color_echo "--------------------------------------------------------------------------------------"
color_echo "Restore is successful"
color_echo "--------------------------------------------------------------------------------------"
