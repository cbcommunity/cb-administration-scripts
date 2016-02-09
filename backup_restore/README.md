# WIP
# Backup and Restore Scripts

## Backup

The script is meant to be run on a separate from CB cluster machine, but can be run on the same as well.

bash backup.sh [-h help] | -r host -u user [-b path] [-k key] [-m master host] [-mu master user] [-mu backup all slaves] [-mk master key]

where:
    -r, --remote        Ip address or the hostname of the remote server to restore the backup on
    -u, --user          User to use for remote server connection
    -b, --backup        Optional. Folder path to store backup. If not provided current folder is used
    -k, --key           Optional. Ssh key that can be used to connect to the remote server
    -m, --master        Optional. In case of slave backup master host can be provided to avoid prompting for the password too many times
    -mu, --master-user  Optional. In case of slave backup master user can be provided to avoid prompting for the password too many times
    -mk, --master-key   Optional. Ssh key that can be used to connect to the master
    -ma, --master-all   Optional. Backup master and all slaves. Ingnored if remote server is in standalone or slave mode


All backups are created under BASE_FOLDER/YYYY-DD-MM-HH-mm-ss/HOSTNAME
Where
    BASE_FOLDER can be provided as command line argument. Otherwise it set to a current directory of the script
    HOSTNAME is an IP address or a hostname

###Examples:
####Assuming 10.X.Y.Z is in Master mode
To backup master ONLY node under ./all_backups folder
    If you have master ssh key:
        bash backup.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups

        This command will
            ssh into the master using the key
            stop it
            create all necessary archives
            copy archives under ./all_backups folder/YYYY-DD-MM-HH-mm-ss/10.X.Y.Z folder
            start the master back

    If you dont have master ssh key:
        bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups

        Same as the previous one, but since [-k master_key] is not provided the script will prompt you for the password first.

To backup master node and ALL SLAVES
    bash backup.sh -r 10.X.Y.Z -u root -k master_key -b ./all_backups -ma 1

    This command will
        ssh into the master using the key
        stop the cluster
        create all necessary archives,
        copy archives under ./all_backups folder/YYYY-DD-MM-HH-mm-ss/10.X.Y.Z folder
        Then it will copy cb_ssh key to the local machine;
        Using this key the script will
            ssh into each slave
            perform a backup for each one
            save the backup under corresponding ./all_backups/YYYY-DD-MM-HH-mm-ss/SLAVE_HOST folder, where SLAVE_HOST is a HOST entry in the cluster.conf for the slave node.
        Start the cluster back

In order to have the key available on the master the user will have to generate it first and copy it to the master node manually
    ssh-keygen –t rsa –b 2048 -C "youremail@email.com"
    ssh-copy-id MASTER_HOST -i PATH_TO_PUB_KEY

####Assuming 10.X.Y.Z is in Slave mode
To backup slave node
    if you have master key and master info available:
        bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups -m 10.X.Y.W -mu root -mk master_ky

        This command will
            ssh into the master first using the key
            stop the cluster
            get cb_ssh key from the master
            ssh into the 10.X.Y.Z using cb_ssh key from the master
            perform backup of the slave
            copy the backup under ./all_backups folder/YYYY-DD-MM-HH-mm-ss/10.X.Y.Z folder
            start the cluser back

    if you don't master info available:
        bash backup.sh -r 10.X.Y.Z -u root -b ./all_backups

        This command will
            ssh into 10.X.Y.Z
            find out that this node is a slave node
            copy it's cluster.conf
            get master information from cluster conf
            ssh into the master
            stop the cluster
            perform backup of the slave
            copy the backup under ./all_backups folder/YYYY-DD-MM-HH-mm-ss/10.X.Y.Z folder
            start the cluser back


## Restore
