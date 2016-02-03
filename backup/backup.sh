#!/usr/bin/env bash

DATE=$(date +%Y-%m-%d-%H-%M-%S)
SSHSOCKET=control-socket$DATE
PORT=50000

REMOTE_SERVER=$1
REMOTE_USER=$2
REMOTE_BACKUP_DIR=/tmp/backup/$DATE
LOCAL_BACKUP_DIR=$REMOTE_SERVER/$DATE/

ssh -o ControlPath=$SSHSOCKET -M -fnNT -L $PORT:$REMOTE_SERVER:22 $REMOTE_USER@$REMOTE_SERVER
mkdir -p $LOCAL_BACKUP_DIR
scp -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER:/etc/cb/cb.conf $LOCAL_BACKUP_DIR/cb.conf
source $LOCAL_BACKUP_DIR/cb.conf

VAR_CB_DIR=$(sed 's/\/data$//' <<< $DatastoreRootDir)

if [ $ClusterMembership != "Slave" ]
then
    command=/usr/share/cb/cbcluster

    if [ $ClusterMembership == "Standalone" ]
    then
        command="service cb-enterprise"
    fi

    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER $command stop
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER mkdir -p $REMOTE_BACKUP_DIR

    # Host file
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbhosts.tar /etc/hosts
    # Yum files
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbyum.tar /etc/yum.repos.d/
    # Certs files
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbcerts.tar /etc/cb/certs/
    # IP Tables file
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbiptables.tar /etc/sysconfig/iptables
    # SSH Configuration and Keys
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbssh.tar /etc/ssh/
    # Carbon Black configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbconfig.tar /etc/cb/
    # Rsyslog Configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrsyslog.tar /etc/rsyslog.conf
    # Rsyslog.d configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrsyslogd.tar /etc/rsyslog.d/
    # logrotate configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cblogrotate.tar /etc/logrotate.d/cb
    # Rabbitmq cookie
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrabbitmqcookie.tar $VAR_CB_DIR/.erlang.cookie

    # Rabbitmq node configuration
    #ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrabbitmqnode.tar $RabbitMQDataPath

    # Syslog CEF templates
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbceftemp.tar /usr/share/cb/syslog_templates

    # Perform the following steps only on a Master CB Server
    # Start Postgres Database
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER service cb-pgsql start

    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER pg_dump -C -Fp -f $REMOTE_BACKUP_DIR/psqldump.sql cb -p 5002 \
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
    --exclude-table-data=tagged_events

    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER pg_dumpall -p 5002 --roles-only -f $REMOTE_BACKUP_DIR/psqlroles.sql
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER "sed -i 's/CREATE ROLE cb;/DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user WHERE usename = \x27cb\x27 ) THEN CREATE ROLE cb; END IF; END\$\$;/' $REMOTE_BACKUP_DIR/psqlroles.sql"
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER "sed -i 's/CREATE ROLE root;/DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_user WHERE usename = \x27root\x27 ) THEN CREATE ROLE root; END IF; END\$\$;/'  $REMOTE_BACKUP_DIR/psqlroles.sql"
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER service cb-pgsql stop

    #Optional: CB Installer backups - Needed only if you have manually installed additional versions of the sensor
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbinstallers.tar /usr/share/cb/coreservices/installers/

    # Review Yum Configuration
    # Review Version Configuration

    # Cluster: Review /etc/cb/cluster.conf
    # Note the number of shards
    # Note the IP and order of minions
    # Note which shards are managed by which systems
    scp -o ControlPath=$SSHSOCKET -r $REMOTE_USER@$REMOTE_SERVER:$REMOTE_BACKUP_DIR/* $LOCAL_BACKUP_DIR
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER rm -rf $REMOTE_BACKUP_DIR

    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER $command start
else
    scp -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER:/etc/cb/cluster.conf $LOCAL_BACKUP_DIR/cluster.conf
    SLAVE_SSHSOCKET=control-socket-slave$DATE
    SLAVE_PORT=50001

    MASTER=0
    MASTER_HOST=
    MASTER_USER=

    IFS="="
    while read -r name value
    do
        if [ "$name" == "[Master]" ]; then
            MASTER=1
        fi
        if [ $MASTER == 1 ] && [ $name == "Host" ]; then
            MASTER_HOST=$value
        fi
        if [ $MASTER == 1 ] && [ $name == "User" ]; then
            MASTER_USER=$value
            break
        fi
    done < $LOCAL_BACKUP_DIR/cluster.conf

    ssh -o ControlPath=$SLAVE_SSHSOCKET -M -fnNT -L $SLAVE_PORT:$MASTER_HOST:22 $MASTER_USER@$MASTER_HOST
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER mkdir -p $REMOTE_BACKUP_DIR
    #Stop CB-Enterprise
    #Clustered environment (on master run):
    ssh -o ControlPath=$SLAVE_SSHSOCKET $MASTER_USER@$MASTER_HOST /usr/share/cb/cbcluster stop

    # Backup Configuration Files
    # Host file
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbhosts.tar /etc/hosts
    # Yum files
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbyum.tar /etc/yum.repos.d/
    # Certs files
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbcerts.tar /etc/cb/certs/
    # IP Tables file
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbiptables.tar /etc/sysconfig/iptables
    # SSH Configuration and Keys
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbssh.tar /etc/ssh/
    # Carbon Black configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbconfig.tar /etc/cb/
    # Rsyslog Configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrsyslog.tar /etc/rsyslog.conf
    # Rsyslog.d configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrsyslogd.tar /etc/rsyslog.d/
    # logrotate configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cblogrotate.tar /etc/logrotate.d/cb
    # Rabbitmq cookie
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrabbitmqcookie.tar $VAR_CB_DIR/.erlang.cookie
    # Rabbitmq node configuration
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrabbitmqnode.tar $RabbitMQDataPath
    # Optional: SSH Authorization Keys - Needed if you have used trusted keys between systems in a clustered environment
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER tar -P --selinux -cvf $REMOTE_BACKUP_DIR/cbrootauthkeys.tar /root/.ssh/authorized_keys

    # Copy gathered data off of server to remote location for use during the restore process
    scp -o ControlPath=$SSHSOCKET -r $REMOTE_USER@$REMOTE_SERVER:$REMOTE_BACKUP_DIR/* $LOCAL_BACKUP_DIR
    ssh -o ControlPath=$SSHSOCKET $REMOTE_USER@$REMOTE_SERVER rm -rf $REMOTE_BACKUP_DIR

    rm -rf $LOCAL_BACKUP_DIR/cb.conf
    rm -rf $LOCAL_BACKUP_DIR/cluster.conf

    #Start CB-Enterprise
    #Clustered environment (on master run):
    ssh -o ControlPath=$SLAVE_SSHSOCKET $MASTER_USER@$MASTER_HOST /usr/share/cb/cbcluster start

    ssh -o ControlPath=$SLAVE_SSHSOCKET -O exit $MASTER_USER@$MASTER_HOST
fi

rm -rf $LOCAL_BACKUP_DIR/cb.conf
ssh -o ControlPath=$SSHSOCKET -O exit $REMOTE_USER@$REMOTE_SERVER