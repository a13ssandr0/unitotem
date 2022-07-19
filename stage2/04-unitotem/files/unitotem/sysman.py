from base64 import b64encode
from io import BytesIO
from os import listdir, makedirs
from os import remove as removefile
from os.path import exists
from re import match, sub
from socket import inet_aton, inet_ntoa
from struct import pack
from subprocess import PIPE, check_output, run
from typing import Union

from apt import Cache
from qrcode import make as make_qr
from ruamel.yaml import YAML
import iwlist


ETC_HOSTNAME     = '/etc/hostname'
ETC_HOSTS        = '/etc/hosts'
ETC_RESOLV_CONF  = '/etc/resolv.conf'
ASOUND_CONF      = '/etc/asound.conf'
NETPLAN_DIR      = '/etc/netplan/'
FALLBACK_AP_FILE = '/lib/netplan/99-unitotem-fb-ap.yaml'
SCREEN_SIZE_FILE = '/tmp/screen_size.txt'

IF_ALL = 0
IF_WIRED = 1
IF_WIRELESS = 2

APT_CACHE=Cache()
APT_UPD_COUNT = 0

_YAML = YAML()

def get_upd_count():
    return APT_UPD_COUNT

def get_hostname():
    return check_output('hostname').strip().decode('utf-8')

def set_hostname(to_h: str, from_h: str = get_hostname()):
    to_h = to_h.strip()
    if match(r'^[a-zA-Z][a-zA-Z0-9]*(-*[a-zA-Z0-9]+)*$', to_h):
        with open(ETC_HOSTNAME, 'w') as etc_hostname:
            etc_hostname.write(to_h)
        with open(ETC_HOSTS, 'r') as etc_hosts:
            hosts = etc_hosts.read()
        with open(ETC_HOSTS, 'w') as etc_hosts:
            etc_hosts.write(sub(f'127.0.1.1.*{from_h}', f'127.0.1.1\t{to_h}', hosts))

def get_display_size():
    if exists(SCREEN_SIZE_FILE):
        with open(SCREEN_SIZE_FILE, 'r') as scr_s:
            return scr_s.read().strip()


# Taken from raspi-config, not needed as of now, maybe in the future...

# def set_config_var(key:str, value:str, filename:str):
#     if key and value and filename:
#         made_change = False
#         out = []
#         with open(filename, 'r') as file:
#             for line in file.readlines():
#                 if match(r'^#?\s*'+key+r'=.*$', line.strip()):
#                     line=key+"="+value
#                     made_change=True
#                 out.append(line)
        
#         if not made_change:
#             out.append(line)

#         with open(filename, 'w') as file:
#             file.writelines(out)


# def get_config_var(key:str, filename:str):
#     if key and filename:
#         with open(filename, 'r') as file:
#             for line in file.readlines():
#                 out = match(r'^\s*'+key+r'=(.*)$', line.strip())
#                 if out:
#                     return out.group()


def get_ifaces(filter=IF_ALL, exclude=['lo']):
    def _get_ifaces(filter=IF_ALL):
        ifaces = [iface[len('/sys/class/net/'):] for iface in check_output('for iface in /sys/class/net/*; do echo $iface; done', shell=True).decode('utf-8').split('\n') if iface]
        if filter == IF_ALL: return ifaces
        w_ifaces = [iface[len('/sys/class/net/'):-len('/wireless')] for iface in check_output('for iface in /sys/class/net/*/wireless; do echo $iface; done', shell=True).decode('utf-8').split('\n') if iface]
        if filter == IF_WIRELESS: return w_ifaces
        if filter == IF_WIRED:
            for w in w_ifaces:
                ifaces.remove(w)
            return ifaces

    return [ifc for ifc in _get_ifaces(filter) if ifc not in exclude] if exclude else _get_ifaces(filter)


def get_dns_list():
    with open(ETC_RESOLV_CONF, 'r') as resolv_conf:
        return [l.removeprefix('nameserver ').strip() for l in resolv_conf.readlines() if l.strip().startswith('nameserver')] # and not l.removeprefix('nameserver ').strip().startswith('127.')]


def set_netplan(filename, file_content, apply = True):
    with open(NETPLAN_DIR + filename, 'w') as netp:
        netp.write(file_content)
    gen_out = run(['netplan', 'generate'], stderr=PIPE, check=False).stderr.decode('utf-8').strip()
    if gen_out:
        return gen_out
    if apply: run(['netplan', 'apply'])
    return apply

def create_netplan(filename):
    with open(NETPLAN_DIR + filename, 'w') as netp: netp.write('network:\n')

def del_netplan_file(filename, apply = True):
    removefile(NETPLAN_DIR + filename)
    gen_out = run(['netplan', 'generate'], stderr=PIPE, check=False).stderr.decode('utf-8').strip()
    if gen_out:
        return gen_out
    if apply: run(['netplan', 'apply'])
    return apply

def get_netplan_file(filename):
    if not exists(NETPLAN_DIR + filename): return ''
    with open(NETPLAN_DIR + filename, 'r') as netp:
        return netp.read()
    
def get_netplan_file_list():
    return [file for file in listdir(NETPLAN_DIR) if file.endswith('.yaml')]

def start_hotspot(wifi_iface = get_ifaces(IF_WIRELESS)[0], ssid = get_hostname(), password = None):
    if password == None:
        password = sub(r'[^0-9A-Fa-f]', '', do_ip_addr()[wifi_iface]['mac']).upper()[-8:]
    if exists(FALLBACK_AP_FILE):
        with open(FALLBACK_AP_FILE, 'r') as netp_hotspot:
            conf = dict(_YAML.load(netp_hotspot))
            if 'network' in conf and 'wifis' in conf['network'] and wifi_iface in conf['network']['wifis'] and ssid in conf['network']['wifis'][wifi_iface]['access-points'] and 'mode' in conf['network']['wifis'][wifi_iface]['access-points'][ssid] and conf['network']['wifis'][wifi_iface]['access-points'][ssid]['mode'] == 'ap' and conf['network']['wifis'][wifi_iface]['access-points'][ssid]['password'] == password:
                return (ssid, password)
    with open(FALLBACK_AP_FILE, 'w') as netp_hotspot:
        netp_hotspot.write('# This file is automatically generated to create first time wireless access point, ANY CHANGES WILL BE LOST!\n')
        _YAML.dump({
            'network': {
                'wifis': {
                    f'{wifi_iface}': {
                        'dhcp4': True,
                        'optional': True,
                        'access-points': {
                            f'{ssid}':{
                                'password': f'{password}',
                                'mode': 'ap'
                            }
                        }
                    }
                }
            }
        }, netp_hotspot)
    run(['netplan', 'apply'])
    return (ssid, password)

def stop_hostpot():
    if exists(FALLBACK_AP_FILE):
        removefile(FALLBACK_AP_FILE)
        run(['netplan', 'apply'])

def wifi_qr(ssid, passwd):
    buffered = BytesIO()
    make_qr(f'WIFI:S:{ssid};T:WPA;P:{passwd};;').save(buffered, format="PNG")
    return b64encode(buffered.getvalue()).decode('utf-8')

def get_wifis():
    wifis = sorted(iwlist.parse(iwlist.scan(get_ifaces(IF_WIRELESS)[0])), key = lambda x: int(x['signal_quality']), reverse=True)
    for w in wifis:
        w['essid'] = w['essid'].replace(r'\x00', '')
    return wifis

# from https://github.com/RedHatInsights/insights-core
def do_ip_addr(get_default=False):
    ip_addr = check_output(['ip', 'addr']).decode('utf-8').splitlines()
    r = {}
    current = {}
    rx_next_line = False
    tx_next_line = False
    def_iface = None
    ifaces = {}
    ifaces_out = {}
    with open("/proc/net/route") as fh:
        for line in fh:
            fields = line.strip().split()
            try:
                int(fields[1], 16)
                if fields[0] not in ifaces: ifaces[fields[0]] = {'nets': [], 'gtws':[]}
                if not def_iface: def_iface = fields[0]
                if fields[1] != '00000000' or not int(fields[3], 16) & 2:
                    ifaces[fields[0]]['nets'] += [{'dst': fields[1], 'mask': fields[7]}]
                    continue
                ifaces[fields[0]]['gtws'] += [fields[2]]
            except ValueError:
                pass
        for iface, prop in ifaces.items():
            if iface not in ifaces_out: ifaces_out[iface] = {}
            for net in prop['nets']:
                subnet = inet_ntoa(pack("<L", int(net['dst'], 16)))
                ifaces_out[iface][subnet] = {'gateway': None, 'mask': inet_ntoa(pack("<L", int(net['mask'], 16)))}
                for gtw in prop['gtws']:
                    if (int(net['mask'], 16) & int(gtw, 16)) == int(net['dst'], 16):
                        ifaces_out[iface][subnet]['gateway'] = inet_ntoa(pack("<L", int(gtw, 16)))
                        break

    ip_addr = [l.strip() for l in ip_addr if "Message truncated" not in l]
    for line in filter(None, ip_addr):
        if rx_next_line and current:
            split_content = line.split()
            current["rx_bytes"] = int(split_content[0])
            current["rx_packets"] = int(split_content[1])
            current["rx_errors"] = int(split_content[2])
            current["rx_dropped"] = int(split_content[3])
            current["rx_overrun"] = int(split_content[4])
            current["rx_mcast"] = int(split_content[5])
            rx_next_line = False
        if tx_next_line and current:
            split_content = line.split()
            current["tx_bytes"] = int(split_content[0])
            current["tx_packets"] = int(split_content[1])
            current["tx_errors"] = int(split_content[2])
            current["tx_dropped"] = int(split_content[3])
            current["tx_carrier"] = int(split_content[4])
            current["tx_collsns"] = int(split_content[5])
            tx_next_line = False
        elif line[0].isdigit() and "state" in line:
            split_content = line.split()
            idx, name, _ = line.split(":", 2)
            virtual = "@" in name
            if virtual:
                name, physical_name = name.split("@")
            current = {
                "index": int(idx),
                "name": name.strip(),
                "physical_name": physical_name if virtual else None,
                "virtual": virtual,
                "flags": split_content[2].strip("<>").split(","),
                "addr": [],
                "default": name.strip() == def_iface
            }
            # extract properties
            for i in range(3, len(split_content), 2):
                key, value = (split_content[i], split_content[i + 1])
                current[key] = int(value) if key in ["mtu", "qlen"] else value
            r[current["name"]] = current
        elif line.startswith("link"):
            split_content = line.split()
            current["type"] = split_content[0].split("/")[1]
            if "peer" in line and len(split_content) >= 3:
                current["peer_ip"] = split_content[1]
                current["peer"] = split_content[3]
            elif len(split_content) >= 2:
                current["mac"] = split_content[1]
                if "promiscuity" in split_content:
                    current["promiscuity"] = split_content[
                        split_content.index('promiscuity') + 1]
        elif 'vxlan' in line:
            split_content = line.split()
            current['vxlan'] = split_content
        elif 'openvswitch' in line:
            split_content = line.split()
            current['openvswitch'] = split_content
        elif 'geneve' in line:
            split_content = line.split()
            current['geneve'] = split_content
        elif line.startswith("inet"):
            split_content = line.split()
            p2p = "peer" in split_content
            addr, mask = split_content[3 if p2p else 1].split("/")
            gateway = None
            if current['name'] in ifaces_out:
                for subn, propts in ifaces_out[current['name']].items():
                    try:
                        if (int(''.join('{:02X}'.format(a) for a in inet_aton(addr)), 16) & int('0b'+('1'*int(mask))+('0'*(32-int(mask))),2)) == int(''.join('{:02X}'.format(a) for a in inet_aton(subn)), 16):
                            gateway = propts['gateway']
                            break
                    except OSError:
                        pass # ipv6 address
            current["addr"].append({
                "addr": addr,
                "mask": mask,
                "gateway": gateway,
                "local_addr": split_content[1] if p2p else None,
                "p2p": p2p
            })
        elif line.startswith("RX"):
            rx_next_line = True
        elif line.startswith("TX"):
            tx_next_line = True
    return r[def_iface] if get_default and def_iface else False if get_default and not def_iface else r

def is_connected():
    pass

def get_audio_devices():
    cards = list(set([match(r'card (\d+): (\w+)', card).groups() for card in check_output(['aplay', '-l'], env={'LANG': 'C'}).decode('utf-8').splitlines() if card.startswith('card')]))
    cards.sort()
    return cards

def get_default_audio_device():
    if not exists(ASOUND_CONF): return 'a'
    with open(ASOUND_CONF, 'r') as conf:
        m = match(r'defaults.(?:pcm|ctl).card (\d+)', conf.read())
        return str(m.group(1)) if m else 'a'

def set_audio_device(dev: Union[str,int]):
    if dev == 'a' and exists(ASOUND_CONF): removefile(ASOUND_CONF)
    else:
        try:
            int(dev)
            with open(ASOUND_CONF, 'r+' if exists(ASOUND_CONF) else 'w+' ) as conf:
                orig = conf.read()
                output = sub(r'defaults.(pcm|ctl).card (\d+)', r'defaults.\1.card ' + dev, orig)
                if output == orig: output += f'\ndefaults.pcm.card {dev}\ndefaults.ctl.card {dev}\n'
                conf.seek(0)
                conf.write(output)
                conf.truncate()
        except ValueError:
            pass


def apt_update():
    global APT_UPD_COUNT
    APT_CACHE.update(raise_on_error=False)
    APT_CACHE.open(None)
    APT_CACHE.upgrade(True)
    changes = APT_CACHE.get_changes()
    APT_UPD_COUNT = len(changes)
    return changes

def apt_upgrade():
    apt_update()
    APT_CACHE.commit()
    apt_update()

def os_version():
    with open('/etc/os-release', 'r') as f:
        for line in f.readlines():
            line = line.strip()
            if 'PRETTY_NAME' in line:
                return line.split('=')[1].strip('"')
