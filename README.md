# Tunnelbroker IPv6 Auto-Bind

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-brightgreen.svg)](https://www.gnu.org/software/bash/)

适用于 Hurricane Electric (HE) Tunnelbroker 的自动化 IPv6 隧道配置脚本。自动模拟登录账号、提取隧道列表、同步本机公网 Client IPv4 并自动建立本地 `sit` 隧道与持久化配置。

---

## 功能特性

* **免手动填参**：自动登录 HE 获取所有隧道详细信息（Tunnel ID、Server IPv4/IPv6、Client IPv6 等）。
* **自动识别公网 IP**：多源测速并自动抓取本机当前公网 IPv4。
* **一键同步端点**：调用 HE 接口即刻更新对端绑定的 Client IPv4。
* **即配即用**：自动通过 `iproute2` 构建 `he-ipv6` (SIT 协议) 虚拟接口，并写入开机自启配置。
* **连通性校验**：内置 IPv6 握手连通性与常见阻断排查提示。

---

## 快速运行

由于脚本包含终端交互读取账号及选项，请使用进程替换方式运行：

### 境外 VPS
```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/zhuanwan0905/tunnelbroker-auto-bind/main/tb_ipv6_autobind.sh](https://raw.githubusercontent.com/zhuanwan0905/tunnelbroker-auto-bind/main/tb_ipv6_autobind.sh))
