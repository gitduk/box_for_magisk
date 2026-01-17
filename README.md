# SingBox for Magisk

A Magisk module that provides transparent proxy functionality for Android devices using sing-box.

## 快速开始

### 1. 安装模块

在 Magisk Manager 中安装本模块，重启设备。

### 2. 配置文件

将 sing-box 配置文件放置到：
```
/data/adb/singbox/config.json
```

### 3. 启动服务

模块会在开机时自动启动，也可以手动管理：

```bash
# 启动服务
/data/adb/singbox/scripts/service.sh start

# 停止服务
/data/adb/singbox/scripts/service.sh stop

# 重启服务
/data/adb/singbox/scripts/service.sh restart

# 查看状态
/data/adb/singbox/scripts/service.sh status

# 健康检查
/data/adb/singbox/scripts/service.sh health

# 强制停止
/data/adb/singbox/scripts/service.sh force-stop
```

## 配置说明

### 网络模式

编辑 `/data/adb/singbox/settings.ini`:

```ini
# 启用/禁用 IPv6
ipv6="false"

# 网络模式: redirect / tproxy / tun
network_mode="tproxy"

# 热点接口（支持无线热点代理）
ap_list=("ap+" "wlan+" "rndis+" "swlan+" "ncm+" "rmnet+")
```

**网络模式说明:**
- **tproxy** (推荐): TCP + UDP 透明代理，性能最佳
- **redirect**: TCP + UDP(直连) 重定向代理，兼容性最好
- **tun**: TCP + UDP 虚拟网卡模式，自动路由

**重要:** 确保 `settings.ini` 中的 `network_mode` 与 `config.json` 中的 inbound 类型匹配：
- 如果 config.json 中有 `"type": "tun"` 的 inbound，使用 `network_mode="tun"`
- 如果 config.json 中有 `"type": "tproxy"` 的 inbound，使用 `network_mode="tproxy"`
- 如果 config.json 中有 `"type": "redirect"` 的 inbound，使用 `network_mode="redirect"`

### 应用过滤（黑白名单）

#### 白名单模式（仅代理指定应用）

编辑 `/data/adb/singbox/include.list`，添加需要代理的应用包名：
```
com.android.chrome
com.google.android.youtube
```

#### 黑名单模式（排除指定应用）

编辑 `/data/adb/singbox/exclude.list`，添加不需要代理的应用包名：
```
com.tencent.mm          # 微信
com.tencent.mobileqq    # QQ
com.eg.android.AlipayGphone  # 支付宝
```

**优先级:** `exclude.list` > `include.list`

如果一个应用的包名同时出现在 `exclude.list` 和 `include.list` 中，这个应用不走代理。

## 高级功能

### 1. 日志管理

日志文件位置:
```
/data/adb/singbox/logs/run.log    # 运行日志
/data/adb/singbox/logs/box.log    # sing-box 日志
```

日志会自动轮转（超过 10MB 时），保留最近 3 个备份。

实时查看日志:
```bash
tail -f /data/adb/singbox/logs/box.log
```

### 2. 健康检查

```bash
/data/adb/singbox/scripts/service.sh health
```

检查内容:
- 进程运行状态
- 配置文件完整性
- 日志错误统计
- 网络连通性

### 3. 手动 iptables 管理

```bash
# 应用 tproxy 规则
/data/adb/singbox/scripts/iptables.sh tproxy

# 应用 redirect 规则
/data/adb/singbox/scripts/iptables.sh redirect

# 应用 tun 规则
/data/adb/singbox/scripts/iptables.sh tun

# 清理所有规则
/data/adb/singbox/scripts/iptables.sh clear
```

### 4. 验证代码结构

```bash
/data/adb/singbox/scripts/validate.sh
```

检查所有脚本文件和函数是否完整。

## 常见问题

### Q1: 服务无法启动

**检查步骤:**

1. 验证配置文件:
```bash
/data/adb/singbox/bin/sing-box check -D /data/adb/singbox/ -C /data/adb/singbox
```

2. 查看日志:
```bash
cat /data/adb/singbox/logs/box.log
```

3. 检查 network_mode 是否与 config.json 的 inbound 类型匹配
4. 检查 TUN 设备（如果使用 tun 模式）:
```bash
ls -l /dev/net/tun
```

### Q2: 某些应用无法联网

1. 检查应用是否在 exclude.list 中
2. 验证 iptables 规则:
```bash
iptables -t mangle -L -n -v
```

### Q3: IPv6 不工作

1. 确认 settings.ini 中 `ipv6="true"`
2. 检查 IPv6 路由规则:
```bash
ip -6 rule list
ip -6 route show table 2024
```

### Q4: 代理速度慢

1. 检查内存使用:
```bash
/data/adb/singbox/scripts/service.sh status
```

2. 检查日志中的错误:
```bash
grep ERROR /data/adb/singbox/logs/box.log
```

3. 尝试切换网络模式（tproxy 性能最佳）

### Q5: 模块更新后配置丢失

模块会自动备份 `config.json`，但建议手动备份:
```bash
cp /data/adb/singbox/config.json /sdcard/backup/
```

## 故障排查

### 收集诊断信息

```bash
# 1. 服务状态
/data/adb/singbox/scripts/service.sh status

# 2. 健康检查
/data/adb/singbox/scripts/service.sh health

# 3. 最近日志
tail -50 /data/adb/singbox/logs/box.log

# 4. iptables 规则
iptables -t mangle -L -n -v | head -50

# 5. 路由规则
ip rule list
ip route show table 2024

# 6. 进程信息
ps | grep sing-box
```

### 完全重置

如果遇到无法解决的问题:

```bash
# 1. 停止服务
/data/adb/singbox/scripts/service.sh force-stop

# 2. 清理规则
/data/adb/singbox/scripts/iptables.sh clear

# 3. 备份配置
cp /data/adb/singbox/config.json /sdcard/backup/

# 4. 在 Magisk Manager 中重新安装模块
```

## 性能优化建议

### 1. 网络模式选择
- 优先使用 **tproxy** 模式（性能最佳）
- 如果遇到兼容性问题，使用 redirect 模式
- tun 模式适合需要自动路由的场景

### 2. 应用过滤
- 使用黑名单模式（exclude.list）性能更好
- 排除不需要代理的国内应用
- 减少规则数量

### 3. DNS 优化
- 在 config.json 中配置 FakeIP 模式
- 使用快速的 DNS 服务器（如阿里 DNS: 223.5.5.5）

### 4. 资源监控
- 定期检查内存使用
- 清理旧日志文件（自动轮转）
- 监控磁盘空间

## 进阶配置

### 自定义常量

编辑 `/data/adb/singbox/scripts/constants.sh`:

```bash
# 日志轮转配置
LOG_MAX_SIZE=10485760  # 10MB
LOG_MAX_BACKUPS=3

# 进程检查配置
MAX_RETRIES=10
RETRY_INTERVAL=0.5

# 文件描述符限制
FILE_DESCRIPTOR_LIMIT=1000000
```

## 安全建议

1. **定期备份配置文件**
2. **不要在 config.json 中存储明文密码**（使用环境变量或密钥文件）
3. **定期更新 sing-box 版本**
4. **监控日志中的异常活动**
5. **使用强密码保护订阅链接**

## 贡献与反馈

提交问题时请附带:
- 设备信息（型号、Android 版本）
- Magisk 版本
- 日志文件
- 重现步骤

## 更新日志

### v1.3.0
- ✨ 重构代码结构，模块化设计
- ✨ 新增健康检查功能
- ✨ 新增日志轮转功能
- ✨ 完善 IPv6 支持
- ✨ 改进错误处理和资源清理
- ✨ 新增配置验证功能
- ✨ 自动修复文件权限
- ✨ 友好的配置错误提示
- 🐛 修复策略路由清理不完整的问题
- 🐛 修复 IPv6 规则缺失的问题
- 🐛 修复 Android shell 兼容性问题
- ⚡ 优化连接跟踪性能
- 📝 完善文档和注释

## 许可证

[查看 LICENSE 文件]

## 致谢

- [sing-box](https://sing-box.sagernet.org/) 项目
- [Magisk](https://github.com/topjohnwu/Magisk) 项目
- 所有贡献者
