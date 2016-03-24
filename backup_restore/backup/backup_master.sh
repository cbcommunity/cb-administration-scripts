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

    parse_all_slaves_from_config $_local_backup_dir

    for _slave_node in "${_slave_nodes[@]}"
    do
        _slave_host=$( get_tail_element $_slave_node '|' 1 )
        _slave_user=$( get_tail_element $_slave_node '|' 2 )
        _slave_name=$( get_tail_element $_slave_node '|' 3 )
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Backing up $_slave_name [\e[0m$_slave_host\e[1;32m]"
        color_echo "--------------------------------------------------------------------------------------"
        _local_backup_dir_slave=$LOCAL_BACKUP_DIR_BASE/$DATE/$_slave_host
        mkdir -p $_local_backup_dir_slave
        color_echo "-------- Connecting to the [\e[0m$_slave_host\e[1;32m]"
        open_ssh_tunnel $_slave_user $_slave_host $_slave_key
        if [ $? == 0 ];
        then
            backup_node $last_conn "Slave" $_local_backup_dir_slave $_slave_user
            close_ssh_tunnel $last_conn
        else
            color_echo "-------- Could not connect to the $slave_host minion ------" "1;33"
            color_echo "-------- Skipping"
        fi
    done

}