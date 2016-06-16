# WIP
# Backup and Restore Scripts

## Backup

The script is meant to run on a standalone box.

```bash
bash backup.sh [-h help] -r host -u user [-b path] [-k key] [-m master host] [-mu master user] [-mk master key] [-ma backup all slaves] [-ss 1]

where:
    -r, --remote        Remote server IP address or Hostname that should be backed up.
    -u, --user          User to connect to the remote server
                        If non root user is used to control the cluster or connect to the remote machine this user has to be added to the sudoers file.
                        See the Non-root section below
    -b, --backup        Optional. Base path to store the backup in. If not provided the current folder is used
    -k, --key           Optional. Ssh key that to connect to the remote server. If not provided user will be prompted for the password
    -m, --master        Optional. Master IP address or Hostname. Slave backups only. If hostname and master key is provided slave can be accessed without password
    -mu, --master-user  Optional. User to connect to the master server. Slave backups only. Root is used if not provided
    -mk, --master-key   Optional. Master ssh key
    -ma, --master-all   Optional. Backup master and all slaves. Master backups only. Ingnored if remote server is in standalone or slave mode
    -ss, --skip-stop    Optional. Skip stopping the cluster/master while backing up
```

All backups are created under `BASE_FOLDER/YYYY-MM-DD-HH-mm-ss/HOSTNAME`

Where:
+ `BASE_FOLDER` can be provided as command line argument. Otherwise it is set to a current directory of the script
+ `HOSTNAME` is an IP address or a hostname

###Examples:
#####`Master` only backup. Saved under `./all_backups folder`
######Master ssh key is present:
`bash backup.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups`

This command will:
- ssh into the master using the key
- stop the cluster/master (unless requested to skip stop)
- perform the backup
- copy backup files under `./all_backups folder/YYYY-MM-DD-HH-mm-ss/10.X.Y.Z` folder
- start the cluster/master back (unless requested to skip stop)

######Master ssh key is not present:
`bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups`

Same as the previous one, but since `[-k master_key]` is not provided the script will prompt you for the password first.

<br>
#####`Master` and `ALL SLAVES` backup. Saved under `./all_backups folder`
`bash backup.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups -ma 1`

This command will:
- ssh into the master using the key
- stop the cluster (unless requested to skip stop)
- perform backup of the master
- copy backup files in *./all_backups folder/YYYY-MM-DD-HH-mm-ss/10.X.Y.Z* folder
- Then it will copy cb_ssh key to the local machine;
- Using this key the script will
 - ssh into each slave
 - perform a backup for each one
 - save the backup under *./all_backups/YYYY-MM-DD-HH-mm-ss/SLAVE_HOST* folder, 
 -- where `SLAVE_HOST` is a `HOST` entry in the cluster.conf for the corresponding slave node.
- Start the cluster back (unless requested to skip stop)

> In order to have the key available on the master the user will have to generate it first and copy it to the master node manually
> - ssh-keygen –t rsa –b 2048 -C "youremail@email.com"
> - ssh-copy-id MASTER_HOST -i PATH_TO_PUB_KEY

<br>
#####`Slave` backup
######Master key and Master info available:
`bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups -m 10.X.Y.W -mu root -mk master_ky`

This command will:
- ssh into the `master` first using the key
- stop the cluster (unless requested to skip stop)
- get `cb_ssh` key from the master
- ssh into the `10.X.Y.Z` using `cb_ssh` key
- perform backup of the slave
- copy the backup under `./all_backups folder/YYYY-MM-DD-HH-mm-ss/10.X.Y.Z` folder
- start the cluser back (unless requested to skip stop)

######Master key and Master info NOT available:
`bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups`

This command will:
- ssh into `10.X.Y.Z`
- find out that this node is a `slave` node
- copy it's `cluster.conf`
- get master information from `cluster.conf`
- ssh into the `master`
- stop the cluster (unless requested to skip stop)
- perform backup of the slave
- copy the backup under `./all_backups folder/YYYY-MM-DD-HH-mm-ss/10.X.Y.Z` folder
- start the cluser back (unless requested to skip stop)


## Restore

The script is meant to run on a standalone box

```
bash restore.sh [-h help] -r host -u user -b path [-k key] [-s 1]

where:
    -r, --remote        Ip address or the hostname of the remote server to restore the backup on
    -na, --node-addr    Ip address or the hostname that will be used for Node Url (Server Node Url and Default Sensor Group Url in case of master restore)
                        Not validated, must be correct IP Address or Hostname that is resolvable on the target machine
    -u, --user          Remote user to connect with.
                        If non root user is used to control the cluster or connect to the remote machine this user has to be added to the sudoers file.
                        See the Non-root section below
    -b, --backup        Folder where the backup is
    -k, --key           Optional. ssh key that can be used to connect to the remote server
    -s, --save-hosts    Optional. Save new (ipaddress, hostname) entry to the hosts file on all nodes in the cluster including master
                        Only needed if previous setup did not have host entries for cluster nodes in the hosts file
```

###Examples:
#####`Master` restore
`bash restore.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups/YYYY-MM-DD-HH-mm-ss/<HOSTNAME>`

This command will:
- ssh into the `master` using the key
- copy backup to the remote
- check if CB server is installed
- `IF NOT`
 - extract yum folder from the bakup on `master`
 - copy certs to the `master`
 - install CB Server in standalone mode
 - initialize CB server in cluster mode with shard number from the backup
- stop the cluster
- perform restore of backup on the master
- update `master's` DB with new master info
- update `/etc/hosts` file and `iptables` with new master info if necessary
- update `cluster.conf` with new master info
- Using `cb_ssh` key
 - ssh into each slave
 - update `/etc/hosts` file and `iptables` with new master info if necessary
 - update `cluster.conf` with new master info
- Start the cluster back

#####`Slave` restore
`bash restore.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups/YYYY-MM-DD-HH-mm-ss/<HOSTNAME>`

This command will:
- get `master's` info from the backup
- ssh into the `master` using the key
- copy `cb_ssh` key from master
- ssh into the `slave` using the `cb_ssh` key
- copy backup to the remote slave
- check if CB server is installed
- `IF NOT`
 - extract yum folder from the bakup on `slave`
 - copy certs to the `slave`
 - install CB Server in standalone mode
- generate config file for `slave` initialization
- initialize CB server in `slave` mode with init config
- stop the cluster
- perform restore of backup on the `slave`
- update `/etc/hosts` file and `iptables` with new `slave` info if necessary on `slave` node
- update `cluster.conf` with new `slave` info on `slave` node
- update `/etc/hosts` file and `iptables` with new `slave` info if necessary on `master` node
- update `cluster.conf` with new `slave` info on `master` node
- Using `cb_ssh` key
 - ssh into each slave
 - update `/etc/hosts` file and `iptables` with new `slave` info if necessary
 - update `cluster.conf` with new `slave` info
- Start the cluster back

# Non-root users

Paste this at the end of your sudoers file and replace `nonroot` with your user name

```
## Required sudo privileges on minion to run cbcluster add-node
Cmnd_Alias HOSTNAME = /bin/hostname
Cmnd_Alias CB_INIT = /usr/share/cb/cbinit
Cmnd_Alias YUM_INSTALL_CB = /usr/bin/yum install cb-enterprise -y
Cmnd_Alias YUM_INSTALL_RSYNC = /usr/bin/yum install rsync -y
Cmnd_Alias MKDIR_ETC_CB = /bin/mkdir /etc/cb --mode=755
Cmnd_Alias MKDIR_ETC_CB_CERTS = /bin/mkdir /etc/cb/certs --mode=755
Cmnd_Alias COPY_ALLIANCE_CRT = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/carbonblack-alliance-client.crt /etc/cb/certs/carbonblack-alliance-client.crt
Cmnd_Alias COPY_SERVER_CRT = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/cb-server.crt /etc/cb/certs/cb-server.crt
Cmnd_Alias COPY_CLIENT_CA_CRT = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/cb-client-ca.crt /etc/cb/certs/cb-client-ca.crt
Cmnd_Alias COPY_ALLIANCE_KEY = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/carbonblack-alliance-client.key /etc/cb/certs/carbonblack-alliance-client.key
Cmnd_Alias COPY_SERVER_KEY = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/cb-server.key /etc/cb/certs/cb-server.key
Cmnd_Alias COPY_CLIENT_CA_KEY = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/cb-client-ca.key /etc/cb/certs/cb-client-ca.key
Cmnd_Alias COPY_CB_REPO = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/CarbonBlack.repo /etc/yum.repos.d/CarbonBlack.repo
Cmnd_Alias COPY_CLUSTER_CONF = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/cluster.conf /etc/cb/cluster.conf
Cmnd_Alias COPY_ERLANG_COOKIE = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/.erlang.cookie /var/cb/.erlang.cookie
Cmnd_Alias COPY_SERVER_LIC = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/server.lic /etc/cb/server.lic
Cmnd_Alias COPY_SERVER_TOKEN = /usr/bin/rsync --remove-source-files --verbose /tmp/.cb_tmp/server.token /etc/cb/server.token
Cmnd_Alias CBCHECK_IP_TABLES = /usr/share/cb/cbcheck iptables --apply
Cmnd_Alias CB_ENTERPRISE = /etc/init.d/cb-enterprise
Cmnd_Alias CAT_VERSION = /bin/cat /usr/share/cb/VERSION

## Required sudo privileges on minion to backup and restore
Cmnd_Alias CB_CLUSTER = /usr/share/cb/cbcluster
Cmnd_Alias CP= /bin/cp
Cmnd_Alias RM= /bin/rm
Cmnd_Alias MKDIR= /bin/mkdir
Cmnd_Alias CHOWN= /bin/chown
Cmnd_Alias TAR= /bin/tar
Cmnd_Alias TEST= /usr/bin/test
Cmnd_Alias SERVICE= /sbin/service
Cmnd_Alias SED= /bin/sed
Cmnd_Alias PGDUMP_ALL= /usr/bin/pg_dumpall
Cmnd_Alias PGDUMP= /usr/bin/pg_dump
Cmnd_Alias DATE= /bin/date
Cmnd_Alias PYTHON= /usr/bin/python
Cmnd_Alias KILL= /bin/kill
Cmnd_Alias PS= /bin/ps
Cmnd_Alias BASH= /bin/bash
Cmnd_Alias FIND= /bin/find
Cmnd_Alias DROPDB= /usr/bin/dropdb
Cmnd_Alias PSQL= /usr/bin/psql
Cmnd_Alias YUM= /usr/bin/yum

nonroot  ALL=(ALL)  NOPASSWD: YUM, PSQL, DROPDB, FIND, BASH, PS, KILL, PYTHON, DATE, PGDUMP, SED, PGDUMP_ALL, SERVICE, TEST, TAR, RM, CHOWN, CP, MKDIR, CB_CLUSTER, HOSTNAME, CB_INIT, YUM_INSTALL_CB, YUM_INSTALL_RSYNC, MKDIR_ETC_CB, MKDIR_ETC_CB_CERTS, COPY_ALLIANCE_CRT, COPY_SERVER_CRT, COPY_CLIENT_CA_CRT, COPY_ALLIANCE_KEY, COPY_SERVER_KEY, COPY_CLIENT_CA_KEY, COPY_CB_REPO, COPY_CLUSTER_CONF, COPY_ERLANG_COOKIE, COPY_SERVER_LIC, COPY_SERVER_TOKEN, CBCHECK_IP_TABLES, CB_ENTERPRISE, CAT_VERSION
```
