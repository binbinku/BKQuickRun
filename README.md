# BKQuickRun

BKQuickRun 是一款 macOS 菜单栏脚本启动器。可以为常用的 `.sh` 脚本设置别名、分类和参数变体，在菜单栏里启动、停止脚本并查看实时输出。

## 构建和使用

用 Xcode 26 或更新版本打开 `BKQuickRun.xcodeproj`，选择 `BKQuickRun` scheme 后运行。应用支持 macOS 14 及以上版本。

点击菜单栏里的 BKQuickRun 图标，在「管理」中添加脚本。脚本可在后台运行，也可在无参数启动时打开 macOS 自带的 Terminal。后台运行支持按脚本开启日志面板输入和多路日志。

配置保存在 `~/Library/Application Support/BKQuickRun/library.json`。编辑配置后，在面板中点击「同步配置」即可重新加载。

## 许可证

[MIT](LICENSE)
