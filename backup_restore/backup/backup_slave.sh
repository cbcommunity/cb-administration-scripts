#!/bin/bash

get_master_info_from_remote(){
    color_echo "-------- Copying cluster.conf from the remote server to the $LOCAL_BACKUP_DIR"
    remote_copy $remote_conn "/etc/cb/cluster.conf" "$LOCAL_BACKUP_DIR/" 1
    exit_if_error $? "-------- Could not copy /etc/cb/cluster.conf. Make sure CB is installed on the remote machine"

    color_echo "-------- Parsing master's information in cluster.conf"
    ret_val=$( read_cluster_config "Master" )
    MASTER_HOST=$( get_tail_element "$ret_val" '|' 3 )
    MASTER_USER=$( get_tail_element "$ret_val" '|' 2 )
}

get_slave_ssh_key_from_master (){
    _conn=$1
    get_key_from_master $_conn

    if [ $(ssh -q -o "BatchMode yes" $REMOTE_USER@$REMOTE_HOST -i $slave_ssh_key "echo 1 && exit " || echo "0") == "1" ];
    then
        SSH_KEY=$slave_ssh_key
        color_echo "-------- Slave ssh key was successfully imported from the master"
    else
        color_echo "-------- Slave ssh key copied from the master is not authorized"
    fi
}

