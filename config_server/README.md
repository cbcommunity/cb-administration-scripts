# Carbon Black Enterprise Response Server Configuration Script

## Overview

Carbon Black Enterprise Response Server Configuration Script is a standalone script designed to
initialize and configure a Cb Response Server to a configuration ini file specifications.  This gives Incident Response
 and Managed Security Service Providers the ability to ensure their Cb Response Server are configured the same way every time.  
 The script can be ran at initialization time to configure from fresh install or on an existing installation to re-initialization 
 configuration.  Besides the ability to (re)initialize a given Cb Response server you can run with script utilizing only API endpoints 
 and configure the running server to meet your needs.  In that it will enable all feeds,  optionally configure feed notifications,
 and group settings for tamper and banning all based on the settings identified withinthe associated configuration file.  
 The script can even be ran multiple times only changing configuration if it does not meet the specification as long as the --cbinit option is not used.

The configuration file utilizes standard INI based [format](https://en.wikipedia.org/wiki/INI_file).  In that it has a Section heading then the associated key name and value specification.


### Command line options

```
python ConfigServer.py -h
Usage: ConfigServer.py [options]

Configure Server based on configuration file and enable all Cb Threat
Intelligence feeds

Options:
  -h, --help            show this help message and exit
  -c SERVER_URL, --cburl=SERVER_URL
                        CB server's URL.  e.g., http://127.0.0.1
  -a TOKEN, --apitoken=TOKEN
                        API Token for Carbon Black server
  -n, --no-ssl-verify   Do not verify server SSL certificate.
  -f BUILDFILE, --file=BUILDFILE
                        Configuration.ini file that contains the configuration to be applied
  -r, --restart         Restart Cb-Enterpise Services upon completion of script.  If applying any cb.conf changes a Carbon Black Service restart will be required
  --cbinit              Execute the command /usr/share/cb/cbinit with the options from the configuration file
```

## Support

The script is supported via our [User eXchange (Jive)](https://community.carbonblack.com/groups/developer-relations) 
and via email to dev-support@carbonblack.com.  


## Cb Response Initialization 

Cb Response has the built in ability to automate the installation of a server.  The options available for automation are
documented on our [User eXchange.](https://community.carbonblack.com/docs/DOC-2245) In the provided exampled configuration.ini file
you will see the below options for customization

```
[Config]
# this is the /usr/share/cb/cbinit area
# you will want to fill in default_sensor_server_url & admin_password
# at a minimum 
# only used if you are following the Fresh Install Steps (Non-Cb Response Cloud)
root_storage_path=/var/cb/data
admin_username=cbadmin
admin_first_name=Cb
admin_last_name=Admin
admin_email=cbadmin@localhost.com
admin_password=PutSomethingHere
service_autostart=1
force_reinit=1
manage_iptables=1
alliance_comms_enabled=1
alliance_statistics_enabled=1
alliance_vt_hashes_enabled=1
alliance_vt_binaries_enabled=0
alliance_bit9_hashes_enabled=1
alliance_bit9_binaries_enabled=0
default_sensor_server_url=http://127.0.0.1
```
    
## Cb Response Post Initialization UI Customization

Carbon Black Enterprise Response Server Configuration Script gives you the ability to customize multiple areas
of the UI/API to your specific configuration.  Below is an example from the example ini

```
[Feed]
# Only the two following global notifications options are available: 
# Alerting (3) and/or Syslog (1) 
# So to configure 1 or 3 place the feed name below then put the associated notification type
abusech=1,3
alienvault=1,3
Bit9AdvancedThreats=1,3
Bit9EarlyAccess=1,3
Bit9SuspiciousIndicators=1,3
cbbanning=1,3
cbemet=1,3
cbtamper=1,3
fbthreatexchange=1,3
iconmatching=1,3
mdl=1,3
SRSThreat=1,3
tor=1,3
ThreatConnect=1,3
CbKnownIOCs=1,3
CbCommunity=1,3
sans=1,3
[Sharing]
# By default we do not enable Carbon Black Event
# data to be uploaded to Carbon Black
# Enabled (1) and Disabled (0)
ticevent=1
[Group]
# This section applies to all Groups
# By default we do not enable banning or tamper detection
# Enabled (1) and Disabled (0)
banning=1
tamper=1
```

## Cb Response Post Initialization cb.conf Customizations

Cb Response gives you the ability to customize the installation via `/etc/cb/cb.conf` this script gives you the ability to set all of those value in the ini and ensure they match in cb.conf.  This portion of the script will only execute if the script is ran locally on the Cb Response server.  Below is an example from the example ini

```
[cb.conf]
# Enable/Disable cblr functionality.  Disabled by default
# only configured if you are local to the Cb Response Server
CbLREnabled=True
```

## Quickstart Guide

The purpose of this document is to outline how to build a Carbon Black Server utilizing a configuration script.  This will provide Carbon Black (Cb) users the ability to rapidly deploy a configured Cb server. 

### Installation

#### Fresh Install Steps (On Premise Cb Response)

- Upload your specific Cb rpm file (license), ConfigServer.py, and configuration.ini files to the Cb server.
- If this is a clone of an existing server with cb-enterprise installed
    - Update the Carbon Black RPM (license)
        - `rpm --force -ivh <cb_rpm_file>.rpm`
    - Update Carbon Black Software & OS
        - `yum update`
- If this is a fresh Cb server without cb-enterprise installed
    - Install the Carbon Black RPM (license)
        - `rpm -ivh <cb_rpm_file>.rpm`
    - Install cb-enterprise on the Master
        - `yum install cb-enterprise`
    - Configure the “configuration.ini” file for your options
        - Required items to change: `default_sensor_server_url, admin_password, with recommended items of admin_email
the default_sensor_server_url should be the IP of the server or the DNS address`
- Initialize the Cb server using the configuration file:
    - `python ConfigServer.py -f configuration.ini -r --cbinit`
- Verify that the Web server is accessible at the `default_sensor_server_url` configured in above step by logging into WebUI
- Now all of your feeds, tamper/banning settings on the default group, and CbLR are now configured

#### Pre-Existing Cb Response Server (Cb Enterprise Response Cloud)

The following steps are available if you would like to ensure the existing server is configured to match configuration.ini file.
- Login into WebUI and pull the API token for the admin created on the install
    - Navigate to <username> in the upper right corner > Profile Info > API Token
copy to clipboard the API token
- To configure the Server with your options you will want to run the ConfigServer.py script
    - `python ConfigServer.py -c https://CbResponseURL  -a <apiToken> -n -f configuration.ini`
- Now all of your feeds, tamper/banning settings on the default group are now configured.
