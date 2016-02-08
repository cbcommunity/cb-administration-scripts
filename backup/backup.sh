#! /bin/bash

. ./common.sh

usage="$(basename "$0") [-h help] | -r host -u user [-b path] [-k key] [-m master host] [-mu master user] [-mu backup all slaves] [-mk master key]

where:
    -r, --remote        Ip address or the hostname of the remote server to restore the backup on
    -u, --user          User to use for remote server connection
    -b, --backup        Optional. Folder path to store backup. If not provided current folder is used
    -k, --key           Optional. Ssh key that can be used to connect to the remote server
    -m, --master        Optional. In case of slave backup master host can be provided to avoid prompting for the password too many times.
    -mu, --master-user  Optional. In case of slave backup master user can be provided to avoid prompting for the password too many times.
    -mk, --master-key   Optional. Ssh key that can be used to connect to the master
    -ma, --master-all   Optional. Backup master and all slaves
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
        LOCAL_BACKUP_DIR_BASE=$(sed 's/\/$//' <<< "$2")
        shift # past argument
        ;;
        -m|--master)
        MASTER_HOST="$2"
        shift # past argument
        ;;
        -mu|--master-user)
        MASTER_USER="$2"
        shift # past argument
        ;;
        -mk|--master-key)
        MASTER_SSH_KEY="$2"
        shift # past argument
        ;;
        -ma|--master-all)
        MASTER_ALL="$2"
        shift # past argument
        ;;
        -k|--key)
        SSH_KEY="$2"
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

    if [ "$ERROR" == "1" ]
    then
        echo "$usage"
        exit 1
    fi
}

LOCAL_BACKUP_DIR_BASE=.
parse_input $@
validate_input

REMOTE_BACKUP_DIR=/tmp/backup/$DATE
LOCAL_BACKUP_DIR=$LOCAL_BACKUP_DIR_BASE/$DATE/$REMOTE_HOST
mkdir -p $LOCAL_BACKUP_DIR

exec > >(tee >(sed -u -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g' > $LOCAL_BACKUP_DIR/backup.log))
exec 2>&1

get_remote_connection () {
    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $SSH_KEY
    remote_conn=$last_conn
}

get_remote_config () {

    if [ -z "$remote_conn" ];
    then
        color_echo "-------- Connecting to the remote server"
        get_remote_connection
    fi

    color_echo "-------- Copying cb.conf from the remote server to the $LOCAL_BACKUP_DIR/"
    remote_copy $remote_conn "/etc/cb/cb.conf" "$LOCAL_BACKUP_DIR/" 1
    source $LOCAL_BACKUP_DIR/cb.conf
}

backup_node () {
    _conn=$1
    _node_type=$2
    _local_backup_dir=$3

    color_echo "-------- Archiving all necessary information"

    remote_exec $_conn "mkdir -p $REMOTE_BACKUP_DIR"
    # Host file
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbhosts.tar /etc/hosts"
    # Yum files
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbyum.tar /etc/yum.repos.d/"
    # Certs files
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbcerts.tar /etc/cb/certs/"
    # IP Tables file
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbiptables.tar /etc/sysconfig/iptables"
    # SSH Configuration and Keys
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbssh.tar /etc/ssh/"
    # Carbon Black configuration
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbconfig.tar /etc/cb/"
    # Rsyslog Configuration
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbrsyslog.tar /etc/rsyslog.conf"
    # Rsyslog.d configuration
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbrsyslogd.tar /etc/rsyslog.d/"
    # logrotate configuration
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cblogrotate.tar /etc/logrotate.d/cb"
    # Rabbitmq cookie
    remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbrabbitmqcookie.tar /var/cb/.erlang.cookie"

    if [ "$_node_type" == "Slave" ];
    then
       # Optional: SSH Authorization Keys - Needed if you have used trusted keys between systems in a clustered environment
       remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbrootauthkeys.tar /root/.ssh/authorized_keys"
    else
        # Perform the following steps only on a Master CB Server
        # Start Postgres Database
        remote_exec $_conn "service cb-pgsql start"

        remote_exec $_conn "pg_dump -C -Fp -f $REMOTE_BACKUP_DIR/psqldump.sql cb -p 5002 \
        --exclude-table-data=allianceclient_comm_history \
        --exclude-table-data=allianceclient_uploads \
        --exclude-table-data=allianceclient_pending_uploads \
        --exclude-table-data=banning_sensor_counts \
        --exclude-table-data=binary_status \
        --exclude-table-data=cb_useractivity \
        --exclude-table-data=detect_dashboard_average_alert_resolution_history \
        --exclude-table-data=detect_dashboard_binary_dwell_history \
        --exclude-table-data=detect_dashboard_host_hygiene_history \
        --exclude-table-data=investigations \
        --exclude-table-data=maintenance_job_history \
        --exclude-table-data=moduleinfo_events \
        --exclude-table-data=mutex_watchlist_searcher \
        --exclude-table-data=sensor_activity \
        --exclude-table-data=sensor_comm_failures \
        --exclude-table-data=sensor_driver_diagnostics \
        --exclude-table-data=sensor_event_diagnostics \
        --exclude-table-data=sensor_licensing_counts \
        --exclude-table-data=sensor_queued_data_stats \
        --exclude-table-data=sensor_resource_statuses \
        --exclude-table-data=server_storage_stats \
        --exclude-table-data=storefiles \
        --exclude-table-data=tagged_events"

        remote_exec $_conn "pg_dumpall -p 5002 --roles-only -f $REMOTE_BACKUP_DIR/psqlroles.sql"
        remote_exec $_conn "sed -i 's/CREATE ROLE cb;/DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user WHERE usename = \x27cb\x27 ) THEN CREATE ROLE cb; END IF; END\$\$;/' $REMOTE_BACKUP_DIR/psqlroles.sql"
        remote_exec $_conn "sed -i 's/CREATE ROLE root;/DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user WHERE usename = \x27root\x27 ) THEN CREATE ROLE root; END IF; END\$\$;/'  $REMOTE_BACKUP_DIR/psqlroles.sql"
        remote_exec $_conn "service cb-pgsql stop"

        # Syslog CEF templates
        remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbceftemp.tar /usr/share/cb/syslog_templates"

        #Optional: CB Installer backups - Needed only if you have manually installed additional versions of the sensor
        remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbinstallers.tar /usr/share/cb/coreservices/installers/"
    fi
    color_echo "-------- Copying backup to the $_local_backup_dir/"
    remote_copy $_conn "$REMOTE_BACKUP_DIR/*" "$_local_backup_dir/" 1 -r
    remote_exec $_conn "rm -rf $REMOTE_BACKUP_DIR"
}

stop_start_cb_server ()
{
    _conn=$1
    _command=$2
    _service=/usr/share/cb/cbcluster

    if [ $ClusterMembership == "Standalone" ]
    then
        _service="service cb-enterprise"
    fi

    remote_exec $_conn "$_service $_command"
}

if [ -z "$MASTER_HOST" ];
then
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Retrieving information from the remote server"
    color_echo "--------------------------------------------------------------------------------------"
    get_remote_config
fi

test_ssh_key() {
    _user=$1
    _host=$2
    _key=$3
    if [ $(ssh -q -o "BatchMode yes" $REMOTE_USER@$REMOTE_HOST -i $_key "echo 1 && exit " || echo "0") == "1" ];
    then
        return 1
    fi

    color_echo "-------- Provided key is not authorized on the server [\e[0m$_host\e[1;32m]"

    return 0
}

get_master_connection (){

    if [ -z "$MASTER_USER" ];
    then
        MASTER_USER=root
    fi
    open_ssh_tunnel $MASTER_USER $MASTER_HOST $MASTER_SSH_KEY
    master_conn=$last_conn
}

get_master_info_from_remote(){
    color_echo "-------- Copying cluster.conf from the remote server to the $LOCAL_BACKUP_DIR"
    remote_copy $remote_conn "/etc/cb/cluster.conf" "$LOCAL_BACKUP_DIR/" 1

    color_echo "-------- Parsing master's information in cluster.conf"
    ret_val=$( read_cluster_config "Master" )
    MASTER_HOST=$( get_tail_element "$ret_val" '|' 3 )
    MASTER_USER=$( get_tail_element "$ret_val" '|' 2 )
}

get_key_from_master(){
    _conn=$1

    color_echo "-------- Copying slave ssh key from the master to the $LOCAL_BACKUP_DIR"
    slave_ssh_key="$LOCAL_BACKUP_DIR/cb_ssh"
    remote_copy $_conn "/etc/cb/cb_ssh" "$LOCAL_BACKUP_DIR/" 1

    if [ -f $slave_ssh_key ]
    then
        chmod 0400 $slave_ssh_key
    else
        color_echo "-------- Slave ssh key is not present on the master"
    fi

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
            backup_node $last_conn "Slave" $_local_backup_dir_slave
            close_ssh_tunnel $last_conn
            unset _slave_user
            unset _slave_host
            _slave=0
        fi

    done < $_local_backup_dir/cluster.conf
}
if [ -z "$MASTER_HOST" ] && [ $ClusterMembership != "Slave" ];
then
    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "$ClusterMembership configuration is found on the remote server"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Backing up \e[0mMASTER\e[1;32m"
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "-------- Stopping cb-enterprise on the master"
    stop_start_cb_server $remote_conn "stop"

    echo
    backup_node $remote_conn $ClusterMembership $LOCAL_BACKUP_DIR

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Backup of the MASTER is done"
    color_echo "--------------------------------------------------------------------------------------"

    if [ $ClusterMembership == "Master" ] && [ "$MASTER_ALL" == "1" ];
    then
        echo
        echo
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Backing up \e[0mALL SLAVES\e[1;32m"
        color_echo "--------------------------------------------------------------------------------------"
        get_key_from_master $remote_conn
        backup_all_slaves $remote_conn $LOCAL_BACKUP_DIR $slave_ssh_key
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Backup of ALL SLAVES is done"
        color_echo "--------------------------------------------------------------------------------------"
    fi

    echo
    color_echo "-------- Starting cb-enterprise on the master"
    stop_start_cb_server $remote_conn "start"
    color_echo "--- Done"
else

    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Slave configuration is found on the remote server"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Establishing connection to the master"
    color_echo "--------------------------------------------------------------------------------------"
    if [ -z "$MASTER_HOST" ];
    then
        color_echo "-------- Master inforamation was not provided. Getting it from the remote server"
        get_master_info_from_remote
    fi
    color_echo "-------- Connecting to the master server"
    get_master_connection
    color_echo "--- Done"

    if [ -z "$remote_conn" ];
    then
        echo
        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Establishing connection to the remote server"
        color_echo "--------------------------------------------------------------------------------------"

        if [ ! -z "$SSH_KEY" ]
        then
            test_ssh_key $REMOTE_USER $REMOTE_HOST $SSH_KEY
            key_valid=$?
        else
            color_echo "-------- SSH key to the slave was not provided"
            key_valid=0
        fi

        if [ "$key_valid" == "0" ];
        then
            get_slave_ssh_key_from_master $master_conn
        fi
        color_echo "-------- Connecting to the slave node"
        get_remote_connection
        get_remote_config
        color_echo "--- Done"
    fi

    echo
    echo
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Backing up SLAVE [\e[0m$REMOTE_HOST\e[1;32m]"
    color_echo "--------------------------------------------------------------------------------------"
    color_echo "-------- Stopping cb-enterprise on the master"
    stop_start_cb_server $master_conn "stop"

    backup_node $remote_conn $ClusterMembership $LOCAL_BACKUP_DIR

    color_echo "--------------------------------------------------------------------------------------"
    color_echo "Backup of the SLAVE is done"
    color_echo "--------------------------------------------------------------------------------------"

    echo
    color_echo "-------- Starting cb-enterprise on the master"
    stop_start_cb_server $master_conn "start"
    color_echo "--- Done"

    close_ssh_tunnel $master_conn
fi

cleanup_tmp_files
close_ssh_tunnel $remote_conn

echo
color_echo "--------------------------------------------------------------------------------------"
color_echo "Backup is successful"
color_echo "--------------------------------------------------------------------------------------"

echo "Log File: $LOCAL_BACKUP_DIR/log.log"
