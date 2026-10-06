#!/usr/bin/env bash
# Remnawave Node one-click installer 1.0.0
# Standalone artifact; no credentials, server addresses or third-party installer URLs.
set -Eeuo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Remnawave Node 一键安装器 v1.0.0

安装：       sudo bash remnawave-node-install.sh
预览：       sudo bash remnawave-node-install.sh --dry-run
检查：       sudo bash remnawave-node-install.sh --check
离线自检：   bash remnawave-node-install.sh --self-test

支持 Debian 12/13、Ubuntu 22.04/24.04/26.04，amd64/arm64，systemd。
1) API Token 自动创建独立 Node、SS2022 AES256 Profile、Host，选择已有内部组。
2) SECRET_KEY 接入面板已创建的 Node；保留面板 Profile，另提供 SS2022 配置参考。
自动安装 Docker（官方 APT 仓库）、设置 initcwnd=100、TFO=3、可用的 BBR，限制管理端口来源。
SmartDNS 使用独立本地端口 6053、IPv4 1.1.1.1 DoH；无需改系统 DNS。
复用现有 Docker；保留现有 qdisc/限速、其他容器和防火墙规则，不重启服务器。
API 模式默认配置兼容已验证的面板 3.4.5 / Node 3.4.2；其他版本按所选镜像校验。
云安全组和既有 UFW/firewalld 需放行相应端口；退出码 3 表示部署完成但面板尚未连接。
密钥通过终端隐藏输入；不接受命令行密码，不保存 API Token。
HELP
  exit 0
fi

if [[ $# -gt 1 ]]; then
  printf '%s\n' '一次只接受一个选项；使用 --help 查看用法。' >&2
  exit 1
fi
case "${1:-}" in
  ''|--dry-run|--check|--self-test) ;;
  *) printf '%s\n' '未知选项；使用 --help 查看用法。' >&2; exit 1 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  if [[ "${1:-}" == '--dry-run' || "${1:-}" == '--check' || "${1:-}" == '--self-test' ]]; then
    printf '%s\n' '此模式需要 Python 3.9+；未自动安装依赖。' >&2
    exit 1
  fi
  if [[ "$(id -u)" != 0 || ! -f /etc/os-release || ! -d /run/systemd/system ]]; then
    printf '%s\n' '需要以 root 运行在支持的 Linux systemd 服务器上。' >&2
    exit 1
  fi
  remna_os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
  remna_os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"')"
  case "$remna_os_id:$remna_os_version" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *) printf '%s\n' '系统不在支持列表，未安装依赖。' >&2; exit 1 ;;
  esac
  printf '%s\n' '安装发行版 Python 3 依赖…'
  if ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update >/dev/null 2>&1 ||
     ! DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends python3 >/dev/null 2>&1; then
    printf '%s\n' 'Python 依赖安装失败；请检查 APT 源和网络后重试。' >&2
    exit 1
  fi
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)'; then
  printf '%s\n' '需要 Python 3.9 或更新版本。' >&2
  exit 1
fi

python3 - "$@" <<'REMNA_ONECLICK_PYTHON'
"""Payload embedded in the distributable shell script. Python 3.9+, stdlib only."""
import base64
import datetime
import fcntl
import getpass
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

VERSION = "1.0.0"
BASE = Path("/opt/remnawave-node-oneclick")
OWNER = "remnawave-node-oneclick"
CONTAINER = "remnawave-node-oneclick"
TABLE = "remna_oneclick"
UNITS = ["remna-oneclick-firewall.service", "remna-oneclick-cwnd.service",
         "remna-oneclick-cwnd.timer", "remna-oneclick-smartdns.service"]
WARNINGS = []


class InstallError(Exception):
    pass


def say(message):
    print(message, flush=True)


def run(args, timeout=60, check=True, data=None):
    # Never echo argv or command output: either can contain credentials.
    try:
        proc = subprocess.run([str(x) for x in args], input=data,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, env={**os.environ, "LC_ALL": "C",
                              "DEBIAN_FRONTEND": "noninteractive", "NEEDRESTART_MODE": "l"})
    except subprocess.TimeoutExpired:
        raise InstallError("命令超时：" + Path(str(args[0])).name)
    except OSError:
        raise InstallError("无法执行：" + Path(str(args[0])).name)
    if check and proc.returncode:
        raise InstallError("命令失败：%s，退出码 %s（未输出可能含密钥的原始内容）" %
                           (Path(str(args[0])).name, proc.returncode))
    return proc


def command(args, **kw):
    return run(args, **kw).stdout.decode("utf-8", "replace").strip()


def write(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise InstallError("拒绝覆盖符号链接：" + str(path))
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    fd, name = tempfile.mkstemp(prefix=".remna-", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_text(value):
    return "".join(c for c in str(value) if c.isprintable())[:100]


def port(value):
    if not re.fullmatch(r"[0-9]{1,5}", str(value)) or not 1 <= int(value) <= 65535:
        raise ValueError("端口必须在 1–65535 之间")
    return int(value)


def host(value):
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        if len(value) > 253 or not re.fullmatch(r"[A-Za-z0-9.-]+", value):
            raise ValueError("请输入 IPv4、IPv6 或域名，不含协议和端口")
        labels = value.rstrip(".").split(".")
        if len(labels) < 2 or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in labels):
            raise ValueError("域名格式无效")
        return value.rstrip(".").lower()


def node_address(value):
    value = host(value)
    return "[" + value + "]" if ":" in value else value


def url(value):
    value = value.strip().rstrip("/")
    p = urllib.parse.urlsplit(value)
    if p.scheme != "https" or not p.hostname or p.username or p.password or p.query or p.fragment:
        raise ValueError("面板地址必须为 HTTPS URL，不含账号、查询参数或片段")
    host(p.hostname)
    try:
        p.port
    except ValueError:
        raise ValueError("面板 URL 端口无效")
    if any(c.isspace() or ord(c) < 32 for c in value):
        raise ValueError("面板 URL 不能包含空白或控制字符")
    return value[:-4] if value.endswith("/api") else value


def secret_key(value):
    value = value.strip().strip('"').strip("'")
    if len(value) > 65536 or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", value):
        raise ValueError("SECRET_KEY 应为面板提供的单行 Base64 密钥")
    try:
        obj = json.loads(base64.b64decode(value, validate=True))
        fields = {"caCertPem": "CERTIFICATE", "jwtPublicKey": "PUBLIC KEY",
                  "nodeCertPem": "CERTIFICATE", "nodeKeyPem": "PRIVATE KEY"}
        for key, kind in fields.items():
            pem = obj[key].replace("\\n", "\n")
            if not isinstance(pem, str) or "-----BEGIN " not in pem or kind not in pem:
                raise ValueError()
    except (ValueError, KeyError, TypeError, AttributeError):
        raise ValueError("SECRET_KEY 格式无效，需使用 Remnawave Node 的密钥")
    return value


def networks(value):
    result = []
    for item in re.split(r"[,\s]+", value.strip()):
        if not item:
            continue
        net = ipaddress.ip_network(item, strict=False)
        if net.prefixlen == 0:
            raise ValueError("管理端口不能允许全网访问，请填写面板的实际出口 IP/CIDR")
        if net.is_multicast or net.is_unspecified:
            raise ValueError("请输入面板出口的单播 IP/CIDR")
        result.append(str(net))
    if not result:
        raise ValueError("至少输入一个面板出口 IP/CIDR")
    return sorted(set(result))


def image_tag(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("请输入固定版本，例如 3.4.2")
    return value


def node_name(value):
    if not re.fullmatch(r"[A-Za-z0-9_-]{3,30}", value):
        raise ValueError("节点名需为 3–30 位字母、数字、下划线或横线")
    return value


def ask(title, default=None, validator=lambda x: x, hidden=False):
    # /dev/tty also supports 'curl ... | sudo bash'; embedded source owns stdin.
    with open("/dev/tty", "r+") as tty:
        while True:
            prompt = title + (" [回车保留]" if hidden and default else
                              " [%s]" % default if default is not None else "") + ": "
            if hidden:
                answer = getpass.getpass(prompt, stream=tty)
            else:
                tty.write(prompt)
                tty.flush()
                answer = tty.readline()
                if not answer:
                    raise InstallError("交互终端已关闭")
                answer = answer.rstrip("\r\n")
            if not answer and default is not None:
                answer = str(default)
            try:
                return validator(answer)
            except (ValueError, TypeError) as exc:
                say("输入有误：" + safe_text(exc))


def yesno(value):
    if value.lower() in ("y", "yes", "是"):
        return True
    if value.lower() in ("n", "no", "否"):
        return False
    raise ValueError("请输入 y 或 n")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kw):
        return None


class API:
    def __init__(self, base, token):
        self.base = url(base) + "/api"
        if not token or any(c.isspace() for c in token) or len(token) > 8192:
            raise InstallError("API Token 格式无效")
        self.token = token
        # No environment proxy and no redirect of Authorization to another host.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, path, body=None, method=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data,
              method=method or ("POST" if body is not None else "GET"), headers={
                  "Authorization": "Bearer " + self.token,
                  "Content-Type": "application/json", "X-Remnawave-Client-Type": "browser"})
        try:
            with self.opener.open(req, timeout=25) as response:
                raw = response.read(4 * 1024 * 1024)
                return json.loads(raw).get("response") if raw else None
        except urllib.error.HTTPError as exc:
            raise InstallError("面板 API %s %s 返回 HTTP %s；检查 Token 权限、URL 和版本" %
                               (req.method, path.split("?")[0], exc.code))
        except (urllib.error.URLError, OSError, ValueError):
            suffix = "；写请求可能已生效，请检查面板中的 OneClick 资源" if req.method != "GET" else ""
            raise InstallError("面板 API 连接或响应失败（保持 TLS 证书校验）" + suffix)


def sysinfo():
    data = {}
    file = Path("/etc/os-release")
    if file.exists():
        for line in file.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                data[k] = v.strip('"').strip("'")
    return data


def platform_check():
    osinfo = sysinfo()
    allowed = {"debian": {"12", "13"}, "ubuntu": {"22.04", "24.04", "26.04"}}
    if osinfo.get("VERSION_ID") not in allowed.get(osinfo.get("ID"), set()):
        raise InstallError("支持 Debian 12/13、Ubuntu 22.04/24.04/26.04；其他系统未改动")
    if not Path("/run/systemd/system").is_dir():
        raise InstallError("需要以 systemd 运行的 Linux 服务器")
    arch = command(["dpkg", "--print-architecture"])
    if arch not in ("amd64", "arm64"):
        raise InstallError("Node 镜像仅选择 amd64/arm64")
    return osinfo, arch


def apt(packages):
    say("安装依赖：" + ", ".join(packages) + "（不升级整个系统）")
    run(["apt-get", "update"], timeout=600)
    run(["apt-get", "install", "-y", "--no-install-recommends", *packages], timeout=900)


def ensure_docker(osinfo, arch):
    if shutil.which("docker"):
        if run(["docker", "info"], check=False).returncode:
            raise InstallError("检测到现有 Docker 但守护进程不可用，请先修复现有 Docker")
        if run(["docker", "compose", "version"], check=False).returncode:
            raise InstallError("现有 Docker 缺少 Compose v2；请从其现有安装来源补装插件后重试")
        say("复用现有 Docker，不重启守护进程。")
        return
    conflicts = []
    for package in ("docker.io", "docker-compose", "docker-compose-v2", "podman-docker", "containerd", "runc"):
        if "install ok installed" in command(["dpkg-query", "-W", "-f=${Status}", package], check=False):
            conflicts.append(package)
    if conflicts or shutil.which("podman") or shutil.which("containerd"):
        raise InstallError("已有其他容器运行时或冲突软件：%s；未卸载，请先处理兼容性" % ", ".join(conflicts))
    family = osinfo["ID"]
    codename = osinfo.get("UBUNTU_CODENAME") or osinfo.get("VERSION_CODENAME")
    if not codename or not re.fullmatch(r"[a-z]+", codename):
        raise InstallError("无法识别官方 Docker 仓库代号")
    key = Path("/etc/apt/keyrings/docker.asc")
    source = Path("/etc/apt/sources.list.d/docker.sources")
    for existing in (key, source, Path("/etc/apt/sources.list.d/docker.list")):
        if existing.exists() or existing.is_symlink():
            raise InstallError("已有 Docker 仓库配置但未安装 Docker；请检查后重试：" + str(existing))
    say("从 Docker 官方 APT 仓库安装 Docker Engine / Compose。")
    pem = command(["curl", "--fail", "--silent", "--show-error", "--proto", "=https",
                   "--connect-timeout", "15", "--max-time", "60",
                   "https://download.docker.com/linux/%s/gpg" % family])
    if "BEGIN PGP PUBLIC KEY BLOCK" not in pem:
        raise InstallError("Docker 仓库签名密钥下载无效")
    write(key, pem + "\n", 0o644)
    write(source, "Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\n"
          "Components: stable\nArchitectures: %s\nSigned-By: %s\n" %
          (family, codename, arch, key), 0o644)
    apt(["docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"])
    run(["systemctl", "enable", "--now", "docker"])
    run(["docker", "info"])


def default_source():
    if shutil.which("ip"):
        text = command(["ip", "-4", "route", "get", "1.1.1.1"], check=False)
        match = re.search(r"\bsrc ([0-9.]+)", text)
        if match:
            return match.group(1)
    return "0.0.0.0"


def source_ip(value):
    address = ipaddress.IPv4Address(value)
    if address.is_multicast or address.is_loopback:
        raise ValueError("出口 IP 需为本机网卡 IPv4，或 0.0.0.0 自动选择")
    if str(address) != "0.0.0.0":
        rows = json.loads(command(["ip", "-j", "-4", "address", "show"]))
        locals_ = {a["local"] for row in rows for a in row.get("addr_info", []) if a.get("family") == "inet"}
        if str(address) not in locals_:
            raise ValueError("该地址不在本机网卡上；NAT 服务器请填私网 IPv4，不填公网映射 IP")
    return str(address)


def make_profile(c, master=None):
    key = master or base64.b64encode(secrets.token_bytes(32)).decode()
    return {
        "log": {"loglevel": "warning", "access": "none"},
        "dns": {"servers": ["tcp+local://127.0.0.1:%s" % c["dns_port"]],
                "queryStrategy": "UseIPv4", "disableFallback": True},
        "inbounds": [{"tag": "ONECLICK_SS2022", "listen": c.get("listen_address", "0.0.0.0"), "port": c["ss_port"],
            "protocol": "shadowsocks", "settings": {"method": "2022-blake3-aes-256-gcm",
            "password": key, "clients": [], "network": "tcp,udp"},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
            "streamSettings": {"sockopt": {"tcpFastOpen": True}}}],
        "outbounds": [{"tag": "DIRECT_IPV4", "protocol": "freedom", "sendThrough": c["source_ip"],
            "settings": {"targetStrategy": "ForceIPv4", "finalRules": [{"action": "block", "ip": ["::/0"]}]},
            "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4", "tcpFastOpen": True}}},
            {"tag": "DNS_OUT", "protocol": "dns", "settings": {"rewriteAddress": "127.0.0.1",
             "rewritePort": c["dns_port"], "rules": [{"action": "return", "qType": 28, "rCode": 0}, {"action": "direct"}]}},
            {"tag": "BLOCK", "protocol": "blackhole"}],
        "routing": {"domainStrategy": "IPOnDemand", "rules": [
            {"type": "field", "inboundTag": ["ONECLICK_SS2022"], "port": "53", "network": "tcp,udp", "outboundTag": "DNS_OUT"},
            {"type": "field", "ip": ["::/0", "geoip:private"], "outboundTag": "BLOCK"}]}}


def compose(c):
    # JSON is valid Compose YAML. Env-file format is kept separate and root-only.
    return {"services": {"node": {
        "image": "remnawave/node:" + c["image_tag"], "container_name": CONTAINER,
        "hostname": CONTAINER, "network_mode": "host", "restart": "unless-stopped",
        "cap_add": ["NET_ADMIN"], "labels": {"io.remna.oneclick.owner": c["owner_id"]},
        "env_file": [".env"], "ulimits": {"nofile": {"soft": 1048576, "hard": 1048576}},
        "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}
    }}}


def firewall(c):
    rules = ["table inet %s {" % TABLE,
             " chain node_api { type filter hook input priority -10; policy accept;",
             '  iifname "lo" tcp dport %s accept' % c["api_port"]]
    for network in c["panel_ips"]:
        family = "ip6" if ":" in network else "ip"
        rules.append("  %s saddr %s tcp dport %s accept" % (family, network, c["api_port"]))
    rules += ["  tcp dport %s drop" % c["api_port"], " }", "}"]
    return "\n".join(rules) + "\n"


def change_cwnd(line, value=100):
    # ip -o separates multipath nexthops with a literal backslash + tab.
    parts = shlex.split(re.sub(r"\\\s+", " ", line))
    # These are read-only status flags emitted by ip, not route configuration.
    parts = [p for p in parts if p not in ("linkdown", "offload", "trap", "notify")]
    if "initcwnd" in parts:
        at = parts.index("initcwnd")
        at += 2 if parts[at + 1] == "lock" else 1
        parts[at] = str(value)
    else:
        at = parts.index("nexthop") if "nexthop" in parts else len(parts)
        parts[at:at] = ["initcwnd", str(value)]
    if "expires" in parts:
        at = parts.index("expires") + 1
        if re.fullmatch(r"[0-9]+sec", parts[at]):
            parts[at] = parts[at][:-3]
    return parts


CWND_HELPER = r'''#!/usr/bin/env python3
import json, re, shlex, subprocess, sys
from pathlib import Path
BASE = Path('/opt/remnawave-node-oneclick')
def execute(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
def parts(line, value):
    p = [x for x in shlex.split(re.sub(r'\\\s+',' ',line)) if x not in ('linkdown','offload','trap','notify')]
    if 'initcwnd' in p:
        at = p.index('initcwnd')
        at += 2 if p[at+1] == 'lock' else 1
        p[at] = str(value)
    else:
        pos = p.index('nexthop') if 'nexthop' in p else len(p)
        p[pos:pos] = ['initcwnd',str(value)]
    if 'expires' in p:
        at = p.index('expires')+1
        if re.fullmatch(r'[0-9]+sec',p[at]):
            p[at] = p[at][:-3]
    return p
failed = False
for family in ('-4','-6'):
    result = execute(['ip','-o',family,'route','show','table','all','default'])
    if result.returncode:
        continue
    for line in result.stdout.decode().splitlines():
        p = shlex.split(line)
        if not p or p[0] != 'default':
            continue
        at = p.index('initcwnd') if 'initcwnd' in p else -1
        if at >= 0 and p[at+(2 if p[at+1]=='lock' else 1)] == '100':
            continue
        result = execute(['ip',family,'route','change'] + parts(line,100))
        if result.returncode:
            failed = True
            print('initcwnd: route update failed ('+family+')',file=sys.stderr)
sys.exit(1 if failed else 0)
'''

FIREWALL_HELPER = r'''#!/usr/bin/env python3
import subprocess
from pathlib import Path
name = 'remna_oneclick'
exists = subprocess.run(['nft','list','table','inet',name],capture_output=True).returncode == 0
config = Path('/opt/remnawave-node-oneclick/node-api.nft').read_bytes()
if exists:
    config = ('delete table inet '+name+'\n').encode() + config
# nft batch validation + atomic replacement; no global flush.
subprocess.run(['nft','--check','-f','-'],input=config,check=True)
subprocess.run(['nft','-f','-'],input=config,check=True)
'''


class Transaction:
    def __init__(self):
        self.backup = BASE / "backups" / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + secrets.token_hex(3))
        self.backup.mkdir(parents=True, mode=0o700)
        self.files = {}
        self.undo = []
        self.services = set()
        self.completed = False

    def remember(self, path):
        path = Path(path)
        if str(path) in self.files:
            return
        if path.is_symlink():
            raise InstallError("拒绝修改符号链接：" + str(path))
        saved = self.backup / "files" / str(path).lstrip("/")
        exists = path.exists()
        mode = (path.stat().st_mode & 0o777) if exists else None
        if exists:
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, saved)
            saved.chmod(0o600)
        self.files[str(path)] = {"exists": exists, "mode": mode, "saved": str(saved)}
        write(self.backup / "manifest.json", self.files)

    def put(self, path, value, mode=0o600):
        self.remember(path)
        write(path, value, mode)

    def rollback(self, announce=True):
        if announce:
            say("安装未完成，恢复本次修改；备份：" + str(self.backup))
        for fn in reversed(self.undo):
            try:
                fn()
            except Exception:
                say("部分回退未完成，请检查备份目录中的 rollback-status.txt。")
                with (self.backup / "rollback-status.txt").open("a") as out:
                    out.write("A rollback operation failed; no credential output retained.\n")
        for path, item in reversed(list(self.files.items())):
            if item["exists"]:
                original = Path(item["saved"]).read_bytes().decode()
                write(path, original, item["mode"])
            else:
                Path(path).unlink(missing_ok=True)
        run(["systemctl", "daemon-reload"], check=False)


def service_state(name):
    return {"active": run(["systemctl", "is-active", "--quiet", name], check=False).returncode == 0,
            "enabled": command(["systemctl", "is-enabled", name], check=False) == "enabled"}


def prepare_service(tx, name):
    if name in tx.services:
        return
    tx.services.add(name)
    before = service_state(name)
    def undo():
        run(["systemctl", "stop", name], check=False)
        run(["systemctl", "disable", name], check=False)
    tx.undo.append(undo)
    return before


def configure_network(tx):
    prepare_service(tx, "remna-oneclick-cwnd.service")
    prepare_service(tx, "remna-oneclick-cwnd.timer")
    keys = {"net.ipv4.tcp_fastopen": "3", "net.ipv4.tcp_mtu_probing": "1",
            "net.ipv4.tcp_syncookies": "1", "net.ipv4.tcp_window_scaling": "1",
            "net.ipv4.tcp_sack": "1", "net.core.somaxconn": "4096",
            "net.ipv4.tcp_max_syn_backlog": "8192", "net.core.netdev_max_backlog": "8192"}
    run(["modprobe", "tcp_bbr"], check=False)
    available = command(["sysctl", "-n", "net.ipv4.tcp_available_congestion_control"])
    if "bbr" in available.split():
        keys["net.ipv4.tcp_congestion_control"] = "bbr"
    else:
        WARNINGS.append("当前内核不提供 BBR，保留原拥塞控制算法；没有更换内核或重启服务器。")
    if run(["modprobe", "sch_fq"], check=False).returncode == 0 or "fq" in command(["tc", "qdisc", "show"], check=False):
        keys["net.core.default_qdisc"] = "fq"
    # Keep existing HTB/CAKE/FQ and provider rate limiting; default_qdisc only affects newly created interfaces.
    originals = {key: command(["sysctl", "-n", key]) for key in keys}
    write(tx.backup / "sysctl-before.json", originals)
    tx.undo.append(lambda: [run(["sysctl", "-w", k + "=" + v], check=False) for k, v in originals.items()])
    tx.put("/etc/sysctl.d/99-remna-oneclick.conf", "# Managed by %s; existing qdisc is preserved.\n" % OWNER +
           "".join(k + "=" + v + "\n" for k, v in keys.items()), 0o644)
    run(["sysctl", "-p", "/etc/sysctl.d/99-remna-oneclick.conf"])
    routes = []
    for family in ("-4", "-6"):
        for line in command(["ip", "-o", family, "route", "show", "table", "all", "default"], check=False).splitlines():
            if line.startswith("default "):
                routes.append({"family": family, "line": line})
    write(tx.backup / "routes-before.json", routes)
    def undo_routes():
        for route in routes:
            original = shlex.split(route["line"])
            at = original.index("initcwnd") if "initcwnd" in original else -1
            old = original[at + (2 if original[at + 1] == "lock" else 1)] if at >= 0 else "0"
            run(["ip", route["family"], "route", "change", *change_cwnd(route["line"], old)], check=False)
    tx.undo.append(undo_routes)
    tx.put(BASE / "initcwnd.py", CWND_HELPER, 0o700)
    tx.put("/etc/systemd/system/remna-oneclick-cwnd.service", """[Unit]
Description=Remnawave initial TCP congestion window 100
After=network-online.target networking.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/remnawave-node-oneclick/initcwnd.py
[Install]
WantedBy=multi-user.target
""", 0o644)
    tx.put("/etc/systemd/system/remna-oneclick-cwnd.timer", """[Unit]
Description=Restore initcwnd after DHCP/network route renewals
[Timer]
OnBootSec=45s
OnUnitActiveSec=2min
Unit=remna-oneclick-cwnd.service
[Install]
WantedBy=timers.target
""", 0o644)
    tx.put("/etc/network/if-up.d/remna-oneclick-cwnd", "#!/bin/sh\n/usr/bin/python3 /opt/remnawave-node-oneclick/initcwnd.py\n", 0o755)
    tx.put("/etc/networkd-dispatcher/routable.d/90-remna-oneclick-cwnd", "#!/bin/sh\n/usr/bin/python3 /opt/remnawave-node-oneclick/initcwnd.py\n", 0o755)
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "remna-oneclick-cwnd.service", "remna-oneclick-cwnd.timer"])
    run(["systemctl", "restart", "remna-oneclick-cwnd.service", "remna-oneclick-cwnd.timer"])
    say("已配置 initcwnd=100（IPv4/IPv6 默认路由）、TFO=3 和内核支持的 BBR；保留原接收窗口与现有队列。")


def configure_firewall(tx, c):
    old = run(["nft", "list", "table", "inet", TABLE], check=False)
    if old.returncode == 0 and not (BASE / "state.json").exists():
        raise InstallError("存在同名 nftables 表但缺少管理状态，未覆盖")
    prepare_service(tx, "remna-oneclick-firewall.service")
    write(tx.backup / "firewall-before.nft", old.stdout.decode())
    def restore():
        now = run(["nft", "list", "table", "inet", TABLE], check=False).returncode == 0
        content = ("delete table inet %s\n" % TABLE).encode() if now else b""
        if old.returncode == 0:
            content += old.stdout
        if content:
            run(["nft", "-f", "-"], data=content)
    tx.undo.append(restore)
    tx.put(BASE / "node-api.nft", firewall(c))
    tx.put(BASE / "load-firewall.py", FIREWALL_HELPER, 0o700)
    tx.put("/etc/systemd/system/remna-oneclick-firewall.service", """[Unit]
Description=Remnawave Node API source allowlist
Before=docker.service
After=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /opt/remnawave-node-oneclick/load-firewall.py
[Install]
WantedBy=multi-user.target
""", 0o644)
    run(["python3", BASE / "load-firewall.py"])
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "remna-oneclick-firewall.service"])
    run(["systemctl", "restart", "remna-oneclick-firewall.service"])
    # UFW/firewalld and cloud security groups can still reject accepted packets in another chain.
    if shutil.which("ufw") and "Status: active" in command(["ufw", "status"], check=False):
        WARNINGS.append("UFW 已启用：需在 UFW 中放行面板出口到管理端口及节点业务 TCP/UDP 端口；脚本保留现有规则。")
    if shutil.which("firewall-cmd") and service_state("firewalld")["active"]:
        WARNINGS.append("firewalld 已启用：需在其规则中放行业务端口和面板出口到管理端口。")
    say("管理端口已按面板出口 IP 限制；未清空现有防火墙规则。")


def dns_lookup(p, tcp=False):
    ident = secrets.randbelow(65536)
    question = b"".join(bytes([len(x)]) + x.encode() for x in "www.cloudflare.com".split(".")) + b"\0\0\1\0\1"
    packet = struct.pack("!HHHHHH", ident, 0x100, 1, 0, 0, 0) + question
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
        sock.settimeout(4)
        sock.connect(("127.0.0.1", p))
        if tcp:
            sock.sendall(struct.pack("!H", len(packet)) + packet)
            header = read_exact(sock, 2)
            answer = read_exact(sock, struct.unpack("!H", header)[0])
        else:
            sock.send(packet)
            answer = sock.recv(4096)
    if len(answer) < 12:
        raise InstallError("SmartDNS 响应过短")
    qid, flags, qcount, acount, _, _ = struct.unpack("!HHHHHH", answer[:12])
    if qid != ident or not flags & 0x8000 or flags & 0xF or not acount:
        raise InstallError("SmartDNS 未返回有效 A 记录")
    def skip_name(at):
        while True:
            if at >= len(answer):
                raise InstallError("DNS 名称越界")
            size = answer[at]
            if size & 0xC0 == 0xC0:
                if at + 1 >= len(answer):
                    raise InstallError("DNS 指针越界")
                return at + 2
            at += 1
            if size == 0:
                return at
            if size > 63 or at + size > len(answer):
                raise InstallError("DNS 名称无效")
            at += size
    at = 12
    for _ in range(qcount):
        at = skip_name(at) + 4
    found = False
    for _ in range(acount):
        at = skip_name(at)
        if at + 10 > len(answer):
            raise InstallError("DNS 记录越界")
        record_type, record_class, _, length = struct.unpack("!HHIH", answer[at:at + 10])
        at += 10
        if at + length > len(answer):
            raise InstallError("DNS 记录长度无效")
        if record_type == 1 and record_class == 1 and length == 4:
            found = True
        at += length
    if not found:
        raise InstallError("SmartDNS 响应中没有 A 记录")
    return True


def read_exact(sock, length):
    data = b""
    while len(data) < length:
        piece = sock.recv(length - len(data))
        if not piece:
            raise InstallError("DNS TCP 连接提前关闭")
        data += piece
    return data


def configure_dns(tx, c):
    if not c["smartdns"]:
        return
    if not shutil.which("smartdns"):
        # Prevent a newly installed distro unit from taking existing port 53.
        policy = Path("/usr/sbin/policy-rc.d")
        if policy.is_symlink():
            raise InstallError("policy-rc.d 为符号链接；请先自行安装 smartdns 包后重试")
        old = policy.read_bytes() if policy.exists() else None
        mode = policy.stat().st_mode & 0o777 if old is not None else None
        saved = tx.backup / "policy-rc.d"
        if old is not None:
            saved.write_bytes(old)
            saved.chmod(mode)
        write(policy, '#!/bin/sh\ncase "$1" in smartdns|smartdns.service) exit 101;; esac\n' +
              ('exec ' + str(saved) + ' "$@"\n' if old is not None else 'exit 0\n'), 0o755)
        try:
            apt(["smartdns"])
        finally:
            if old is None:
                policy.unlink(missing_ok=True)
            else:
                write(policy, old.decode(), mode)
        run(["systemctl", "disable", "--now", "smartdns.service"], check=False)
    prepare_service(tx, "remna-oneclick-smartdns.service")
    config = """server-name remna-oneclick
bind 127.0.0.1:%s
bind-tcp 127.0.0.1:%s
cache-size 4096
cache-persist no
prefetch-domain yes
serve-expired yes
speed-check-mode none
dualstack-ip-selection no
ca-file /etc/ssl/certs/ca-certificates.crt
log-level warn
audit-enable no
server-https https://1.1.1.1/dns-query
""" % (c["dns_port"], c["dns_port"])
    tx.put(BASE / "smartdns.conf", config)
    binary = shutil.which("smartdns")
    tx.put("/etc/systemd/system/remna-oneclick-smartdns.service", """[Unit]
Description=Remnawave SmartDNS IPv4 Cloudflare DoH
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=%s -f -c /opt/remnawave-node-oneclick/smartdns.conf -p /run/remna-oneclick-smartdns.pid
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
""" % binary, 0o644)
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "remna-oneclick-smartdns.service"])
    run(["systemctl", "restart", "remna-oneclick-smartdns.service"])
    deadline = time.monotonic() + 25
    while True:
        try:
            dns_lookup(c["dns_port"])
            dns_lookup(c["dns_port"], tcp=True)
            break
        except (OSError, InstallError):
            if time.monotonic() > deadline:
                raise InstallError("SmartDNS 的 TCP/UDP 查询未通过，已停止后续部署")
            time.sleep(1)
    say("SmartDNS TCP/UDP 实测通过：127.0.0.1:%s → IPv4 1.1.1.1 DoH。" % c["dns_port"])


def validate_crypto(key):
    payload = json.loads(base64.b64decode(key))
    with tempfile.TemporaryDirectory(prefix="remna-key-", dir=str(BASE)) as directory:
        directory = Path(directory)
        for field in ("caCertPem", "nodeCertPem", "nodeKeyPem", "jwtPublicKey"):
            write(directory / field, payload[field].replace("\\n", "\n"))
        ca, cert, private, jwt = [directory / field for field in
                                 ("caCertPem", "nodeCertPem", "nodeKeyPem", "jwtPublicKey")]
        try:
            run(["openssl", "verify", "-check_ss_sig", "-CAfile", ca, ca])
            run(["openssl", "verify", "-CAfile", ca, cert])
            run(["openssl", "pkey", "-pubin", "-in", jwt, "-noout"])
            public = run(["openssl", "x509", "-in", cert, "-pubkey", "-noout"]).stdout
            from_cert = run(["openssl", "pkey", "-pubin", "-outform", "DER"], data=public).stdout
            from_key = run(["openssl", "pkey", "-in", private, "-pubout", "-outform", "DER"]).stdout
            if from_cert != from_key:
                raise InstallError("Node 证书与私钥不匹配")
        except InstallError:
            raise InstallError("SECRET_KEY 的证书链、有效期、公钥或私钥校验失败；请从面板重新复制")
    say("SECRET_KEY 证书链、有效期及公私钥匹配校验通过。")


def config_inputs(old, dry=False):
    say("\nRemnawave Node 一键安装器 v" + VERSION)
    say("1 = API 自动创建节点/SS2022 AES256/订阅 Host；2 = 使用面板 SECRET_KEY 接入已有节点。")
    c = dict(old)
    c["mode"] = ask("对接方式", old.get("mode", "1"), lambda x: x if x in ("1", "2") else (_ for _ in ()).throw(ValueError("选 1 或 2")))
    if old and c["mode"] != old["mode"]:
        raise InstallError("已有部署不能切换对接模式；请使用原模式重复运行")
    api = None
    if c["mode"] == "1":
        c["panel_url"] = ask("面板 HTTPS 地址，例如 https://panel.example.com", old.get("panel_url"), url)
        token = ask("面板 API Token（不保存，需读取/创建/更新/删除 Node、Profile、Host 及更新内部组权限）", hidden=True)
        api = API(c["panel_url"], token)
        c["name"] = ask("节点名称", old.get("name", "Node-" + socket.gethostname().split(".")[0][:15]), node_name)
        c["management_address"] = ask("面板直接连接本机的公网 IP/IPv6/域名", old.get("management_address"), node_address)
    c["api_port"] = ask("Node 管理端口（不是用户连接端口）", old.get("api_port", 2222), port)
    c["image_tag"] = ask("Node 镜像固定版本（已验证 3.4.2 配合面板 3.4.5）", old.get("image_tag", "3.4.2"), image_tag)
    c["panel_ips"] = ask("面板实际出口 IP/CIDR，多个用逗号分隔（可填 IPv6；CDN IP 通常不是面板出口）",
                         ",".join(old["panel_ips"]) if old.get("panel_ips") else None, networks)
    if c["mode"] == "2":
        existing = None
        env = BASE / ".env"
        if env.exists() and old:
            match = re.search(r"^SECRET_KEY=([A-Za-z0-9+/=]+)$", env.read_text(), re.M)
            existing = match.group(1) if match else None
        c["secret"] = ask("粘贴面板生成的 SECRET_KEY（隐藏输入）", existing, secret_key, hidden=True)
        c["smartdns"] = ask("另建 SmartDNS 1.1.1.1 DoH 实例并输出 SS2022 配置参考？y/n",
                            "y" if old.get("smartdns", True) else "n", yesno)
    else:
        c["secret"] = secret_key(api.call("/keygen")["secretKey"]) if not dry else "DRY_RUN"
        c["smartdns"] = True
    if c["smartdns"]:
        c["dns_port"] = ask("SmartDNS 本地端口（保留原有 53 端口 DNS 服务）", old.get("dns_port", 6053), port)
        c["ss_port"] = ask("SS2022 AES256 业务端口", old.get("ss_port", 2443), port)
        c["source_ip"] = ask("IPv4 出口的本机网卡地址，NAT 填私网 IP，0.0.0.0 自动选择",
                              old.get("source_ip", default_source()), source_ip)
        default_listen = "::" if ":" in c.get("management_address", "") else "0.0.0.0"
        c["listen_address"] = ask("SS 监听地址（0.0.0.0=IPv4；::=IPv6/双栈，出口仍走 IPv4）",
                                  old.get("listen_address", default_listen),
                                  lambda x: x if x in ("0.0.0.0", "::") else (_ for _ in ()).throw(ValueError("填 0.0.0.0 或 ::")))
        if len({c["api_port"], c["dns_port"], c["ss_port"]}) != 3:
            raise InstallError("管理、SmartDNS 和 SS 业务端口必须不同")
    if c["mode"] == "1":
        c["public_address"] = ask("订阅 Host 的连接 IP/域名（可填转发域名）", old.get("public_address", c["management_address"]), host)
        c["public_port"] = ask("订阅 Host 外部端口（有转发时可不同）", old.get("public_port", c["ss_port"]), port)
        c["country"] = ask("国家代码，例如 HK/JP/MY", old.get("country", "XX"),
                           lambda x: x.upper() if re.fullmatch(r"[A-Za-z]{2}", x) else (_ for _ in ()).throw(ValueError("请输入两个英文字母")))
        if not dry:
            # Read-only checks before local or panel mutation.
            nodes = api.call("/nodes")
            profiles = api.call("/config-profiles")["configProfiles"]
            api.call("/hosts")
            squads = api.call("/internal-squads")["internalSquads"]
            if old.get("node_uuid"):
                owned = next((n for n in nodes if n["uuid"] == old["node_uuid"]), None)
                if not owned or owned.get("note") != OWNER + ":" + old["owner_id"]:
                    raise InstallError("面板节点已删除或不属于脚本，停止覆盖")
                profile = next((p for p in profiles if p["uuid"] == old["profile_uuid"]), None)
                if not profile or profile["name"] != "OneClick-" + old["owner_id"][:12]:
                    raise InstallError("原脚本配置 Profile 已更名/删除，停止覆盖")
                c["_validation_profile"] = profile["config"]
            elif any(n["name"] == c["name"] for n in nodes):
                raise InstallError("面板已有同名节点；请换名称或使用 SECRET_KEY 模式")
            say("选择加入现有内部组，已有用户需属于该组；0 = 暂不加入：")
            for i, squad in enumerate(squads, 1):
                say("%s. %s" % (i, safe_text(squad["name"])))
            default = next((str(i) for i, s in enumerate(squads, 1) if s["uuid"] == old.get("squad_uuid")), "1" if len(squads) == 1 else "0")
            chosen = ask("内部组编号", default, lambda x: int(x) if x.isdigit() and 0 <= int(x) <= len(squads) else (_ for _ in ()).throw(ValueError("编号无效")))
            c["squad_uuid"] = squads[chosen - 1]["uuid"] if chosen else None
    # Existing panel resources aren't overwritten on rerun. Retain user edits.
    if old.get("node_uuid"):
        immutable = ["panel_url", "name", "management_address", "api_port", "dns_port", "ss_port",
                     "source_ip", "listen_address", "public_address", "public_port", "country", "squad_uuid"]
        changed = [key for key in immutable if c.get(key) != old.get(key)]
        if changed:
            raise InstallError("已有 API 部署的对接参数应在面板修改，重复运行请保留：" + ", ".join(changed))
    c["owner_id"] = old.get("owner_id", str(uuid.uuid4()))
    return c, api


def port_precheck(c, old):
    if old:
        for key in ("api_port", "dns_port", "ss_port"):
            if old.get(key) != c.get(key):
                raise InstallError("重复运行不能直接更改已部署端口；保持原端口以保护现有服务")
        return
    text = command(["ss", "-H", "-lntu"])
    occupied = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 5:
            match = re.search(r":([0-9]+)$", fields[4])
            if match:
                occupied.add(int(match.group(1)))
    wanted = [c["api_port"]] + ([c["dns_port"]] if c["smartdns"] else [])
    if c["mode"] == "1":
        wanted.append(c["ss_port"])
    for p in wanted:
        if p in occupied:
            raise InstallError("端口 %s 已有服务监听，未停止原服务；请更换端口" % p)


def create_panel(tx, c, api):
    if c.get("node_uuid"):
        say("复用脚本已创建的面板节点、Profile、Host；保留面板上的现有设置。")
        return
    profile = api.call("/config-profiles", {"name": "OneClick-" + c["owner_id"][:12],
                                          "config": json.loads((BASE / "ss2022-profile.json").read_text())})
    c["profile_uuid"] = profile["uuid"]
    def checkpoint():
        write(tx.backup / "panel-created.json", {k: c.get(k) for k in
              ("owner_id", "profile_uuid", "inbound_uuid", "node_uuid", "host_uuid", "squad_uuid")})
    checkpoint()
    tx.undo.append(lambda: api.call("/config-profiles/" + profile["uuid"], method="DELETE"))
    inbound = next((i for i in profile["inbounds"] if i["tag"] == "ONECLICK_SS2022"), None)
    if not inbound:
        raise InstallError("面板未识别 SS2022 入站，检查面板版本兼容性")
    c["inbound_uuid"] = inbound["uuid"]
    checkpoint()
    node = api.call("/nodes", {"name": c["name"], "address": c["management_address"], "port": c["api_port"],
        "proxyUrl": None, "countryCode": c["country"], "note": OWNER + ":" + c["owner_id"],
        "configProfile": {"activeConfigProfileUuid": profile["uuid"], "activeInbounds": [inbound["uuid"]]}})
    c["node_uuid"] = node["uuid"]
    checkpoint()
    tx.undo.append(lambda: api.call("/nodes/" + node["uuid"], method="DELETE"))
    mappings = {"xrayJson": [{"op": "set", "to": "streamSettings.sockopt.tcpFastOpen", "value": True}],
                "mihomo": [{"op": "set", "to": "tfo", "value": True}],
                "singbox": [{"op": "set", "to": "tcp_fast_open", "value": True}]}
    h = api.call("/hosts", {"remark": c["name"] + " SS2022", "address": c["public_address"], "port": c["public_port"],
          "nodes": [node["uuid"]], "mapper": mappings,
          "inbound": {"configProfileUuid": profile["uuid"], "configProfileInboundUuid": inbound["uuid"]}})
    c["host_uuid"] = h["uuid"]
    checkpoint()
    tx.undo.append(lambda: api.call("/hosts/" + h["uuid"], method="DELETE"))
    if c.get("squad_uuid"):
        squad = api.call("/internal-squads/" + c["squad_uuid"])
        ids = [i["uuid"] for i in squad["inbounds"]]
        if inbound["uuid"] not in ids:
            api.call("/internal-squads", {"uuid": squad["uuid"], "inbounds": ids + [inbound["uuid"]]}, "PATCH")
            def undo_squad():
                current = api.call("/internal-squads/" + squad["uuid"])
                api.call("/internal-squads", {"uuid": squad["uuid"],
                    "inbounds": [i["uuid"] for i in current["inbounds"] if i["uuid"] != inbound["uuid"]]}, "PATCH")
            tx.undo.append(undo_squad)
    say("已创建独立 SS2022 AES256 Profile、Node 和订阅 Host；入站/出口及客户端订阅已启用 TFO。")


def verify_kernel():
    say("TFO 内核值：" + command(["sysctl", "-n", "net.ipv4.tcp_fastopen"]))
    say("拥塞控制：" + command(["sysctl", "-n", "net.ipv4.tcp_congestion_control"]))
    for family in ("-4", "-6"):
        lines = [line for line in command(["ip", "-o", family, "route", "show", "table", "all", "default"], check=False).splitlines()
                 if line.startswith("default ")]
        if not lines:
            say(family + " 无默认路由，后续由定时器处理。")
        for line in lines:
            p = shlex.split(line)
            at = p.index("initcwnd") if "initcwnd" in p else -1
            if at < 0 or p[at + (2 if p[at + 1] == "lock" else 1)] != "100":
                raise InstallError("默认路由 initcwnd 校验未通过：" + family)
        if lines:
            say(family + " 默认路由 initcwnd=100 校验通过。")


def node_running():
    if not shutil.which("docker"):
        return False
    result = run(["docker", "inspect", "--format", "{{.State.Running}}", CONTAINER], check=False)
    return result.returncode == 0 and result.stdout.strip() == b"true"


def check_node_listener(c):
    payload = json.loads(base64.b64decode(c["secret"]))
    cert = payload["nodeCertPem"].replace("\\n", "\n")
    expected = ssl.PEM_cert_to_DER_cert(cert)
    context = ssl.create_default_context(cadata=payload["caCertPem"].replace("\\n", "\n"))
    # The local certificate is pinned below; Remnawave uses a generated certificate hostname.
    context.check_hostname = False
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    deadline = time.monotonic() + 25
    while True:
        try:
            with socket.create_connection(("127.0.0.1", c["api_port"]), timeout=3) as raw:
                with context.wrap_socket(raw, server_hostname="localhost") as tls:
                    if tls.getpeercert(binary_form=True) != expected:
                        raise InstallError("管理端口上的证书不属于本次 Node")
            say("Node 管理端口监听及 TLS 证书匹配校验通过。")
            return
        except (OSError, ssl.SSLError):
            if time.monotonic() >= deadline:
                raise InstallError("Node 管理端口未就绪，或容器持续重启；检查密钥、端口和镜像版本")
            time.sleep(1)


RUNTIME_INSPECTION = r'''
const fs=require('fs'), http=require('http');
try {
 const d='/run/s6/container_environment/';
 const request=http.get({socketPath:'\0'+fs.readFileSync(d+'INTERNAL_SOCKET_PATH','utf8'),
  path:'/internal/get-config?token='+encodeURIComponent(fs.readFileSync(d+'INTERNAL_REST_TOKEN','utf8'))},r=>{
   let body='';r.on('data',b=>body+=b);r.on('end',()=>{
    try {
     const c=JSON.parse(body), ins=(c.inbounds||[]).filter(i=>i.protocol==='shadowsocks');
     const outs=(c.outbounds||[]).filter(o=>o.protocol==='freedom');
     console.log(JSON.stringify({ss:ins.length,
       inboundTFO:ins.length>0&&ins.every(i=>i.streamSettings?.sockopt?.tcpFastOpen===true),
       outboundTFO:outs.length>0&&outs.every(o=>o.streamSettings?.sockopt?.tcpFastOpen===true),
       aes256:ins.length>0&&ins.every(i=>i.settings?.method==='2022-blake3-aes-256-gcm'),
       forceIPv4:outs.length>0&&outs.every(o=>o.settings?.targetStrategy==='ForceIPv4')}));
    } catch {process.exitCode=1;}
   });
 });request.setTimeout(5000,()=>{request.destroy();process.exitCode=1;});
 request.on('error',()=>{process.exitCode=1;});
} catch {process.exitCode=1;}
'''


def inspect_runtime():
    result = run(["docker", "exec", "-i", CONTAINER, "node"], data=RUNTIME_INSPECTION.encode(),
                 timeout=10, check=False)
    try:
        return json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        return None


def manual_summary(c):
    say("Node 容器已运行；需由面板连接并推送所选 Profile，才能提供用户代理服务。")
    say("面板 Node 管理端口填写 %s，SECRET_KEY 必须与本机输入一致。" % c["api_port"])
    runtime = inspect_runtime()
    if runtime and runtime["inboundTFO"] and runtime["outboundTFO"]:
        say("已读回 Xray 运行配置，SS 入站和 freedom 出站的 TFO 均为 true。")
    else:
        say("应用 TFO 尚未确认：已有 Profile 的入站与 freedom 出站需有 streamSettings.sockopt.tcpFastOpen=true。")
    if c["smartdns"]:
        say("SS2022 AES256 + SmartDNS + IPv4 出口参考配置：" + str(BASE / "ss2022-profile.json"))
        say("该文件未自动覆盖面板已有 Profile；导入独立 Profile 后为 Node 选择入站，并绑定 Host/内部组。")


def main():
    option = sys.argv[1] if len(sys.argv) > 1 else ""
    if option == "--self-test":
        self_test()
        return 0
    if option not in ("", "--dry-run", "--check"):
        raise InstallError("未知参数；使用 --help 查看用法")
    osinfo, arch = platform_check()
    if option == "--check":
        say("系统：%s %s / %s" % (osinfo["ID"], osinfo["VERSION_ID"], arch))
        for key in ("net.ipv4.tcp_fastopen", "net.ipv4.tcp_congestion_control"):
            if shutil.which("sysctl"):
                say(key + "=" + command(["sysctl", "-n", key], check=False))
        if shutil.which("ip"):
            for family in ("-4", "-6"):
                say(command(["ip", "-o", family, "route", "show", "table", "all", "default"], check=False))
        if shutil.which("docker"):
            say("本脚本容器运行：" + str(node_running()))
        return 0
    if os.geteuid() != 0:
        raise InstallError("安装及 dry-run 请使用 sudo bash 或 root 运行")
    dry = option == "--dry-run"
    if BASE.is_symlink():
        raise InstallError("安装目录为符号链接，拒绝操作")
    lock_path = Path("/run/remna-oneclick.lock")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise InstallError("已有安装器运行，请等待完成")
        old = json.loads((BASE / "state.json").read_text()) if (BASE / "state.json").exists() else {}
        if old and old.get("installer") != OWNER:
            raise InstallError("现有 state.json 不属于本脚本")
        if not old:
            owned_files = [BASE / "compose.yaml", BASE / ".env", BASE / "state.json",
                           Path("/etc/sysctl.d/99-remna-oneclick.conf"),
                           Path("/etc/network/if-up.d/remna-oneclick-cwnd"),
                           Path("/etc/networkd-dispatcher/routable.d/90-remna-oneclick-cwnd")]
            owned_files += [Path("/etc/systemd/system") / unit for unit in UNITS]
            if any(p.exists() or p.is_symlink() for p in owned_files):
                raise InstallError("存在同名配置但没有本脚本的部署状态，未覆盖；检查 /opt/remnawave-node-oneclick")
        if shutil.which("docker"):
            inspect = run(["docker", "inspect", "--format", '{{index .Config.Labels "io.remna.oneclick.owner"}}', CONTAINER], check=False)
            if inspect.returncode == 0 and (not old or inspect.stdout.decode().strip() != old.get("owner_id")):
                raise InstallError("同名容器不是本脚本管理的，未覆盖")
        if not shutil.which("ip") or not shutil.which("ss"):
            if dry:
                raise InstallError("dry-run 缺少 iproute2；未自动安装依赖")
            apt(["iproute2"])
        c, api = config_inputs(old, dry)
        port_precheck(c, old)
        say("\n部署计划：Node API %s，面板出口 %s，固定镜像 remnawave/node:%s" %
            (c["api_port"], ",".join(c["panel_ips"]), c["image_tag"]))
        if c["smartdns"]:
            say("SmartDNS 127.0.0.1:%s / SS2022 AES256 TCP+UDP %s / IPv4 出口 %s" %
                (c["dns_port"], c["ss_port"], c["source_ip"]))
        if dry:
            say("dry-run 完成；未安装依赖、写配置、修改路由、防火墙或面板资源。")
            return 0
        BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
        BASE.chmod(0o700)
        tx = Transaction()
        before_services = {u: service_state(u) for u in UNITS}
        write(tx.backup / "services-before.json", before_services)
        previous_container = node_running()
        previous_container_exists = shutil.which("docker") and run(["docker", "inspect", "--format", "{{.Id}}", CONTAINER], check=False).returncode == 0
        container_changed = False
        pending = False
        try:
            dependencies = ["python3", "ca-certificates", "curl", "openssl", "iproute2", "kmod", "nftables"]
            apt(dependencies)
            validate_crypto(c["secret"])
            ensure_docker(osinfo, arch)
            say("拉取固定 Node 镜像；只操作本脚本容器。")
            run(["docker", "pull", "remnawave/node:" + c["image_tag"]], timeout=900)
            if c["smartdns"]:
                if not old.get("profile_uuid"):
                    master = None
                    if old and (BASE / "ss2022-profile.json").exists():
                        master = json.loads((BASE / "ss2022-profile.json").read_text())["inbounds"][0]["settings"]["password"]
                    tx.put(BASE / "ss2022-profile.json", make_profile(c, master))
                validation_path = BASE / "ss2022-profile.json"
                if c.get("_validation_profile"):
                    validation_path = tx.backup / "current-profile-validation.json"
                    write(validation_path, c["_validation_profile"])
                run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "/usr/local/bin/xray",
                     "-v", str(validation_path) + ":/tmp/config.json:ro",
                     "remnawave/node:" + c["image_tag"], "run", "-test", "-c", "/tmp/config.json"], timeout=90)
                say("SS2022 配置通过所选镜像内 Xray 语法校验。")
            configure_network(tx)
            configure_firewall(tx, c)
            configure_dns(tx, c)
            tx.put(BASE / ".env", "NODE_PORT=%s\nSECRET_KEY=%s\n" % (c["api_port"], c["secret"]))
            tx.put(BASE / "compose.yaml", compose(c))
            dc = ["docker", "compose", "--project-name", OWNER, "--project-directory", str(BASE), "-f", str(BASE / "compose.yaml")]
            run(dc + ["config", "--quiet"])
            if c["mode"] == "1":
                create_panel(tx, c, api)
            container_changed = True
            run(dc + ["up", "-d", "--no-build"], timeout=180)
            time.sleep(8)
            if not node_running():
                raise InstallError("Node 容器未保持运行；检查 SECRET_KEY 或所选版本，日志可能含密钥请勿公开")
            check_node_listener(c)
            verify_kernel()
            if c["mode"] == "1":
                say("等待面板直接连接并启动 Xray，最多 90 秒…")
                deadline = time.monotonic() + 90
                while True:
                    try:
                        n = api.call("/nodes/" + c["node_uuid"])
                        if n.get("isConnected") and float(n.get("xrayUptime") or 0) > 0:
                            break
                    except InstallError:
                        pass
                    if not node_running():
                        raise InstallError("等待面板时 Node 容器退出")
                    if time.monotonic() >= deadline:
                        pending = True
                        break
                    time.sleep(3)
                if pending:
                    WARNINGS.append("面板尚未连接/Xray 尚未启动，容器和配置已保留；检查云安全组、已有防火墙、面板出口 IP 与直接连接地址。")
                else:
                    say("面板已连接，Xray 已启动。")
                    runtime = inspect_runtime()
                    if runtime and all(runtime.get(x) for x in ("inboundTFO", "outboundTFO", "aes256", "forceIPv4")):
                        say("已读回 Xray 运行配置：AES256、入站/出口 TFO、IPv4 出口均已启用。")
                    else:
                        WARNINGS.append("面板已连接，但运行配置与默认 AES256/TFO/IPv4 模板不同或未能读回；保留现有配置，请在面板检查。")
            else:
                manual_summary(c)
            state = {k: v for k, v in c.items() if k != "secret" and not k.startswith("_")}
            state.update(installer=OWNER, installer_version=VERSION, last_backup=str(tx.backup),
                         status="pending-panel" if pending or c["mode"] == "2" else "online")
            tx.put(BASE / "state.json", state)
            tx.completed = True
        except BaseException:
            if container_changed:
                run(["docker", "stop", CONTAINER], check=False)
                if not previous_container_exists:
                    run(["docker", "rm", CONTAINER], check=False)
            tx.rollback()
            for name, before in before_services.items():
                if name not in tx.services:
                    continue
                if before["enabled"]:
                    run(["systemctl", "enable", name], check=False)
                if before["active"]:
                    run(["systemctl", "restart", name], check=False)
            if old and previous_container_exists and (BASE / "compose.yaml").exists():
                restore_dc = ["docker", "compose", "--project-name", OWNER, "-f", str(BASE / "compose.yaml")]
                run(restore_dc + ["create", "--force-recreate"], check=False, timeout=120)
                if previous_container:
                    run(restore_dc + ["start"], check=False, timeout=120)
            say("已安装的软件包与下载的镜像保留；未卸载其他服务。")
            raise
        say("\n配置目录：" + str(BASE) + "；本次备份：" + str(tx.backup))
        say("密钥文件权限 600，目录 700；API Token 未保存。")
        say("云安全组需放行 TCP 管理端口（仅面板出口），以及 SS 业务 TCP/UDP 端口。")
        if c["mode"] == "1" and not c.get("squad_uuid"):
            WARNINGS.append("未选择内部组：需要在面板把此入站加入用户所属组后，用户订阅才会包含新节点。")
        for message in WARNINGS:
            say("注意：" + message)
        say("检查命令：sudo bash remnawave-node-install.sh --check")
        return 3 if pending else 0


def self_test():
    # Regression cases focus on preventing accidental network/credential damage.
    samples = [
        "default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.2 metric 100 initcwnd 32 initrwnd 32",
        "default via fe80::1 dev eth0 proto ra metric 1024 pref medium",
        "default via 10.0.0.1 dev eth0 onlink metric 20",
        "default proto static metric 5 nexthop via 10.0.0.1 dev eth0 weight 1 nexthop via 10.0.1.1 dev eth1 weight 1",
        "default via 10.0.0.1 dev eth0 table 500 proto static metric 5 initcwnd lock 32 initrwnd lock 32"]
    for line in samples:
        before = shlex.split(line)
        after = change_cwnd(line)
        normalized = after[:]
        at = normalized.index("initcwnd")
        del normalized[at:at + (3 if normalized[at + 1] == "lock" else 2)]
        original = before[:]
        if "initcwnd" in original:
            at = original.index("initcwnd")
            del original[at:at + (3 if original[at + 1] == "lock" else 2)]
        assert original == normalized, "route attributes were lost"
        at = after.index("initcwnd")
        assert after[at + (2 if after[at + 1] == "lock" else 1)] == "100"
    expired = change_cwnd("default via fe80::1 dev eth0 proto ra expires 900sec pref medium")
    assert expired[expired.index("expires") + 1] == "900"
    # Test the actual standalone boot helper, including non-main routing tables.
    import ast
    tree = ast.parse(CWND_HELPER)
    helper_function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "parts")
    scope = {"shlex": shlex, "re": re}
    exec(compile(ast.Module(body=[helper_function], type_ignores=[]), "<cwnd-helper>", "exec"), scope)
    for sample in samples:
        assert scope["parts"](sample, 100) == change_cwnd(sample)
    escaped_multipath = "default table 600 \\\tnexthop via 10.0.0.1 dev eth0 weight 1 \\\tnexthop via 10.0.1.1 dev eth1 weight 2"
    parsed = change_cwnd(escaped_multipath)
    assert parsed.count("nexthop") == 2
    assert parsed.index("initcwnd") < parsed.index("nexthop")
    assert scope["parts"](escaped_multipath, 100) == parsed
    assert node_address("2001:db8::10") == "[2001:db8::10]"
    assert host("[2001:db8::1]") == "2001:db8::1"
    assert url("https://panel.example.com/api/") == "https://panel.example.com"
    for validator, value in [(port, "22;reboot"), (port, "0"), (port, "65536"),
                             (host, "x.example\n$(id)"), (host, "evil..example"),
                             (url, "http://panel.example.com"), (url, "https://user:pass@panel.example.com"),
                             (networks, "0.0.0.0/0"), (networks, "::/0"),
                             (image_tag, "latest"), (secret_key, "abc\nSECRET=x")]:
        try:
            validator(value)
        except (ValueError, InstallError):
            pass
        else:
            raise AssertionError("unsafe input accepted")
    c = {"api_port": 2222, "ss_port": 2443, "dns_port": 6053, "source_ip": "10.0.0.2",
         "panel_ips": ["192.0.2.10/32", "2001:db8::10/128"], "image_tag": "3.4.2", "owner_id": "test-owner"}
    nft = firewall(c)
    assert "flush ruleset" not in nft and "ip6 saddr 2001:db8::10/128" in nft
    assert "tcp dport 2222 drop" in nft and "2443 drop" not in nft
    profile = make_profile(c)
    assert len(base64.b64decode(profile["inbounds"][0]["settings"]["password"])) == 32
    assert profile["inbounds"][0]["streamSettings"]["sockopt"]["tcpFastOpen"] is True
    assert profile["outbounds"][0]["streamSettings"]["sockopt"]["tcpFastOpen"] is True
    assert profile["outbounds"][0]["settings"]["targetStrategy"] == "ForceIPv4"
    assert compose(c)["services"]["node"]["network_mode"] == "host"
    assert "SECRET_KEY" not in json.dumps(compose(c))
    # Fresh hosts without Docker must progress to installation; existing daemons must not restart.
    real_which = shutil.which
    real_run = globals()["run"]
    shutil.which = lambda name: None
    try:
        assert node_running() is False
    finally:
        shutil.which = real_which
    calls = []
    shutil.which = lambda name: "/usr/bin/docker" if name == "docker" else real_which(name)
    globals()["run"] = lambda args, **kw: (calls.append(args) or subprocess.CompletedProcess(args, 0, b"ok", b""))
    real_say = globals()["say"]
    globals()["say"] = lambda message: None
    try:
        ensure_docker({"ID": "debian"}, "amd64")
        assert calls == [["docker", "info"], ["docker", "compose", "version"]]
    finally:
        shutil.which = real_which
        globals()["run"] = real_run
        globals()["say"] = real_say
    # Transaction restores modes/content and deletes only its own newly created file.
    global BASE
    previous_base = BASE
    with tempfile.TemporaryDirectory() as temp:
        BASE = Path(temp)
        existing = BASE / "existing"
        existing.write_text("old-content")
        existing.chmod(0o640)
        tx = Transaction()
        tx.put(existing, "new-secret")
        tx.put(BASE / "new-file", "secret")
        unrelated = BASE / "unrelated"
        unrelated.write_text("keep")
        # Don't invoke host systemctl in the offline regression.
        real_run = globals()["run"]
        globals()["run"] = lambda *a, **k: subprocess.CompletedProcess(a, 0, b"", b"")
        try:
            tx.rollback(announce=False)
        finally:
            globals()["run"] = real_run
        assert existing.read_text() == "old-content"
        assert existing.stat().st_mode & 0o777 == 0o640
        assert not (BASE / "new-file").exists()
        assert unrelated.read_text() == "keep"
        assert (tx.backup / "manifest.json").stat().st_mode & 0o777 == 0o600
    BASE = previous_base
    say("离线自检通过：路由属性保留、IPv6、输入防注入、API 防火墙、AES256/TFO 配置、备份回退与权限。")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        say("操作已中断。")
        sys.exit(130)
    except (InstallError, OSError, ValueError, KeyError, TypeError) as error:
        say("错误：" + (str(error) if isinstance(error, InstallError) else "配置/环境错误，未输出可能含密钥的异常内容"))
        sys.exit(1)

REMNA_ONECLICK_PYTHON
