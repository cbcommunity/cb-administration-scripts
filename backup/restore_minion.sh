#! /bin/bash

update_all_slaves_with_new_slave () {
    _master_conn=$1
    _local_backup_dir=$2
    _slave_key=$3
    _old_host=$4
    _new_host=$5
    _save_hosts=$6


    color_echo "-------- Copying cluster config and rabbitmq cookie from the master"
    # ********************************************************************************************#
    # **************************** Copying cluster.conf from the master *************************#
    # ********************************************************************************************#
    remote_copy $_master_conn "/etc/cb/cluster.conf" "$_local_backup_dir" 1
    # ********************************************************************************************#
    # **************************** Copying erlang.cookie from the master *************************#
    # ********************************************************************************************#
    remote_copy $_master_conn "/var/cb/.erlang.cookie" "$_local_backup_dir" 1

    _slave=0
    _slave_host=
    _slave_user=
    IFS="="
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
            color_echo "Updating $_slave_name [\e[0m$_slave_host\e[1;32m]"
            color_echo "--------------------------------------------------------------------------------------"

            color_echo "-------- Connecting using the key"
            open_ssh_tunnel $_slave_user $_slave_host $_slave_key

            OLD_IP=$( get_ip_from_hostname $_old_host )
            NEW_IP=$( get_ip_from_hostname $_new_host )

            color_echo "-------- Updating hosts file"
            update_host_file $_old_host $OLD_IP $_new_host $NEW_IP $last_conn $_save_hosts

            color_echo "-------- Updating iptables"
            remote_exec $last_conn "service iptables stop > /dev/null"
            remote_exec $last_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/sysconfig/iptables"
            remote_exec $last_conn "service iptables start > /dev/null"

            color_echo "-------- Stopping  cb-enterprise"
            remote_exec $last_conn "service cb-enterprise stop > /dev/null"
            remote_exec $last_conn "ps aux | grep rabbit | grep erlang | grep cb | awk '{print \$2}' | xargs kill -9 > /dev/null"

            color_echo "-------- Copying cluster.conf and rabbitmq cookie"
            remote_copy $last_conn "$_local_backup_dir/cluster.conf" "/etc/cb/" 0
            remote_copy $last_conn "$_local_backup_dir/.erlang.cookie" "/var/cb/" 0

            color_echo "-------- Removing RabbitMQ data folder"
            remote_exec $last_conn "rm -rf $RabbitMQDataPath"

            close_ssh_tunnel $last_conn
            color_echo "--- Done"
            unset _slave_user
            unset _slave_host
            _slave=0
        fi

    done < $_local_backup_dir/cluster.conf
    unset IFS
}

parse_slave_host_from_backup () {
    _local_backup_dir=$1
    
    _slave_host=$( get_tail_element "$_local_backup_dir" '/' 1 )
    _ret_val=$( read_cluster_config "Slave*" "Host" $_slave_host )
    _slave_host=$( get_tail_element "$_ret_val" '|' 3 )

    while [ -z "$_slave_host" ];
    do
        echo "Please enter the minion that you are trying to restore as it appears in cluster.conf file"
        read _slave_host
        _ret_val=$( read_cluster_config "Slave*" "Host" $_slave_host )
        _slave_host=$( get_tail_element "$_ret_val" '|' 3 )
    done
    
    echo "$_slave_host"
}

install_cb_enterprise() {
    _remote_conn=$1
    _remote_backup_dir=$2
    if [ ! $( remote_exec $_remote_conn "test -e /etc/cb/cb.conf && echo 1 || echo 0" ) == 1 ]
    then
        color_echo "-------- CB Server is NOT installed on the remote machine ----------------------------"
        color_echo "-------- Installing CB server"
        remote_exec $_remote_conn "tar -P -xf $_remote_backup_dir/cbyum.tar"
        remote_exec $_remote_conn "yum -y install cb-enterprise"
        color_echo "--- Done"
    fi
}

generate_init_conf(){
    _master_conn=$1
    _slave_conn=$2
    _local_backup_dir=$3
    _remote_backup_dir=$4

    color_echo "-------- Generating config file for initialization"

    rm -rf $_local_backup_dir/cbinit.py
    cat <<EOF >> $_local_backup_dir/cbinit.py
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

with open("$_remote_backup_dir/cbinit.conf",'w') as tmpfile:
    cbinit_conf = init_config
    tmpfile.write(cbinit_conf)
    tmpfile.flush()

EOF

    remote_exec $_master_conn "mkdir -p $_remote_backup_dir"
    remote_copy $_master_conn "$_local_backup_dir/cbinit.py" "$_remote_backup_dir" 0
    remote_exec $_master_conn "service cb-pgsql start > /dev/null"
    remote_exec $_master_conn "python $_remote_backup_dir/cbinit.py"
    remote_exec $_master_conn "service cb-pgsql stop > /dev/null"
    remote_copy $_master_conn "$_remote_backup_dir/cbinit.conf" "$_local_backup_dir" 1

    rm -rf $_local_backup_dir/cbinit.py
}

update_master_with_new_slave() {
    _master_conn=$1
    _local_backup_dir=$2
    _slave_host=$3
    _slave_node_id=$4
    _new_slave_host=$5

    rm -rf $_local_backup_dir/cbupdate.py
    cat <<EOF >> $_local_backup_dir/cbupdate.py
from cb.utils.db import db_session_context
from cb.db.core_models import SensorGroup, ClusterNodeSensorAddress
from cb.utils.config import Config
import re

config = Config()
config.load('/etc/cb/cb.conf')

with db_session_context(config) as db:
    node = db.query(ClusterNodeSensorAddress).get($_slave_node_id)
    node.address="$_new_slave_host"
    db.commit()
EOF

    OLD_IP=$( get_ip_from_hostname $_slave_host )
    NEW_IP=$( get_ip_from_hostname $_new_slave_host )

    color_echo "-------- Updating hosts file"
    update_host_file $_slave_host $OLD_IP $_new_slave_host $NEW_IP $_master_conn $SAVE_HOSTS

    color_echo "-------- Updating cluster.conf"
    remote_exec $_master_conn "sed -i 's/$_slave_host\$/$_new_slave_host/g' /etc/cb/cluster.conf"
    remote_exec $_master_conn "sed -i 's/$OLD_IP/$_new_slave_host/g' /etc/cb/cluster.conf"
    color_echo "-------- Updating iptables"
    remote_exec $_master_conn "service iptables stop  > /dev/null"
    remote_exec $_master_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/sysconfig/iptables"
    remote_exec $_master_conn "service iptables start > /dev/null"

    color_echo "-------- Updating slave address in the db"
    remote_exec $_master_conn "service cb-pgsql start > /dev/null"
    remote_copy $_master_conn "$_local_backup_dir/cbupdate.py" "$_remote_backup_dir" 0
    remote_exec $_master_conn "python $_remote_backup_dir/cbupdate.py"
    remote_exec $_master_conn "service cb-pgsql stop  > /dev/null"

    # Remove RabbitMQDataPath
    color_echo "-------- Removing RabbitMQ data folder"
    remote_exec $_master_conn "ps aux | grep rabbit | grep erlang | grep cb | awk '{print \$2}' | xargs kill -9"
    remote_exec $_master_conn "rm -rf $RabbitMQDataPath"

    rm -rf $_local_backup_dir/cbupdate.py
}

init_slave_node () {
    _master_conn=$1
    _slave_conn=$2
    _local_backup_dir=$3
    _remote_backup_dir=$4
    _slave_host=$5
    _new_slave_host=$6
    _slave_node_id=$7

    OLD_IP=$( get_ip_from_hostname $_slave_host )

    color_echo "-------- Copying config file for initialization"
    remote_copy $_master_conn "$_local_backup_dir/cbinit.conf" "$_remote_backup_dir" 0
    remote_copy $_master_conn "/etc/cb/cluster.conf" "$_local_backup_dir" 1
    remote_exec $_slave_conn "tar -P -xf $_remote_backup_dir/cbcerts.tar"

    sed -i "s/$_slave_host\$/$_new_slave_host/g" $_local_backup_dir/cluster.conf
    sed -i "s/$OLD_IP/$_new_slave_host/g" $_local_backup_dir/cluster.conf
    remote_copy $_slave_conn "$_local_backup_dir/cluster.conf" "/etc/cb/" 0

    color_echo "-------- Running cbinit command"
    remote_exec $_slave_conn "/usr/share/cb/cbinit --node-id $_slave_node_id $_remote_backup_dir/cbinit.conf > /dev/null"
}

restore_slave_backup (){
    _remote_conn=$1

    # Delete any stored ssh keys
    remote_exec $_remote_conn "rm -rf /root/.ssh/known_hosts"
    # Restore Hosts file
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbhosts.tar"
    # Restore Configuration Files
    # Restore Carbon Black Configuration files
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbconfig.tar"
    # Restore SSH Keys
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbssh.tar"
    # Yum files
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbyum.tar"
    # IP Tables file
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbiptables.tar"
    # Rsyslog Configuration
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslog.tar"
    # Rsyslog.d Configuration
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslogd.tar"
    # logrotate Configuration
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cblogrotate.tar"
    # Optional: SSH Authorization Keys - Needed if you have used trusted keys between systems in a clustered environment
    remote_exec $_remote_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrootauthkeys.tar"
}