#! /bin/bash

DATE=$(date +%Y-%m-%d-%H-%M-%S)
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

is_host_reachable(){
    _user=$1
    _host=$2
    status=$(ssh -o BatchMode=yes -o ConnectTimeout=2 $_host echo 0 2>&1)
    if [[ $status == 0 ]] ; then
        return 0
    elif [[ $status == "Permission denied"* ]] ; then
        return 0
    elif [[ $status == "Host key verification failed."* ]] ; then
        return 0
    fi
    echo $status
    return 1
}

is_host_resolvable(){
    _host=$1
    if [ ! -z "$(resolve_hostname $_host)" ]; then
        return 0
    fi
    return 1
}

check_host_time(){
    _conn=$1
    remote_time=$( remote_exec_get_output $_conn "date +%s" )
    local_time=$(date +%s)
    difference=$(( $local_time - $remote_time ))
    difference=${difference#-}
    if (($difference > 5 )); then
        color_echo "There is $difference seconds time difference between local and remote servers" "1;33"
        return $difference
    fi
    return 0
}


exit_if_error (){
    _return_code=$1
    _error_message=$2

    if [ $_return_code != 0 ]
    then
        color_echo "$_error_message" "1;31"
        color_echo "-------- Exiting now"
        cleanup_tmp_files

        if [ ! -z "$remote_conn" ];
        then
            close_ssh_tunnel $remote_conn
        fi

        if [ ! -z "$master_conn" ];
        then
            close_ssh_tunnel $master_conn
        fi
        exit $_return_code
    fi
}

test_ssh_key() {
    _user=$1
    _host=$2
    _key=$3
    if [ $(ssh -q -o "BatchMode yes" $_user@$_host -i $_key "echo 1 && exit " || echo "0") == "1" ];
    then
        return 1
    fi

    color_echo "-------- Provided key is not authorized on the server [\e[0m$_host\e[1;32m]"

    return 0
}

path_contains_backup(){
    _path=$(sed -e 's#/$##' <<< $1)
    if [ -f "$_path/cbconfig.tar" ]
    then
        return 0
    fi
    return 1
}

resolve_hostname ()
{
    echo $(getent ahosts $1 | sed -n 1p | cut -d " " -f1 | tr -s " ")
}

open_ssh_tunnel() {
    user=$1
    host=$2
    key=$3

    get_next_conn $user $host

    if [ "$user" != "root" ]; then
        if [ ! -z "$key" ];
        then
            ssh -t -o ControlPath=$last_conn -o ConnectTimeout=2 -M -fnN -L $PORT:$host:22 $user@$host -i $key < /dev/tty
        else
            ssh -t -o ControlPath=$last_conn -o ConnectTimeout=2 -M -fnN -L $PORT:$host:22 $user@$host < /dev/tty
        fi
    else
        if [ ! -z "$key" ];
        then
            ssh -o ControlPath=$last_conn -o ConnectTimeout=2 -M -fnN -L $PORT:$host:22 $user@$host -i $key
        else
            ssh -o ControlPath=$last_conn -o ConnectTimeout=2 -M -fnN -L $PORT:$host:22 $user@$host
        fi
    fi
    return $?
}

close_ssh_tunnel() {
    path=$1
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )
    cleanup_remote_tmp_folder $path $host
    ssh -o ControlPath=$path -O exit $user@$host
}

remote_exec() {
    path=$1
    remote_command=$2
    keep_input=$3
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )

    if [ "$user" != "root" ]; then
        ssh -t -q -o ControlPath=$path $user@$host "sudo -n $remote_command" < /dev/tty
    else
        if [ ! -z "$keep_input" ]; then
           ssh -o ControlPath=$path $user@$host "$remote_command"
        else
           ssh -o ControlPath=$path $user@$host "$remote_command" < /dev/null
        fi
    fi
}

remote_exec_get_output() {
    path=$1
    remote_command=$2
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )

    if [ "$use_output" == "1" ];
    then
        _ret_value=$(ssh -t -q -o ControlPath=$path $user@$host "sudo -n $remote_command" < /dev/tty)

        if [ ! -z "$_ret_value" ]; then
            i=$((${#_ret_value}-1))
            echo ${_ret_value:0:$i}
        fi
    else
        ssh -o ControlPath=$path $user@$host "$remote_command" < /dev/null
    fi
}

remote_exec_keep_input() {
    path=$1
    remote_command=$2
    remote_exec $1 $2 1
}

remote_copy() {
    path=$1
    from_path=$2
    to_path=$3
    from_remote=$4
    args=$5
    user=$( get_tail_element $path '_' 3 )
    host=$( get_tail_element $path '_' 2 )

    if [ "$user" != "root" ]; then
        if [ $from_remote == 1 ]
        then
            remote_exec $path "rm -rf /tmp/FILETRANSFER/$DATE"
            remote_exec $path "mkdir -p /tmp/FILETRANSFER/$DATE"
            remote_exec $path "cp $args $from_path /tmp/FILETRANSFER/$DATE"
            remote_exec $path "chown -R $user /tmp/FILETRANSFER/$DATE"

            if [ ! -z "$args" ]
            then
                scp -o ControlPath=$path $args $user@$host:/tmp/FILETRANSFER/$DATE/* $to_path
            else
                _file_name=$( get_tail_element $from_path '/' 1 )
                scp -o ControlPath=$path $user@$host:/tmp/FILETRANSFER/$DATE/$_file_name $to_path
            fi
        else
            remote_exec $path "rm -rf /tmp/FILETRANSFER/$DATE"
            remote_exec $path "mkdir -p /tmp/FILETRANSFER/$DATE"
            remote_exec $path "chown -R $user /tmp/FILETRANSFER/$DATE"
            scp -o ControlPath=$path $args $from_path $user@$host:/tmp/FILETRANSFER/$DATE
            if [ ! -z "$args" ]
            then
                remote_exec $path "cp $args /tmp/FILETRANSFER/$DATE/* $to_path"
            else
                _file_name=$( get_tail_element $from_path '/' 1 )
                remote_exec $path "cp /tmp/FILETRANSFER/$DATE/$_file_name $to_path"
            fi
        fi
        return $?
    fi

    if [ $from_remote == 1 ]
    then
        scp -o ControlPath=$path $args $user@$host:$from_path $to_path
    else
        scp -o ControlPath=$path $args $from_path $user@$host:$to_path
    fi
    return $?
}

parse_all_slaves_from_config () {
    _config_dir=$1
    _slave=0
    _slave_host=
    _slave_user=
    IFS="="
    _slave_nodes=()
    while read -r name value
    do
        if [[ "$name" =~ ^\[Slave* ]]; then
            _slave=1
            if [ ! -z "$_slave_name" ]
            then
                echo
            fi
            _slave_name=$name
        fi
        if [ $_slave == 1 ] && [ "$name" == "Host" ]; then
            _slave_host=$value
        fi
        if [ $_slave == 1 ] && [ "$name" == "User" ]; then
            _slave_user=$value
        fi
        if [ $_slave == 1 ] && [ ! -z "$_slave_host" ] && [ ! -z "$_slave_user"  ]; then
            _slave_nodes+=("$_slave_name|$_slave_user|$_slave_host")
            unset _slave_user
            unset _slave_host
            _slave=0
        fi

    done < $_config_dir/cluster.conf
    unset IFS
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
    color_echo "-------- Regenerating server token on the remote server"
    remote_exec $_conn "rm -rf /etc/cb/server.token"
    token_command=$(printf '%q' "from cb.alliance.token_manager import SetupServerToken; SetupServerToken().set_server_token('/etc/cb/server.token')")
    remote_exec $_conn "python -c $token_command"
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
        color_echo "-------- IP address was provided. Skipping."
        return 0
    fi

    # If we have new hostname in the hosts file we will just update it with the current ip
    # If we don't have new hostname in the hosts file and we have an old hostname we will add a new entry to the hosts file
    # If neither old nor new hostname is in the hosts file we will not change hosts file, unless SAVE_HOSTS=1

    host_match_regex="^.*[[:space:]]*$_new_host[[:space:]]*.*$"
    _match=$(remote_exec_get_output $_ssh_conn "grep -q '$host_match_regex' /etc/hosts && echo '1' || echo '0'")
    if [  "$_match" == "1" ];
    then
        color_echo "-------- \"$_new_host\" host entry is found in the hosts file"
        remote_exec $_ssh_conn "grep -o \"$host_match_regex\" /etc/hosts"
        color_echo "-------- Updating it to the $_new_ip"
        _command="sed -i -r 's/^ *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(.* +$_new_host)/$_new_ip\1/' /etc/hosts"
        remote_exec $_ssh_conn "$_command"
        remote_exec $_ssh_conn "grep -o \"$host_match_regex\" /etc/hosts"
        return 0
    fi

    host_match_regex="^.*[[:space:]]*$_old_host[[:space:]]*.*$"

    _match=$(remote_exec_get_output $_ssh_conn "grep -q '$host_match_regex' /etc/hosts && echo '1' || echo '0'")
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
    color_echo "-------- Cleaning temp files in \e[0m$LOCAL_BACKUP_DIR\e[1;32m on local"
    rm -rf "$LOCAL_BACKUP_DIR/cb.conf"
    rm -rf "$LOCAL_BACKUP_DIR/cluster.conf"
    rm -rf "$LOCAL_BACKUP_DIR/cb_ssh"
    rm -rf "$LOCAL_BACKUP_DIR/cbupdate.py"
    rm -rf "$LOCAL_BACKUP_DIR/cbinit.py"
    rm -rf "$LOCAL_BACKUP_DIR/cb_ssh.pub"
    rm -rf "$LOCAL_BACKUP_DIR/cbinit.conf"
    rm -rf "$LOCAL_BACKUP_DIR/.erlang.cookie"
}

remote_remote_tmp_folder(){
    _conn=$1
    _host=$2
    _folder=$3

    if [ ! -z "$_dir_to_clean" ]
    then
        color_echo "-------- Cleaning temp files [\e[0m$_dir_to_clean/*\e[1;32m] on remote [\e[0m$_host\e[1;32m]"
        remote_exec $_conn "rm -rf $_dir_to_clean"
    fi
}

cleanup_remote_tmp_folder(){
    _conn=$1
    _host=$2

    if [[ $( remote_exec_get_output $_conn "test -d $REMOTE_RESTORE_DIR && echo 0 || echo 1" ) == 0 ]]
    then
        _dir_to_clean=$REMOTE_RESTORE_DIR
        remote_remote_tmp_folder $_conn $_host $_dir_to_clean
    fi

    if [[ $( remote_exec_get_output $_conn "test -d $REMOTE_BACKUP_DIR && echo 0 || echo 1" ) == 0 ]]
    then
        _dir_to_clean=$REMOTE_BACKUP_DIR
        remote_remote_tmp_folder $_conn $_host $_dir_to_clean
    fi
}
