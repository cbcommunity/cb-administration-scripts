#!/bin/bash

usage="$(basename "$0") [-h help] -r host -u user [-b path] [-k key] [-m master host] [-mu master user] [-mk master key] [-ma 1] [-ss 1]

where:
    -r, --remote        Remote server IP address or Hostname that should be backed up.
    -u, --user          User to connect to the remote server
    -b, --backup        Optional. Base path to store the backup in. If not provided the current folder is used
    -k, --key           Optional. Ssh key that to connect to the remote server. If not provided user will be prompted for the password
    -m, --master        Optional. Master IP address or Hostname. Slave backups only. If hostname and master key is provided slave can be accessed without password
    -mu, --master-user  Optional. User to connect to the master server. Slave backups only. Root is used if not provided
    -mk, --master-key   Optional. Master ssh key
    -ma, --master-all   Optional. Backup master and all slaves. Master backups only. Ingnored if remote server is in standalone or slave mode
    -ss, --skip-stop    Optional. Skip stopping the cluster/master while backing up
"

LOCAL_BACKUP_DIR_BASE=.
REMOTE_BACKUP_DIR=/tmp/backup/$DATE

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
        LOCAL_BACKUP_DIR_BASE=$(sed 's/\/$//' <<< "$2")
        shift # past argument
        ;;
        -k|--key)
        SSH_KEY="$2"
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
        -ss|--skip-stop)
        SKIP_MASTER_STOP="$2"
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

    is_host_resolvable $REMOTE_HOST
    if [ $? != 0 ]
    then
        color_echo "Remote host is not resolvable" "1;31"
        ERROR=1
    fi

    _resolved_ip=$( resolve_hostname $REMOTE_HOST )
    if [[ "$_resolved_ip" =~ 127. ]] || [[ "$_resolved_ip" == "::1" ]]
    then
        color_echo "Loopback can't be used as the remote host. Please use a remote machine hostname or IP" "1;31"
        ERROR=1
    fi

    is_host_reachable $REMOTE_USER $REMOTE_HOST
    if [ $? != 0 ]
    then
        color_echo "Remote host is not reachable via ssh" "1;31"
        ERROR=1
    fi

    if [ $ERROR != 0 ]
    then
        echo "$usage"
        exit 1
    fi
}

get_remote_connection () {
    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $SSH_KEY
    exit_if_error $? "-------- Could not connect to the remote host ----------------------------------------"
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
    exit_if_error $? "-------- Could not copy /etc/cb/cb.conf from remote server. Make sure CB is installed"
    source $LOCAL_BACKUP_DIR/cb.conf
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
backup_node () {
    _conn=$1
    _node_type=$2
    _local_backup_dir=$3
    _user=$4
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
       _ssh_path="/root/.ssh/authorized_keys"
       if [ "$_user" != "root" ]
       then
           _ssh_path="/home/$_user/.ssh/authorized_keys"
       fi

       if [ $( remote_exec_get_output $remote_conn "test -e $_ssh_path && echo 1 || echo 0" ) == 1 ]
       then
           remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbrootauthkeys.tar $_ssh_path"
       fi
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

        if [ "$SKIP_MASTER_STOP" != "1" ]
        then
            remote_exec $_conn "service cb-pgsql stop"
        fi

        # Syslog CEF templates
        remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbceftemp.tar /usr/share/cb/syslog_templates"

        #Optional: CB Installer backups - Needed only if you have manually installed additional versions of the sensor
        remote_exec $_conn "tar -P --selinux -cf $REMOTE_BACKUP_DIR/cbinstallers.tar /usr/share/cb/coreservices/installers/"
    fi
    color_echo "-------- Copying backup to the $_local_backup_dir/"
    remote_copy $_conn "$REMOTE_BACKUP_DIR/*" "$_local_backup_dir/" 1 -r
}

