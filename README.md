# SingBox for Magisk

**使用方式**

sing-box 配置文件 config.json 放在 `/data/adb/singbox/` 目录, 重启手机模块生效

**黑白名单**

- `/data/adb/singbox/include.list` 文件中的应用包名走代理

- `/data/adb/singbox/exclude.list` 文件中的应用包名不走代理

`exclude.list` 优先级高于 `include.list`:

如果一个应用的包名同时出现在 `exclude.list` 和 `include.list` 中，这个应用不走代理。

