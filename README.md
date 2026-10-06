# Remnawave Node One-click Installer

在目标 Linux 服务器执行以下命令，即可下载脚本并开始交互式安装：

```bash
curl -fsSL https://raw.githubusercontent.com/GHUNLIL/remnawave-node-oneclick/main/remnawave-node-install.sh -o remnawave-node-install.sh && sudo bash remnawave-node-install.sh
```

将同目录的 `remnawave-node-install.sh` 上传到**需要安装 Node 的 Linux 服务器**，运行：

```bash
sudo bash remnawave-node-install.sh
```

支持 Debian 12/13、Ubuntu 22.04/24.04/26.04，amd64/arm64，使用 systemd。默认固定镜像 `remnawave/node:3.4.2`，对应已验证的面板 3.4.5；也可以输入其他固定版本，安装时会用镜像自带的 Xray 校验配置。首次运行需要服务器能访问发行版仓库、Docker 官方仓库和 Docker Hub。

**方式 1：API 自动对接**

输入面板 HTTPS 地址、API Token、节点名称、管理地址/端口、面板实际出口 IP、SS 业务端口、订阅连接地址/外部端口，再选择内部组。Token 需要读取、创建、更新、删除节点/配置/Host，以及读取、更新内部组的权限；删除权限用于失败回退。

脚本创建独立的 SS2022 AES256 Profile、Node 和订阅 Host，加入选中的已有内部组。已有用户属于该组后会获得此节点。不会给用户创建账号或更改流量与到期时间。Profile 使用 SmartDNS → IPv4 `1.1.1.1` DoH，强制 IPv4 业务出口，并在服务端入站、出站和支持的客户端订阅配置中启用 TFO。IPv6 管理地址会自动加方括号，直接连接服务器，不创建中转隧道。

**方式 2：SECRET_KEY 对接**

先在面板添加 Node，选择 Profile，复制其 `SECRET_KEY`。运行脚本时选 `2`，输入同一管理端口、密钥和面板出口 IP。脚本部署 Docker Node，保留面板已有 Profile。可选安装 SmartDNS，并生成 `/opt/remnawave-node-oneclick/ss2022-profile.json` 作为独立 Profile 的导入参考；不会自动覆盖原 Profile。

已有 Profile 的入站和 freedom 出站需要包含 `streamSettings.sockopt.tcpFastOpen=true`，应用才能使用 TFO。脚本会尝试读回运行配置并报告结果。仅系统 `tcp_fastopen=3` 不能证明应用 TFO 已启用。

**端口和出口**

- `2222` 默认是面板管理端口；仅允许填写的面板出口 IP/CIDR，支持 IPv4/IPv6。不要填写 CDN 边缘 IP，除非它确实是面板连接 Node 的出口。面板在同一服务器的 Docker 网桥中运行时，可输入实际桥接网段。
- `2443` 默认是 SS 业务端口，需要开放 TCP 和 UDP。转发场景下，订阅 Host 的外部端口可与本机业务端口不同。
- `6053` 默认是 SmartDNS 本地端口，只监听 `127.0.0.1`，保留现有 53 端口解析服务和系统 DNS。
- IPv4 出口应填写**本机网卡地址**。NAT 服务器填私网 IPv4，不填未绑定在本机网卡上的公网映射 IP。`0.0.0.0` 由系统选择。
- `::` 监听适合 IPv6/双栈入站，业务出口仍为 IPv4；双栈接入取决于服务器内核的 IPv6 配置。仅 IPv4 入站可以用 `0.0.0.0`。

脚本自建管理端口来源限制，不清空其他防火墙规则。已有 UFW、firewalld，以及云厂商安全组仍可能拦截连接，需在对应规则里放行管理端口和业务端口。

**优化与重复运行**

设置 TCP 初始拥塞窗口 `initcwnd=100`、内核 TFO=3、MTU 黑洞探测、内核支持的 BBR。保留原 `initrwnd`、网关、源地址、路由表、metric 和现有 HTB/CAKE/FQ 等队列。systemd 服务、网络上线钩子和每两分钟的补偿定时器会在路由重建后恢复窗口值。已有 Docker 和其他容器不重启；不更换内核，不重启服务器，不升级全系统或清理用户数据。

安装目录和备份目录权限为 700，密钥/配置文件为 600。API Token 仅在当前进程内使用，不保存。容器日志滚动限制为 10 MiB × 3。Node 原始启动日志可能包含内部令牌，请勿公开粘贴。Docker 组成员具有读取容器环境的能力。

重复运行会复用本脚本创建的部署，保留面板中的现有节点/Profile/Host 设置。管理地址、业务端口等面板参数后续请在面板调整；脚本重复运行保持原输入即可。可调整面板出口允许列表和 Node 镜像版本。升级前会校验面板当前 Profile，备份配置；失败时恢复本次修改。软件包、官方 Docker APT 仓库和下载的镜像保留。API 请求因网络中断而结果不确定时，检查面板中的 `OneClick-*` Profile；已返回的资源 UUID 保存在当次备份的 `panel-created.json`，方便处理未能自动回退的资源。

```bash
# 交互预览，不安装依赖或修改服务器/面板配置
sudo bash remnawave-node-install.sh --dry-run

# 读取当前系统参数和本脚本容器状态
sudo bash remnawave-node-install.sh --check

# 离线回归检查，不操作系统网络、Docker 或面板
bash remnawave-node-install.sh --self-test
```

退出码 `0` 表示脚本阶段完成；SECRET_KEY 模式仍需面板选好 Profile 并完成连接。API 模式退出码 `3` 表示本地部署和面板资源已保留，但面板连接/Xray 启动尚未确认，需检查连通性。退出码 `1` 表示失败，会尝试回退本次配置；`130` 表示用户中断。备份位于 `/opt/remnawave-node-oneclick/backups/`。

验证已通过：Bash 语法、离线自检、6 项回归检查；官方 Node 3.4.2 镜像内的 Xray 配置检查；隔离网络命名空间内的 IPv4/IPv6、策略路由、多路径路由和 nftables 原子替换；独立临时 SmartDNS 的真实 TCP/UDP 查询；现有 Node 的只读证书校验。API 创建和失败回退使用模拟 API 验证，没有新增生产面板节点，也没有在全新 VPS 上完整执行安装流程。验证过程中已有 Node 和 SmartDNS 服务的进程身份保持一致。

实现依据：[Remnawave Node 官方文档](https://docs.rw/install/remnawave-node/)、[Docker Debian 安装说明](https://docs.docker.com/engine/install/debian/)、[Docker Ubuntu 安装说明](https://docs.docker.com/engine/install/ubuntu/)、[Linux TCP 参数](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html)、[ip-route 手册](https://man7.org/linux/man-pages/man8/ip-route.8.html)。

本仓库为独立安装工具，不属于 Remnawave 官方项目。

本地验证：

```bash
bash -n remnawave-node-install.sh
bash remnawave-node-install.sh --self-test
python3 test_installer.py
```
