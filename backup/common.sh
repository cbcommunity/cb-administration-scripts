#!/usr/bin/env bash

DATE=$(date +%Y-%m-%d-%H-%M-%S)
REMOTE_RESTORE_DIR=/tmp/restore/$DATE
PORT=50000
last_conn=

get_next_conn () {
    ((PORT++))
    path="remote_tunnel_$1_$2_$PORT"
    last_conn=$path
}

get_tail_element (){
    string=$1
    delimiter=$2
    index=$3

    IFS="$delimiter" read -ra arr <<< "$string"

    echo ${arr[$(expr ${#arr[@]} - $index)]}
}

get_ip_from_hostname ()
{
    echo $(getent ahosts $1 | sed -n 1p | cut -d " " -f1 | tr -s " ")
}

open_ssh_tunnel() {
    user=$1
    host=$2
    key=$3

    get_next_conn $user $host

    if [ ! -z "$key" ];
    then
        ssh -o ControlPath=$last_conn -M -fnNT -L $PORT:$host:22 $user@$host -i $key
    else
        ssh -o ControlPath=$last_conn -M -fnNT -L $PORT:$host:22 $user@$host
    fi
}

close_ssh_tunnel() {
    path=$1
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )
    ssh -o ControlPath=$path -O exit $user@$host
}

remote_exec() {
    path=$1
    remote_command=$2
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )
    ssh -o ControlPath=$path $user@$host "$remote_command" < /dev/null
}

remote_copy() {
    path=$1
    from_path=$2
    to_path=$3
    from_remote=$4
    args=$5
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )

    if [ $from_remote == 1 ]
    then
        scp -o ControlPath=$path $args $user@$host:$from_path $to_path
    else
        scp -o ControlPath=$path $args $from_path $user@$host:$to_path
    fi
}

color_echo () {
    text=$1
    color="1;32"
    if [ ! -z "$2" ]
    then
        color="$2"
    fi

    echo -e "\e[${color}m$text\e[0m"
}

read_cluster_config() {
    section=$1
    host_name=$2
    host_value=$3
    section_found=0
    section_host=
    section_user=
    section_shards=
    section_name=$name
    section_id=0

    if [ ! -f $LOCAL_BACKUP_DIR/cluster.conf ]
    then
         tar xvf $LOCAL_BACKUP_DIR/cbconfig.tar -C $LOCAL_BACKUP_DIR/ /etc/cb/cluster.conf --strip-components 2
    fi

    IFS="="
    while read -r name value
    do
        if [[ "$name" =~ \[$section ]]; then
            section_found=1
            section_name=$name
            ((section_id++))
        fi
        if [ $section_found == 1 ] && [ "$name" == "Host" ];
        then
            if [ -z "$host_name"  ] || ( [ $name == $host_name ] && [ $value == $host_value ] );
            then
                section_host=$value
            else
                unset section_shards
            fi
        fi
        if [ $section_found == 1 ] && [ "$name" == "User" ] && [ ! -z "$section_host"  ];
        then
            section_user=$value
            break
        fi
        if [ $section_found == 1 ] && [ "$name" == "ProcSolrShards" ];
        then
            section_shards=$value
        fi
    done < $LOCAL_BACKUP_DIR/cluster.conf

    echo "$section_id|$section_name|$section_host|$section_user|shards=$section_shards"
}


extract_configs_from_backup ()
{
    tar xf $LOCAL_BACKUP_DIR/cbconfig.tar -P -C $LOCAL_BACKUP_DIR/ /etc/cb/cb.conf --strip-components 2
    tar xf $LOCAL_BACKUP_DIR/cbconfig.tar -P -C $LOCAL_BACKUP_DIR/ /etc/cb/cluster.conf --strip-components 2
    source $LOCAL_BACKUP_DIR/cb.conf
}

regenerate_server_token () {
    _conn=$1

    echo
    color_echo "-------- Regenerating server token on the remote server -----------------------------"
    remote_exec $_conn "rm -rf /etc/cb/server.token"
    token_command=$(printf '%q' "from cb.alliance.token_manager import SetupServerToken; SetupServerToken().set_server_token('/etc/cb/server.token')")
    remote_exec $_conn "python -c $token_command"
    color_echo "--- Done"
    echo
}


update_host_file () {

    _old_host=$1
    _old_ip=$2

    _new_host=$3
    _new_ip=$4

    _ssh_conn=$5
    _save_host_entry=$6

    if [ "$_new_host"  == "$_new_ip" ];
    then
        color_echo "-------- IP address was provided. Skipping. ---------------"
        return 0
    fi

    # If we have new hostname in the hosts file we will just update it with the current ip
    # If we don't have new hostname in the hosts file and we have an old hostname we will add a new entry to the hosts file
    # If neither old nor new hostname is in the hosts file we will not change hosts file, unless SAVE_HOSTS=1

    host_match_regex="^.*[[:space:]]*$_new_host[[:space:]]*.*$"
    _match=$(remote_exec $_ssh_conn "grep -q '$host_match_regex' /etc/hosts && echo '1' || echo '0'" )
    if [  "$_match" == "1" ];
    then
        color_echo "-------- \"$_new_host\" host entry is found in the hosts file"
        remote_exec $_ssh_conn "grep -o \"$host_match_regex\" /etc/hosts"
        color_echo "-------- Updating it to the $_new_ip -----------------------"
        _command="sed -i -r 's/^ *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(.* +$_new_host)/$_new_ip\1/' /etc/hosts"
        remote_exec $_ssh_conn "$_command"
        remote_exec $_ssh_conn "grep -o \"$host_match_regex\" /etc/hosts"
        return 0
    fi

    host_match_regex="^.*[[:space:]]*$_old_host[[:space:]]*.*$"

    _match=$(remote_exec $_ssh_conn "grep -q '$host_match_regex' /etc/hosts && echo '1' || echo '0'" )
    if [ "$_old_host" != "$_old_ip" ] && [ "$_match" == "1" ];
    then
        color_echo "-------- $_new_host host entry is not found in the hosts file, but the old one is."
        color_echo "-------- Adding \"$_new_ip        $_new_host\" to the hosts file"
        remote_exec $_ssh_conn "sed -i '1i $_new_ip        $_new_host' /etc/hosts"
        return 0
    fi

    if [ "$_save_host_entry" == "1" ];
    then
        color_echo "-------- Neither $_new_host nor $_old_host was not found in the /etc/hosts file, but SAVE_HOSTS=$_save_host_entry was provided, so we are adding a new entry."
        color_echo "-------- Adding \"$_new_ip        $_new_host\" to the hosts file"
        remote_exec $_ssh_conn "sed -i '1i $_new_ip        $_new_host' /etc/hosts"
    else
        color_echo "-------- Old host name is not in the hosts file. Not changing hosts file."
    fi
}

cleanup_tmp_files() {
    rm -rf "$LOCAL_BACKUP_DIR/cb.conf"
    rm -rf "$LOCAL_BACKUP_DIR/cluster.conf"
    rm -rf "$LOCAL_BACKUP_DIR/cb_ssh"
    rm -rf "$LOCAL_BACKUP_DIR/cbupdate.py"
    rm -rf "$LOCAL_BACKUP_DIR/cbinit.py"
    rm -rf "$LOCAL_BACKUP_DIR/psqlcbvalues"
}

