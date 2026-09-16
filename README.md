# locrdp

让每一台 Windows 电脑安全启用远程桌面和远程协助。

locrdp 是一套面向 Windows 原生 RDP 的连接工具。它保留 `mstsc` 和 Windows 远程协助的使用体验，把设备发现、身份验证、连接协商和复杂网络环境下的路径选择交给 locrdp 处理。两台电脑使用设备码和访问密码即可建立连接，不要求被控电脑拥有公网 IP，也不要求手动映射 RDP 端口。

本仓库当前公开的是 **自建兜底中继部署脚本** 与相关文档。Windows 客户端、信令服务和会员中心等其他组件不在本仓库中发布。

## 产品定位

- 面向 Windows 原生远程桌面和远程协助，而不是重新实现一套远程桌面协议。
- 优先使用 IPv6/P2P 直连；直连不可用时自动使用 TURN 兜底中继。
- 内层 RDP 服务只允许本机回环地址访问，互联网连接由两端 locrdp 客户端处理。
- 适合远程办公、个人电脑管理、轻量运维和临时远程协助。
- 不把 locrdp 作为通用 FRP 端口映射工具，也不要求把 Windows RDP 端口暴露到公网。

## 主要能力

### Windows 原生体验

locrdp 复用 Windows 自带的 RDP 能力。连接成功后，用户仍然使用熟悉的远程桌面体验；需要现场协助时，也可以使用两端可见的 Windows 远程协助模式。

### 设备码连接

被控电脑运行 locrdp 后生成设备码和访问密码。控制端输入这些信息即可发起连接，不需要记忆公网地址、端口或虚拟组网地址。

### 自动选择网络路径

连接建立时，locrdp 会根据网络条件选择路径：

1. 优先尝试 IPv6/P2P 直连。
2. 直连不可用时使用 TURN 兜底中继。
3. 中继只转发端到端加密数据，不承担 RDP 明文解析。

### 文件传输与语音

远程会话中可以发送和接收文件。文件传输使用独立的数据通道，不占用远程画面通道；远程会话关闭后，进行中的传输仍可继续。远程协助期间还可以发起一对一语音通话，语音通道同样优先直连，必要时使用当前中继链路。

### 不暴露 RDP 公网端口

真正面向互联网的是两端 locrdp 客户端，RDP 只在本机 `127.0.0.1` 回环地址上提供服务。使用 locrdp 不需要在家庭路由器或云服务器上开放 Windows RDP 的公网入口。

## 连接流程

```text
被控 Windows 电脑运行 locrdp
        |
        | 设备注册、在线状态与连接协商
        v
控制端输入设备码和访问密码
        |
        +--> IPv6/P2P 直连（优先）
        |
        +--> TURN 兜底中继（直连失败时）
                    |
                    +--> 转发端到端加密数据
```

中继是连接路径的一部分，不是 RDP 服务的公网代理。使用官方中继或自建中继时，RDP 端口都不需要直接暴露给互联网。

## 自建兜底中继

本仓库的脚本在一台 Debian 公网服务器上安装 [eturnal](https://eturnal.net/)，完成以下工作：

- 安装必要依赖和 eturnal 服务。
- 自动检测或接受指定的公网 IPv4 地址。
- 写入 TURN 监听、realm、认证密钥和媒体端口范围。
- 尝试配置 BBR、文件描述符和任务数等吞吐参数。
- 按需放行 `ufw` 或 `firewalld` 端口。
- 使用 locrdp 账号授权并将中继绑定到该账号。
- 注册 UDP/TCP TURN 地址，供 locrdp 客户端选择。

脚本不会安装官方配额模块、流量上报模块或会话限速补丁。它只负责部署用户自己拥有和管理的 TURN 中继。

### 快速部署

在 Debian 公网服务器上执行：

```bash
curl -fsSLO https://www.locrdp.cn/turn/locrdp-selfhost-eturnal-setup.sh \
  && sudo bash locrdp-selfhost-eturnal-setup.sh
```

脚本会交互式询问 locrdp 账号或手机号以及密码。账号验证完成后，脚本会安装并启动 eturnal，然后把当前服务器注册到该账号的自建中继列表。

### 系统要求

- Debian 系统（脚本会检查 `/etc/os-release` 中的发行版标识）。
- root 权限，建议使用 `sudo` 执行。
- 可从服务器访问 `api.locrdp.cn` 和 `eturnal.net`。
- 一个用于绑定中继的 locrdp 账号。
- 公网 IPv4 地址；无法自动识别时可手动设置 `PUBLIC_IP`。

脚本会自动安装或使用以下命令：`curl`、`openssl`、`python3`、`systemctl`、`sysctl`。其中 `apt-get` 用于安装缺失的基础依赖。

### 云安全组和防火墙

请同时在云厂商安全组和服务器本机防火墙放行：

| 用途 | 协议 | 默认端口 |
| --- | --- | --- |
| TURN 监听 | UDP/TCP | `3478` |
| TURN 媒体中继端口 | UDP | `49152-65535` |

脚本会在检测到 `ufw` 或运行中的 `firewalld` 时尝试写入规则，但云安全组通常仍需要手动配置。

### 可选环境变量

在运行脚本前可以通过环境变量覆盖默认值：

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `PUBLIC_IP` | 自动检测 | 指定服务器公网 IPv4 |
| `TURN_PORT` | `3478` | TURN UDP/TCP 监听端口 |
| `RELAY_MIN_PORT` | `49152` | 媒体端口范围起点 |
| `RELAY_MAX_PORT` | `65535` | 媒体端口范围终点 |
| `REALM` | `locrdp-selfhost` | eturnal realm |
| `SELFHOST_TURN_NAME` | 主机短名 | 会员中心显示的中继名称 |
| `SELFHOST_TURN_AREA` | `self` | 中继区域标识，仅允许小写字母 |
| `TURN_CREDENTIAL_TTL` | `3600` | 临时凭据有效期，范围 300-3600 秒 |
| `LOCRDP_API_BASE_URL` | `https://api.locrdp.cn` | 高级场景下覆盖 locrdp API 地址 |
| `LOCRDP_ACCOUNT` | 交互输入 | 预填 locrdp 账号 |
| `LOCRDP_PASSWORD` | 交互输入 | 预填 locrdp 密码，不建议写入 shell 历史 |

示例：

```bash
sudo env PUBLIC_IP=203.0.113.10 \
  SELFHOST_TURN_NAME=home-turn \
  bash locrdp-selfhost-eturnal-setup.sh
```

### 部署后的检查

脚本完成后会打印 TURN URL、服务器编号和配置文件位置。可以在服务器上检查服务状态：

```bash
sudo systemctl status eturnal --no-pager
sudo journalctl -u eturnal --no-pager -n 80
sudo ss -lntup | grep ':3478'
```

默认配置文件为 `/etc/eturnal.yml`，系统调优文件为 `/etc/sysctl.d/99-locrdp-selfhost-eturnal.conf`，systemd 覆盖配置为 `/etc/systemd/system/eturnal.service.d/99-locrdp-selfhost-throughput.conf`。重新运行脚本前，如果已有 `/etc/eturnal.yml`，脚本会先生成带时间戳的备份。

### 常见问题

**脚本提示不是 Debian。**

当前脚本只支持 Debian。请使用 Debian 公网服务器，或在其他发行版上手动部署兼容的 eturnal 配置。

**无法检测公网 IPv4。**

为服务器配置公网 IPv4，或显式指定：

```bash
sudo env PUBLIC_IP=你的公网IPv4 bash locrdp-selfhost-eturnal-setup.sh
```

**服务已启动但客户端无法中继。**

检查云安全组是否同时放行 `3478/udp`、`3478/tcp` 和 `49152-65535/udp`，再检查 `relay_ipv4_addr` 是否为外部可达地址。

**账号验证或绑定失败。**

确认服务器可以访问 `https://api.locrdp.cn`，账号密码正确，并检查系统时间是否准确。绑定令牌有时效限制，脚本会在安装依赖完成后才请求授权信息。

**Windows 家庭版能否使用？**

Windows 家庭版无法开启系统远程桌面服务，这是微软版本限制；远程协助、文件传输和语音功能仍可按客户端支持情况使用。需要完整 RDP 服务时，请使用专业版、企业版或其他支持远程桌面的版本。

## 安全边界与隐私

- 不要把 `LOCRDP_PASSWORD` 写入公开脚本、镜像或 CI 日志。
- 脚本通过 HTTPS 调用 locrdp API，并使用短期授权数据绑定中继。
- 中继服务器会看到网络连接元数据和转发流量，但不应能读取端到端加密的 RDP 数据内容。
- 请把云安全组限制在实际需要的端口，不要额外开放 Windows RDP 端口。
- 脚本会修改 eturnal 配置、systemd 服务和部分内核网络参数；运行前请确认服务器属于你并且允许这些变更。
- eturnal 是独立的第三方软件，使用时还应遵守其许可证和上游安全公告。

## 项目与下载

- 项目主页：[https://www.locrdp.cn](https://www.locrdp.cn)
- Windows 客户端与产品介绍：[https://www.locrdp.cn/index.html](https://www.locrdp.cn/index.html)
- 自建中继脚本：[turn/locrdp-selfhost-eturnal-setup.sh](turn/locrdp-selfhost-eturnal-setup.sh)
- 问题反馈：[GitHub Issues](https://github.com/lowphpcom/locrdp/issues)

本仓库只发布自建中继脚本和文档。客户端、服务端 API、会员中心和其他部署组件可能通过独立渠道提供。

## 许可证

本仓库中的脚本和文档采用 [0BSD（Zero-Clause BSD）](LICENSE.md) 许可证。该许可证允许不受限制地使用、复制、修改和分发本仓库内容，无需保留版权声明。

第三方组件（包括 eturnal）不受本仓库许可证覆盖，具体以各自上游许可证为准。
