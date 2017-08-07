#!/usr/bin/env python
#
#The MIT License (MIT)
#
# Copyright (c) 2015 Carbon Black
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# -----------------------------------------------------------------------------
# Carbon Black Enterprise Response Server Configuration Script is a standalone script designed to
# initialize and configure a Cb Response Server to a configuration ini file specifications.  This gives Incident Response
# and Managed Security Service Providers the ability to ensure their Cb Response Server is configured the same way every time.  
# The script can be ran at initialization time to configure a fresh install or on an existing installation to re-initialization 
# configuration.  Besides the ability to (re)initialize a given Cb Response server you can run the script utilizing only API endpoints 
# and configure the running server to meet your needs.  In that it will enable all feeds,  optionally configure feed notifications,
# and group settings for tamper and banning all based on the settings identified within the associated configuration file.  
# The script can even be ran multiple times only changing configuration if it does not meet the specification as long as the --cbinit option is not used.
#
#
#  created 2016-06-26 by Ryan Cason rcason@carbonblack.com
#
# ------------------------------------------------------------------------------
#  TODO:
#
# ------------------------------------------------------------------------------

import ConfigParser
import sys
import os
import subprocess
import optparse
import requests
import urlparse
import tempfile
import shutil
import json

try:
    from requests.packages.urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
    urllib3.disable_warnings()
except:
    pass
def load(input_file, section=None):
    dict={}
    section = section or 'Config'
    parser = ConfigParser.RawConfigParser()
    parser.optionxform = str
    parser.read(input_file)
    for prop, val in parser.items(section):
        dict[prop]=val
    return dict
def enable_feed_action(cb_server_url, api_token, config, ssl_verify=True, test=None ):
    if test:
        print "----Validating configuration against Feeds----"
    feeds = requests.get(urlparse.urljoin(cb_server_url, '/api/v1/feed'),
                         headers={'X-Auth-Token': api_token}, verify=ssl_verify)
    feeds.raise_for_status()
    for f in feeds.json():
        fn=f['name']
        fid=f['id']
        if f['enabled'] == False:
            f['enabled']=True
            if test:
                print "%s Feed not enabled" % (fn)
            else:
                data = json.dumps(f)
                requests.put(urlparse.urljoin(cb_server_url, '/api/v1/feed/{0}'.format(fid)),
                          data=data, headers={'X-Auth-Token': api_token}, verify=ssl_verify)
        if config.has_key(fn):
            f_actions = requests.get(urlparse.urljoin(cb_server_url, '/api/v1/feed/{0}/action'.format(fid)),
                                     headers={'X-Auth-Token': api_token}, verify=ssl_verify)
            c_action = config[fn].split(",")
            for c in c_action:
                if int(c) == 1 or int(c) == 3:
                    found=False
                    if f_actions.status_code == 200:
                        for f in f_actions.json():
                            if int(c) == int(f['action_type']):
                                found=True
                    if found == False:
                        if test:
                            print "%s Feed not configed for a type of %s" % (fn, c)
                        else:
                            print "Applying Feed Configuration for %s with %s" % (fn, c)
                            data = json.dumps({'action_type': int(c), 'watchlist_id': None, 'action_data':'{"email_recipients":[1]}', 'group_id':int(fid)})
                            requests.post(urlparse.urljoin(cb_server_url, '/api/v1/feed/{0}/action'.format(fid)),
                                      data=data, headers={'X-Auth-Token': api_token}, verify=ssl_verify)
def report_watchlist_action(cb_server_url, api_token,  ssl_verify=True):
    
    print "----Reporting all watchlists configured to alert----"
    watchlists = requests.get(urlparse.urljoin(cb_server_url, '/api/v1/watchlist'),
                         headers={'X-Auth-Token': api_token}, verify=ssl_verify)
    watchlists.raise_for_status()
    for w in watchlists.json():
        wn=w['name']
        wid=w['id']
        w_actions = requests.get(urlparse.urljoin(cb_server_url, '/api/v1/watchlist/{0}/action'.format(wid)),
                                     headers={'X-Auth-Token': api_token}, verify=ssl_verify)
        if w_actions.status_code == 200:
            found=False 
            for wa in w_actions.json():
                if 3 == int(wa['action_type']):
                    found=True
            if found == True:
                print "%s Watchlist configed for Alert" % (wn)

def configure_groups(cb_server_url, api_token, config , ssl_verify=True, test=None):

    if test:
        print "----Validating configuration against Groups----"
    groups = requests.get(urlparse.urljoin(cb_server_url, '/api/group'),
                         headers={'X-Auth-Token': api_token}, verify=ssl_verify)
    groups.raise_for_status()
    for g in groups.json():
        update=False
        if int(config['banning']) == 1 and g['banning_enabled'] == False:
            g['banning_enabled']=True
            update=True
            if test:
                print "%s Group not configured for banning" % (g['name'])
        if int(config['tamper']) == 1 and int(g['tamper_level']) == 0:
            g['tamper_level']=1
            update=True
            if test:
                print "%s Group not configured for tamper" % (g['name'])
        if update == True and not test:
            print "Updating Tamper and/or Banniing on Group %s" % (g['name'])
            data = json.dumps(g)
            requests.put(urlparse.urljoin(cb_server_url, '/api/group/{0}'.format(g['id'])),
                          data=data, headers={'X-Auth-Token': api_token}, verify=ssl_verify)

def enable_data_sharing(cb_server_url, api_token, config ,ssl_verify=True, test=None):

    if test:
        print "----Validating configuration against Sharing Settings----"
    groups = requests.get(urlparse.urljoin(cb_server_url, '/api/group'),
                         headers={'X-Auth-Token': api_token}, verify=ssl_verify)
    groups.raise_for_status()
    for g in groups.json():
        g_actions = requests.get(urlparse.urljoin(cb_server_url, '/api/v1/group/{0}/datasharing'.format(g['id'])),
                                 headers={'X-Auth-Token': api_token}, verify=ssl_verify).json()
        if int(config['ticevent']) == 1:
            for a in g_actions:
                found=False
                if "TICEVT" == a['what']:
                    found=True
            if found == False:
                if test:
                    print "%s Group not configured for Sharing Events" % (g['name'])
                else: 
                    print "Applying Event Sharing on Group %s" % (g['name'])
                    data = json.dumps({'group_id': int(g['id']), 'what': "TICEVT", 'who': "BIT9"})
                    requests.post(urlparse.urljoin(cb_server_url, '/api/v1/group/{0}/datasharing'.format(g['id'])),
                                      data=data, headers={'X-Auth-Token': api_token}, verify=ssl_verify)

def change_config_setting(setting, value, config,test=None):

    if test:
        print "----Validating configuration against %s----" % (config)
    found = False
    update = False
    fh, abs_path = tempfile.mkstemp()
    with open(abs_path, 'w') as new_file:
        with open(config, 'r') as old_file:
            for line in old_file:
                if line.lstrip().startswith('{0}='.format(setting)) or line.lstrip().startswith('#{0}='.format(setting)):
                    found = True
                    if str(value).strip() != str(line.strip().split("=")[1]) or line.lstrip().startswith('#{0}='.format(setting)):
                        if test:
                            print 'Incorrect Cb.conf option %s setting [setting=%s][value=%s]' % (config, setting, str(value))
                        else:
                            print 'Changing %s setting [setting=%s][value=%s]' % (config, setting, str(value))
                            new_file.write('{0}={1}\n'.format(setting, value.strip()))
                            update=True
                    else:
                       new_file.write(line) 
                else:
                    new_file.write(line)
            if not found:
                update=True
                new_file.seek(0, 2)
                new_file.write('\n{0}={1}\n'.format(setting, value))
    os.close(fh)
    if update==False:
        os.remove(abs_path)
    else:
        if test:
            os.remove(abs_path)
        else:
            os.remove(config)
            shutil.move(abs_path, config)
            subprocess.call(['/bin/chown','root:cb', config])
            subprocess.call(['/bin/chmod','644' ,config])


def update_cb_conf(config, test=None):
    for k,v in config.items():
        change_config_setting(k, v, '/etc/cb/cb.conf',test)

def get_apitoken(cb_server_url, username, password, ssl_verify=True):
    if cb_server_url.endswith('/'):
        aurl = cb_server_url + 'api/auth'
    else:
        aurl = cb_server_url + '/api/auth'

    # get the api token
    r = requests.get(aurl, auth=requests.auth.HTTPDigestAuth(username, password), verify=ssl_verify)
    r.raise_for_status()
    return r.json()['auth_token']



def build_cli_parser():
    parser = optparse.OptionParser(usage="%prog [options]", description="Configure Server based on configuration file and enable all Cb Threat Intelligence feeds")

    # for each supported output type, add an option
    #
    parser.add_option("-c", "--cburl", action="store", default=None, dest="server_url",
                      help="CB server's URL.  e.g., http://127.0.0.1 ")
    parser.add_option("-a", "--apitoken", action="store", default=None, dest="token",
                      help="API Token for Carbon Black server")
    parser.add_option("-n", "--no-ssl-verify", action="store_false", default=True, dest="ssl_verify",
                      help="Do not verify server SSL certificate.")
    parser.add_option("-f", "--file", action="store", default=False, dest="buildfile",
                      help="Configuration.ini file that contains the configuration to be applied")   
    parser.add_option("-r", "--restart", action="store_true", default=False, dest="servicerestart",
                      help="Restart Cb-Enterpise Services upon completion of script.  If applying any cb.conf changes a Carbon Black Service restart will be required")                        
    parser.add_option("--cbinit", action="store_true", default=False, dest="cbinit",
                      help="Execute the command /usr/share/cb/cbinit with the options from the configuration file")    
    parser.add_option("-t", "--test", action="store_true", default=False, dest="test",
                      help="Do NOT apply any configuration changes only test and report")
    
    return parser
    
def main(argv):
    parser = build_cli_parser()
    opts, args = parser.parse_args(argv)
    if not opts.buildfile:
        print "Missing required param; run with --help for usage"
        sys.exit(-1)
    if opts.cbinit and not opts.test:
        if os.path.isfile('/etc/cb/server.token'):
            os.remove('/etc/cb/server.token')
        print "Re-Initializing Carbon Black"
        subprocess.call(['/usr/share/cb/cbinit', opts.buildfile])  
    if not opts.server_url or not opts.token:
        cbconfig = load(opts.buildfile,section='Config')
        api_token = get_apitoken(cbconfig['default_sensor_server_url'], cbconfig['admin_username'], cbconfig['admin_password'], ssl_verify=opts.ssl_verify)
        api_server = cbconfig['default_sensor_server_url']
    else:
        api_token = opts.token
        api_server = opts.server_url
    feedconfig = load(opts.buildfile,section='Feed')
    enable_feed_action(api_server, api_token, feedconfig , opts.ssl_verify, opts.test)
    sharingconfig = load(opts.buildfile,section='Sharing')
    enable_data_sharing(api_server, api_token, sharingconfig, opts.ssl_verify, opts.test )
    groupconfig = load(opts.buildfile,section='Group')
    configure_groups(api_server, api_token, groupconfig, opts.ssl_verify, opts.test )
    if opts.test:
        report_watchlist_action(api_server, api_token, opts.ssl_verify)
    if os.path.isfile('/etc/cb/cb.conf'):
        cb_conf_config = load(opts.buildfile,section='cb.conf')
        update_cb_conf(cb_conf_config, opts.test )
        if opts.servicerestart and not opts.test:
            print "Restarting Carbon Black Services"
            subprocess.call(['/etc/init.d/cb-enterprise', 'restart'])
         

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
