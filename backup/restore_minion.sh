#!/usr/bin/env bash

copy_config_to_all_slaves () {
    slave_key=$1
    slave=0
    slave_host=
    slave_user=
    IFS="="
    while read -r name value
    do
        if [[ $name =~ ^\[Slave* ]]; then
            slave=1
        fi
        if [ $slave == 1 ] && [ $name == "Host" ]; then
            slave_host=$value
        fi
        if [ $slave == 1 ] && [ $name == "User" ]; then
            slave_user=$value
        fi
        if [ $slave == 1 ] && [ ! -z "$slave_host" ] && [ ! -z "$slave_user"  ]; then
            open_ssh_tunnel $slave_user $slave_host $slave_key
            remote_copy $last_conn "$LOCAL_BACKUP_DIR/cluster.conf" "/etc/cb/" 0
            close_ssh_tunnel $last_conn
            slave_user=
            slave_host=
            slave=0
        fi
    done < $LOCAL_BACKUP_DIR/cluster.conf
}
