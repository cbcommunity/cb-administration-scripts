# WIP
# Backup and Restore Scripts

## Backup

The script is meant to run on a standalone box.

```bash
bash backup.sh [-h help] -r host -u user [-b path] [-k key] [-m master host] [-mu master user] [-mk master key] [-ma backup all slaves] [-ss 1]

where:
    -r, --remote        Remote server IP address or Hostname. This server is used to restore the backup on.
    -u, --user          User to connect to the remote server
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
    -u, --user          Remote user to connect with
    -b, --backup        Folder where the backup is
    -k, --key           Optional. ssh key that can be used to connect to the remote server
    -s, --save-hosts    Optional. Save new (ipaddress, hostname) entry to the hosts file on all nodes in the cluster including master
                        Only needed if previous setup did not have host entries for cluster nodes in the hosts file
```

###Examples:
#####`Master` restore
`bash restore.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups/YYYY-MM-DD-HH-mm-ss`

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
`bash restore.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups/YYYY-MM-DD-HH-mm-ss`

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
