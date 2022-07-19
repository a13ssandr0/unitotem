from json import JSONDecodeError, dumps, loads
from os.path import exists, join, isfile, getsize, abspath
from subprocess import run
from threading import Thread
from time import sleep, time
from uuid import uuid4
from sys import exit

from crontab import CronTab
from flask import Flask, render_template, request
from flask_httpauth import HTTPBasicAuth
from PyChromeDevTools import ChromeInterface
from pymediainfo import MediaInfo
from requests.exceptions import ConnectionError
from shutil import disk_usage
from validators import url as is_valid_url
from werkzeug.utils import secure_filename
from werkzeug.security import generate_password_hash, check_password_hash
from waitress import serve

from sysman import *

VERSION = '2.0.0-beta'

APT_THREAD       = Thread()
AUDIO_DEVICES    = [('a', 'Auto')] + get_audio_devices()
AUTH             = HTTPBasicAuth()
CFG_FILE         = '/etc/unitotem/unitotem.conf'
CHROME           = ChromeInterface(auto_connect=False)
CONFIG           = {'urls': [],'default_duration': 30, 'users': {'admin': {'pass': generate_password_hash("admin")}}}
CRONTAB_FILE     = '/etc/crontab'
CURRENT_ASSET    = -1
DEF_AUDIO_DEV    = get_default_audio_device()
DEF_WIFI_CARD    = get_ifaces(IF_WIRELESS)[0]
DEFAULT_AP       = None
HOSTNAME         = get_hostname()
IS_FIRST_BOOT    = False
NEXT_CHANGE_TIME = 0
OS_VERSION       = os_version()
WWW              = Flask(__name__)
WWW.config['MAX_CONTENT_LENGTH']    = 512 * 1000 * 1000 # 512MB
WWW.config['TEMPLATES_AUTO_RELOAD'] = True
WWW.config['UPLOAD_FOLDER']         = './static/uploaded/'


def save_config():
    global CONFIG, IS_FIRST_BOOT
    with open(CFG_FILE, 'w') as conf_f:
        conf_f.write(dumps(CONFIG, indent=4))
        IS_FIRST_BOOT = False

def load_config():
    if not exists(CFG_FILE): return False
    global CONFIG
    should_update_file = False
    with open(CFG_FILE, 'r') as conf_f:
        try:
            cfg_tmp = loads(conf_f.read())
            for k, v in CONFIG.items():
                if k not in cfg_tmp:
                    cfg_tmp[k] = v
                    should_update_file = True
            CONFIG = cfg_tmp
        except JSONDecodeError:
            should_update_file = True
    if should_update_file:
        save_config()
    return True

def enabled_asset_count():
    cnt = 0
    for e in CONFIG['urls']:
        if e['enabled']:
            cnt += 1
    return cnt

def human_readable_size(size, decimal_places=2):
    for unit in ['B','KiB','MiB','GiB','TiB']:
        if size < 1024.0:
            break
        size /= 1024.0
    return f"{size:.{decimal_places}f}{unit}"

def list_resources():
    return [f for f in listdir(WWW.config['UPLOAD_FOLDER']) if isfile(join(WWW.config['UPLOAD_FOLDER'], f))]

def get_resources():
    files = []
    for f in listdir(WWW.config['UPLOAD_FOLDER']):
        if isfile(join(WWW.config['UPLOAD_FOLDER'], f)):
            dur = ''
            dur_s = ''
            for track in MediaInfo.parse(join(WWW.config['UPLOAD_FOLDER'], f)).tracks:
                if 'other_duration' in track.to_data():
                    dur = track.to_data()['other_duration'][1]
                    dur_s = round(int(track.to_data()['duration'])/1000)
                    break
                elif 'duration' in track.to_data():
                    dur = track.to_data()['duration']
                    dur_s = round(int(dur)/1000)
                    break
            files.append({
                'filename': f,
                'size': human_readable_size(getsize(join(WWW.config['UPLOAD_FOLDER'], f))),
                'duration': dur,
                'duration_s': dur_s
            })
    return files

@WWW.route("/", methods=['GET', 'POST'])
@AUTH.login_required
def scheduler():
    return render_template('index.html', 
        ut_vers=VERSION,
        logged_user=AUTH.current_user(),
        disp_size=get_display_size(),
        disk_used=human_readable_size(disk_usage(WWW.config['UPLOAD_FOLDER']).used),
        disk_total=human_readable_size(disk_usage(WWW.config['UPLOAD_FOLDER']).total),
        urls_list=CONFIG['urls'],
        default_duration=CONFIG['default_duration'],
        files_list=get_resources()
    )

@WWW.route("/settings", methods=['GET', 'POST'])
@AUTH.login_required
def settings():
    return render_template('settings.html',
        ut_vers = VERSION,
        logged_user = AUTH.current_user(),
        disp_size=get_display_size(),
        disk_used=human_readable_size(disk_usage(WWW.config['UPLOAD_FOLDER']).used),
        disk_total=human_readable_size(disk_usage(WWW.config['UPLOAD_FOLDER']).total),
        upd = get_upd_count(),
        is_updating = APT_THREAD.name == 'update' and APT_THREAD.is_alive(),
        is_upgrading = APT_THREAD.name == 'upgrade' and APT_THREAD.is_alive(),
        hostname = HOSTNAME,
        netplan_config = {fname.removesuffix('.yaml'): get_netplan_file(fname) for fname in get_netplan_file_list()},
        default_duration = CONFIG['default_duration'],
        audio = AUDIO_DEVICES,
        def_audio_dev = DEF_AUDIO_DEV,
        crontab = [job for job in CronTab(user='root').crons if job.comment.startswith('unitotem:-)')],
        def_wifi = DEF_WIFI_CARD
    )

@WWW.route("/api", methods=['GET', 'POST'])
@AUTH.login_required
def main_controller():
    try:
        if request.method == 'POST' and request.files:
            # check if the post request has the file part
            for file in request.files.values():
                if file and file.filename:
                    file.save(join(WWW.config['UPLOAD_FOLDER'], secure_filename(file.filename)), buffer_size=64 * 1024 * 1024)
            return '\n'

        return handle_api(request.json if request.is_json else dict(request.args))

    except Exception as e:
        return str(e) + '\n', 500

    return '\n'

def handle_api(request_data):
    global NEXT_CHANGE_TIME, CURRENT_ASSET, CONFIG, IS_FIRST_BOOT, APT_THREAD
    
    response = type('obj', (object,), {'data': '\n', 'code': 200})

    if 'reboot' in request_data:
        run('/usr/sbin/reboot')

    elif 'shutdown' in request_data:
        run('/usr/sbin/poweroff')

    elif 'add_asset' in request_data:
        if is_valid_url(request_data['add_asset']) or request_data['add_asset'] in list_resources():
            CONFIG['urls'].append({
                'url': ('file:' if request_data['add_asset'] in list_resources() else '') + request_data['add_asset'],
                'duration': int(request_data.get('duration', CONFIG['default_duration'])),
                'enabled': bool(request_data.get('enabled', False))
            })
            save_config()
        else: response.code = 406

    elif 'set-state' in request_data:
        for index, elem in enumerate(CONFIG['urls']):
            if request_data['url'] == elem['url']:
                initiate_rotation = not enabled_asset_count()
                CONFIG['urls'][index]['enabled'] = 'enabled' in request_data['set-state']
                save_config()
                if initiate_rotation:
                    chrome_goto(0)
                elif index == CURRENT_ASSET:
                    NEXT_CHANGE_TIME = int(time())
                break

    elif 'update-duration' in request_data:
        for index, elem in enumerate(CONFIG['urls']):
            if request_data['url'] == elem['url']:
                old_dur = CONFIG['urls'][index]['duration']
                CONFIG['urls'][index]['duration'] = int(request_data['update-duration'])
                save_config()
                if index == CURRENT_ASSET:
                    NEXT_CHANGE_TIME += (CONFIG['urls'][index]['duration'] - old_dur) if CONFIG['urls'][index]['duration'] else float('inf')
                break

    elif 'delete' in request_data:
        for elem_n in range(len(CONFIG['urls'])):
            if request_data['delete'] == CONFIG['urls'][elem_n]['url']:
                try:
                    if CONFIG['urls'][CURRENT_ASSET]['url'] == CONFIG['urls'][elem_n]['url']:
                        NEXT_CHANGE_TIME = int(time())
                finally:
                    CONFIG['urls'].pop(elem_n)
                    save_config()
                    break

    elif 'delete_file' in request_data:
        if exists(join(WWW.config['UPLOAD_FOLDER'], request_data['delete_file'])):
            removefile(join(WWW.config['UPLOAD_FOLDER'], request_data['delete_file']))

    elif 'goto' in request_data:
        chrome_goto(int(request_data['goto']), force=True)

    elif 'reorder' in request_data:
        CONFIG['urls'].insert(int(request_data['to'])+1, CONFIG['urls'].pop(int(request_data['from'])))
        save_config()
        if CURRENT_ASSET == int(request_data['to'])+1 or CURRENT_ASSET == int(request_data['from']):
            chrome_goto()

    elif 'back' in request_data:
        chrome_goto(CURRENT_ASSET-1, backwards=True)

    elif 'refresh' in request_data:
        CHROME.Page.reload()

    elif 'next' in request_data:
        chrome_goto(CURRENT_ASSET+1)

    elif 'set_def_duration' in request_data:
        CONFIG['default_duration'] = int(request_data['set_def_duration'])
        save_config()

    elif 'update' in request_data:
        if not APT_THREAD.is_alive():
            APT_THREAD = Thread(target=apt_update, name='update')
            APT_THREAD.start()

    elif 'update_count' in request_data:
        response.data = str(get_upd_count()) + '\n'

    elif 'upgrade' in request_data:
        if not APT_THREAD.is_alive():
            APT_THREAD = Thread(target=apt_upgrade, name='upgrade')
            APT_THREAD.start()

    elif 'is_updating' in request_data:
        response.data = dumps(APT_THREAD.name == 'update' and APT_THREAD.is_alive()) + '\n'

    elif 'is_upgrading' in request_data:
        response.data = dumps(APT_THREAD.name == 'upgrade' and APT_THREAD.is_alive()) + '\n'

    elif 'set_passwd' in request_data:
        CONFIG['users'][AUTH.current_user()]['pass'] = generate_password_hash(request_data['set_passwd'])

    elif 'audio_out' in request_data:
        set_audio_device(request_data['audio_out'])

    elif 'set_hostname' in request_data:
        set_hostname(request_data['set_hostname'])

    elif 'get_wifis' in request_data:
        response.data = dumps(get_wifis())

    elif 'set_netplan_conf' in request_data:
        res = set_netplan(secure_filename(request_data['set_netplan_conf']), request_data['content'], request_data.get('apply', True))
        if res == True:
            if DEFAULT_AP and do_ip_addr(True): #AP is still enabled but now we are connected, AP is no longer needed
                stop_hostpot()
                IS_FIRST_BOOT = False
                NEXT_CHANGE_TIME = int(time())
                chrome_goto(0)
        elif isinstance(res, str):
            response.data = res + '\n'
            response.code = 422

    elif 'new_netplan_conf' in request_data:
        create_netplan(request_data['new_netplan_conf'])

    elif 'del_netplan_conf' in request_data:
        if isinstance(del_netplan_file(request_data['del_netplan_conf'], request_data.get('apply', True)), str):
            response.data = res + '\n'
            response.code = 422

    elif 'schedule' in request_data:
        if request_data['schedule'] in ['pwr', 'reb'] and 'm' in request_data and 'h' in request_data and 'dom' in request_data and 'mon' in request_data and 'dow' in request_data:
            with CronTab(user='root') as crontab:
                crontab.new('/usr/sbin/' + ('poweroff' if request_data['schedule'] == 'pwr' else 'reboot'), 'unitotem:-)' + str(uuid4())).setall(' '.join([request_data['m'],request_data['h'],request_data['dom'],request_data['mon'],request_data['dow']]))

    elif 'set_job_state' in request_data:
        with CronTab(user='root') as crontab:
            list(crontab.find_comment(request_data['job']))[0].enable('enabled' in request_data['set_job_state'])

    elif 'remove_schedule' in request_data:
        with CronTab(user='root') as crontab:
            crontab.remove_all(comment=request_data['remove_schedule'])

    elif 'edit_schedule' in request_data:
        with CronTab(user='root') as crontab:
            job = list(crontab.find_comment(request_data['edit_schedule']))[0]
            if 'm' in request_data and 'h' in request_data and 'dom' in request_data and 'mon' in request_data and 'dow' in request_data:
                job.setall(' '.join(request_data['m'],request_data['h'],request_data['dom'],request_data['mon'],request_data['dow']))
            if request_data.get('cmd', '') in ['pwr', 'reb']:
                job.set_command('poweroff' if request_data['cmd'] == 'pwr' else 'reboot')

    else:
        response.data = dumps(request_data, indent=4) + '\n'
        response.code = 404

    return response.data, response.code


@WWW.route("/unitotem-no-assets")
def no_assets_page():
    ip = do_ip_addr(get_default=True)
    return render_template('no-assets.html',
        ut_vers=VERSION,
        os_vers=OS_VERSION,
        ip_addr=ip['addr'][0]['addr'] if ip else None,
        hostname=HOSTNAME
    )

@WWW.route("/unitotem-first-boot")
def first_boot_page():
    ip = do_ip_addr(get_default=True)
    return render_template('first-boot.html',
        ut_vers=VERSION,
        os_vers=OS_VERSION,
        ip_addr=ip['addr'][0]['addr'] if ip else None,
        hostname=HOSTNAME,
        wifi=DEFAULT_AP
    )

@AUTH.verify_password
def verify_password(username, password):
    if username in CONFIG['users'] and check_password_hash(CONFIG['users'][username]['pass'], password):
        return username


def chrome_goto(asset: int = CURRENT_ASSET, force: bool = False, backwards: bool = False):
    global NEXT_CHANGE_TIME, CURRENT_ASSET, CONFIG, CHROME
    if 0 <= asset < len(CONFIG['urls']):
        if CONFIG['urls'][asset]['enabled'] or force:
            CURRENT_ASSET = asset
            CHROME.Page.navigate(url=('file://' + abspath(join(WWW.config['UPLOAD_FOLDER'], CONFIG['urls'][CURRENT_ASSET]['url'].removeprefix('file:')))) if CONFIG['urls'][CURRENT_ASSET]['url'].startswith('file:') else CONFIG['urls'][CURRENT_ASSET]['url'])
            NEXT_CHANGE_TIME = (int(time()) + CONFIG['urls'][CURRENT_ASSET]['duration']) if CONFIG['urls'][CURRENT_ASSET]['duration'] else float('inf')
        else:
            chrome_goto(asset + (-1 if backwards else 1))




if __name__ == "__main__":
    makedirs(WWW.config['UPLOAD_FOLDER'], exist_ok=True)
    makedirs('/etc/unitotem', exist_ok=True)
    
    IS_FIRST_BOOT = not load_config()

    if IS_FIRST_BOOT:
        print('First boot or no configuration file found.')

    if IS_FIRST_BOOT and (not do_ip_addr(True) or exists(FALLBACK_AP_FILE)):
        # config file doesn't exist and we are not connected, maybe it's first boot
        hotspot = start_hotspot()
        DEFAULT_AP = dict(ssid=hotspot[0], password = hotspot[1], qrcode = wifi_qr(hotspot[0], hotspot[1]))
        print(f'Not connected to any network, started fallback hotspot {hotspot[0]} with password {hotspot[1]}.')

    if not APT_THREAD.is_alive():
        APT_THREAD = Thread(target=apt_update, name='update')
        APT_THREAD.start()

    def chrome_control_main():
        global NEXT_CHANGE_TIME, CURRENT_ASSET, CONFIG, CHROME
        for i in range(5):
            try:
                CHROME.connect()
                while(True):
                    if time()>=NEXT_CHANGE_TIME:
                        if IS_FIRST_BOOT:
                            NEXT_CHANGE_TIME = float('inf')
                            CHROME.Page.navigate(url='https://localhost/unitotem-first-boot')
                        elif not enabled_asset_count():
                            NEXT_CHANGE_TIME = float('inf')
                            CHROME.Page.navigate(url='https://localhost/unitotem-no-assets')
                        else:
                            CURRENT_ASSET += 1
                            if CURRENT_ASSET >= len(CONFIG['urls']): CURRENT_ASSET = 0
                            chrome_goto(CURRENT_ASSET)
                    sleep(1)
            except ConnectionError:
                pass
            print('Chrome not started, remote debugging tools not enabled or wrong port.\t Retrying...' + str(i+1))
            sleep(5)
        print('Max retries reached, could not connect to Chrome.')
        exit(1)

    Thread(target=chrome_control_main, daemon=True).start()

    serve(WWW, listen='*:5000')

    stop_hostpot()
