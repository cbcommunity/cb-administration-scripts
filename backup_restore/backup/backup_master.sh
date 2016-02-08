#!/bin/bash

backup_all_slaves (){
    _master_conn=$1
    _local_backup_dir=$2
    _slave_key=$3
    _slave=0
    _slave_host=
    _slave_user=
    IFS="="

    remote_copy $remote_conn "/etc/cb/cluster.conf" "$LOCAL_BACKUP_DIR/" 1

    while read -r name value
    do
        if [[ "$name" =~ ^\[Slave* ]]; then
            _slave=1
            _slave_name=$name
        fi
        if [ $_slave == 1 ] && [ "$name" == "Host" ]; then
            _slave_host=$value
        fi
        if [ $_slave == 1 ] && [ "$name" == "User" ]; then
            _slave_user=$value
        fi
        if [ $_slave == 1 ] && [ ! -z "$_slave_host" ] && [ ! -z "$_slave_user"  ]; then
            echo
            color_echo "--------------------------------------------------------------------------------------"
            color_echo "Backing up $_slave_name [\e[0m$_slave_host\e[1;32m]"
            color_echo "--------------------------------------------------------------------------------------"
            _local_backup_dir_slave=$LOCAL_BACKUP_DIR_BASE/$DATE/$_slave_host
            mkdir -p $_local_backup_dir_slave
            color_echo "-------- Connecting to the [\e[0m$_slave_host\e[1;32m]"
            open_ssh_tunnel $_slave_user $_slave_host $_slave_key
            if [ $? == 0 ];
            then
                backup_node $last_conn "Slave" $_local_backup_dir_slave
                close_ssh_tunnel $last_conn
            else
                color_echo "-------- Could not connect to the $slave_host minion ------" "1;33"
                color_echo "-------- Skipping"
            fi
            unset _slave_user
            unset _slave_host
            _slave=0
        fi

    done < $_local_backup_dir/cluster.conf
}