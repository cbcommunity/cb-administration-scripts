#!/usr/bin/env bash

. ./common.sh
. ./restore_master.sh
. ./restore_minion.sh

usage="$(basename "$0") [-h help] | -r host -u user -b path [-k key]

where:
    -r, --remote        Ip address or the hostname of the remote server to restore the backup on
    -u, --user          User to use for remote server connection
    -b, --backup        Folder path with backup for restore
    -k, --key           Optional. ssh key that can be used to connect to the remote server
    -s, --save-hosts    Optional. Save new (ipaddress, hostname) entry to the hosts file on all nodes in the cluster
                        Only needed if previous setup did not have host entries for cluster nodes in the hosts file
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
        LOCAL_BACKUP_DIR=$(sed 's/\/$//' <<< "$2")
        shift # past argument
        ;;
        -k|--key)
        MASTER_SSH_KEY="$2"
        shift # past argument
        ;;
        -s|--save-hosts)
        SAVE_HOSTS=1
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

    if [ -z "$LOCAL_BACKUP_DIR" ]
    then
        color_echo "PATH to the backup files must be provided" "1;31"
        ERROR=1
    fi

    if [ "$ERROR" == "1" ]
    then
        echo "$usage"
        exit 1
    fi
}

parse_input $@
validate_input
extract_configs_from_backup

if [ $ClusterMembership != "Slave" ]
then
    # ************************************************************************************************#
    # **************************** Open the connection to the new vm *********************************#
    # ************************************************************************************************#
    color_echo "-------- Master configuration is found in the backup path ---------------------------"
    color_echo "-------- Connecting to the remote machine -------------------------------------------"
    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $MASTER_SSH_KEY
    remote_conn=$last_conn
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Copying backup files to the remote server *************************#
    # ************************************************************************************************#
    copy_backup_to_remote $remote_conn

    # ************************************************************************************************#
    # **************************** Installing CB Server if needed ************************************#
    # ************************************************************************************************#
    if [ ! $( remote_exec $remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        install_master $remote_conn
    fi

    # ************************************************************************************************#
    # **************************** Stopping CB server if needed **************************************#
    # ************************************************************************************************#
    command=/usr/share/cb/cbcluster
    echo
    color_echo "-------- CB Server is installed on the remote machine -------------------------------"
    if [ $ClusterMembership == "Standalone" ]
    then
        command="service cb-enterprise"
        color_echo "-------- Remote machine is in standalone mode ---------------------------------------"
    else
        color_echo "-------- Remote machine is in cluster mode ------------------------------------------"
    fi
    echo
    color_echo "-------- Stopping CB Server on the remote machine -----------------------------------"
    remote_exec $remote_conn "$command stop"
    color_echo "--- Done"

    # ************************************************************************************************#
    # **************************** Stopping iptables *************************************************#
    # ************************************************************************************************#
    echo
    color_echo "-------- Stopping iptables ----------------------------------------------------------"
    remote_exec $remote_conn "service iptables stop"
    color_echo "--- Done"

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
    echo
    color_echo "-------- Updating master configs to have new master address -------------------------"
    udpate_remote_server $remote_conn $OLD_HOST $NEW_HOST
    color_echo "--- Done"
    echo

    # ************************************************************************************************#
    # **************************** Removing shards on the new master that are not in the config ******#
    # ************************************************************************************************#
    remove_shards $remote_conn

    # ************************************************************************************************#
    # **************************** Starting iptables service *****************************************#
    # ************************************************************************************************#
    echo
    color_echo "-------- Starting iptables service --------------------------------------------------"
    remote_exec $remote_conn "service iptables start"
    color_echo "--- Done"


    # ************************************************************************************************#
    # **************************** Updating slaves with new master information ***********************#
    # ************************************************************************************************#
    if [ $ClusterMembership == "Master" ]
    then
        echo
        color_echo "-------- Updating all slaves to have new master address -----------------------------"

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
        color_echo "--- Done"
        echo
    fi

    # ************************************************************************************************#
    # **************************** Starting cluster or just the server *******************************#
    # ************************************************************************************************#
    color_echo "-------- Starting CB Server on the remote machine -----------------------------------"
    remote_exec $remote_conn "$command start"
    color_echo "--- Done"
    echo

    # ************************************************************************************************#
    # **************************** Cleaning up temp files and closing the connection *****************#
    # ************************************************************************************************#
    cleanup_tmp_files
    close_ssh_tunnel $remote_conn
    # ************************************************************************************************#

    echo
    color_echo "-------- Master node is succesfully restored ----------------------------------------"
    echo
else
    slave_to_restore=$( get_tail_element $LOCAL_BACKUP_DIR '/' 2 )

    ret_val=$( read_cluster_config "Master" )

    MASTER_HOST=$( get_tail_element "$ret_val" '|' 3 )
    MASTER_USER=$( get_tail_element "$ret_val" '|' 2 )

    MASTER_BACKUPDIR="$MASTER_HOST/$(ls -t $MASTER_HOST | head -1)"
    tar xvf $MASTER_BACKUPDIR/cbconfig.tar -C $LOCAL_BACKUP_DIR/ /etc/cb/cb_ssh --strip-components 2
    chmod 0400 $slave_ssh_key

    open_ssh_tunnel $MASTER_USER $MASTER_HOST $MASTER_SSH_KEY
    master_conn=$last_conn

    if [ ! -f $slave_ssh_key ]
    then
        remote_copy $master_conn "/etc/cb/cb_ssh" "$LOCAL_BACKUP_DIR/" 1
    fi

    open_ssh_tunnel $REMOTE_USER $REMOTE_HOST $slave_ssh_key
    remote_conn=$last_conn

    remote_exec $remote_conn "mkdir -p $REMOTE_RESTORE_DIR"
    remote_copy $remote_conn "$LOCAL_BACKUP_DIR/*" "$REMOTE_RESTORE_DIR" 0 -r

    ret_val=$( read_cluster_config "Slave*" "Host" $slave_to_restore )
    slave_to_restore=$( get_tail_element "$ret_val" '|' 3 )

    if [ -z "$slave_to_restore" ];
    then
        echo "Please enter the minion that you are trying to restore"
        read slave_to_restore
    fi

    ret_val=$( read_cluster_config "Slave*" "Host" $slave_to_restore )
    slave_to_restore=$( get_tail_element "$ret_val" '|' 3 )
    shards=$(get_tail_element "$ret_val" '|' 1)
    shards=$(sed -r 's/shards(=|\s)//g' <<< "$shards")
    slave_name=$( get_tail_element "$ret_val" '|' 4 )
    node_id=$( get_tail_element "$ret_val" '|' 5 )

    #Stop CB-Enterprise
    #Clustered environment (on master run):
    remote_exec $master_conn "/usr/share/cb/cbcluster stop"

    if [ $( remote_exec $remote_conn "test -e '/etc/cb/cb.conf' && echo 1 || echo 0" ) == 0 ]
    then

        remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbyum.tar"
        remote_exec $remote_conn "yum -y install cb-enterprise"
    fi

    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbcerts.tar"
    remote_exec $master_conn "service cb-pgsql start"

    rm -rf $LOCAL_BACKUP_DIR/cbinit.py
    cat <<EOF >> $LOCAL_BACKUP_DIR/cbinit.py
from cb.core.cluster_config import ClusterConfig, Node
from cb.utils.db import db_session_context
from cb.db.core_models import SensorGroup
from cb.utils.config import Config
import re

config = Config()
config.load('/etc/cb/cb.conf')
cluster_config=ClusterConfig.load(config)

pgsql_password=''
default_sensor_server_url=''

match = re.search('//cb:(?P<pass>[^@]*)', config.DatabaseURL)
if match:
   pgsql_password=match.groups()[0]

with db_session_context(config) as db:
   default_sensor_server_url=db.query(SensorGroup).get(1).sensorbackend_server

init_config = """
[Config]
master_host=%s
root_storage_path=%s
pgsql_password=%s
service_autostart=0
force_reinit=1
cluster_membership=Slave
manage_iptables=%s
default_sensor_server_url=%s
rabbitmq_password=%s""" % (
    cluster_config.get_node(0)._configured_address,
    config.DatastoreRootDir,
    pgsql_password,
    1 if config.ManageIptables else 0,
    default_sensor_server_url,
    config.RabbitMQPassword
)

with open("$REMOTE_RESTORE_DIR/cbinit.conf",'w') as tmpfile:
    cbinit_conf = init_config
    tmpfile.write(cbinit_conf)
    tmpfile.flush()

EOF

    remote_exec $master_conn "mkdir -p $REMOTE_RESTORE_DIR"

    remote_copy $master_conn "$LOCAL_BACKUP_DIR/cbinit.py" "$REMOTE_RESTORE_DIR" 0
    remote_exec $master_conn "python $REMOTE_RESTORE_DIR/cbinit.py"

    rm -rf $LOCAL_BACKUP_DIR/cbupdate.py
    cat <<EOF >> $LOCAL_BACKUP_DIR/cbupdate.py
from cb.utils.db import db_session_context
from cb.db.core_models import SensorGroup, ClusterNodeSensorAddress
from cb.utils.config import Config
import re

config = Config()
config.load('/etc/cb/cb.conf')

with db_session_context(config) as db:
    node = db.query(ClusterNodeSensorAddress).get($node_id)
    node.address="$REMOTE_HOST"
    db.commit()
EOF

    remote_copy $master_conn "$LOCAL_BACKUP_DIR/cbupdate.py" "$REMOTE_RESTORE_DIR" 0
    remote_exec $master_conn "python $REMOTE_RESTORE_DIR/cbupdate.py"


    remote_exec $master_conn "service cb-pgsql stop"

    remote_copy $master_conn "$REMOTE_RESTORE_DIR/cbinit.conf" "$LOCAL_BACKUP_DIR" 1
    remote_copy $remote_conn "$LOCAL_BACKUP_DIR/cbinit.conf" "$REMOTE_RESTORE_DIR" 0

    remote_exec $master_conn "sed -i 's/$slave_to_restore/$REMOTE_HOST/g' /etc/cb/cluster.conf"

    remote_copy $master_conn "/etc/cb/cluster.conf" "$LOCAL_BACKUP_DIR" 1
    remote_copy $master_conn "$LOCAL_BACKUP_DIR/cluster.conf" "/etc/cb/" 0

    remote_exec $remote_conn "/usr/share/cb/cbinit --node-id $node_id $REMOTE_RESTORE_DIR/cbinit.conf"

    # Delete any stored ssh keys
    remote_exec $remote_conn "rm -rf /root/.ssh/known_hosts"

    # Restore Configuration Files
    # Restore Carbon Black Configuration files
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbconfig.tar"

    #Copy updated cluster config to all slaves
    copy_config_to_all_slaves $slave_ssh_key

    # Clear server.token
    remote_exec $remote_conn "rm -rf /etc/cb/server.token"

    # Grab new server.token
    token_command=$(printf '%q' "from cb.alliance.token_manager import SetupServerToken; SetupServerToken().set_server_token('/etc/cb/server.token')")
    remote_exec $remote_conn "python -c $token_command"


    # Restore SSH Keys
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbssh.tar"
    # Hosts file
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbhosts.tar"
    # Yum files
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbyum.tar"
    # IP Tables file
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbiptables.tar"
    # Rsyslog Configuration
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslog.tar"
    # Rsyslog.d Configuration
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslogd.tar"
    # logrotate Configuration
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cblogrotate.tar"
    # Remove Rabbitmq cookie
    remote_exec $remote_conn "rm -rf $DatastoreRootDir/../.erlang.cookie"
    # Remove Rabbitmq node Configuration
    remote_exec $remote_conn "rm -rf $RabbitMQDataPath"
    # Optional: SSH Authorization Keys - Needed if you have used trusted keys between systems in a clustered environment
    remote_exec $remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrootauthkeys.tar"
    # Remove RabbitMQDataPath
    remote_exec $master_conn "rm -rf $RabbitMQDataPath"
    # Start CB-Enterprise (on the Master) Once all minion nodes are restored
    # Clustered environment (on master run):
    remote_exec $master_conn "/usr/share/cb/cbcluster start"

    close_ssh_tunnel $remote_conn
    close_ssh_tunnel $master_conn
fi





