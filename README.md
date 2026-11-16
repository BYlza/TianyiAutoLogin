# 天翼校园自动登录守护

给中国电信「天翼校园」客户端（`ESurfingClient.exe`）做**掉线自动重连**的 Windows 守护脚本。

客户端本身没有开机自启，也不会在网络掉线后自己重拨；手动点一次「登录」才恢复。这个脚本负责在后台盯着，
发现断网或进程消失就把它拉起来，必要时自动点一次登录按钮。

> 脚本**不存账号密码、不模拟登录协议、不绕过任何认证**。它就是启动官方客户端并点一下界面上的「登录」，
> 用的仍然是你客户端里已经保存好的凭据。

## 工作原理

| 环节 | 做法 |
|---|---|
| 在线判据 | ping `223.5.5.5`，被屏蔽时退化为 TCP `223.5.5.5:53`。**不读**客户端 `ConnectSetting.ini` 的 `connState`（实测是残留值，不可信） |
| 巡检间隔 | 15 秒一次，连续 4 次探测失败（约 60 秒）判定掉线 |
| 进程消失 | 立即 `Start-Process` 拉起（两次拉起最小间隔 60 秒） |
| 掉线 | 重启客户端，但有两道闸：客户端已稳定运行 ≥120 秒、距上次重启 ≥300 秒（连续失败 3 次后放宽到 900 秒） |
| 客户端校验 | 启动前核对 `ESurfingClient.exe` 的 SHA256，不匹配就拒绝启动（见「安全设计」） |
| 自动登录 | 拉起后若 8 秒内仍未联网，按客户区相对坐标点一次「登录」按钮，最多 5 次；点击前会确认该坐标上最顶层的窗口确实是客户端 |
| 单实例 | 互斥量 `TianyiAutoLoginWatchdog`，重复启动直接退出 |
| 状态保持 | 登录成功后**不关窗口、不结束进程**，让它挂在托盘由客户端自己保活 |
| 日志 | 只在状态切换时写一行；超过 1MB 自动滚动为 `autologin.log.1` |

## 环境要求

- Windows 10 / 11，Windows PowerShell 5.1（系统自带）
- 已安装天翼校园客户端，且客户端里已保存账号并成功登录过一次
- 安装步骤需要管理员权限（客户端本身以管理员运行）

## 安全设计：为什么脚本要部署到 `%ProgramData%`

计划任务是「登录时 + 最高权限」触发，全程无 UAC 弹窗。如果脚本留在用户可写目录
（比如 `D:\我的项目\`），任何以你身份运行的程序都可以改写它，下次登录时就能静默拿到管理员权限。

所以 `-Install` 会做这些事：

1. 把脚本本体复制到 `%ProgramData%\TianyiAutoLogin\`；
2. **先把目录所有者改成 Administrators**（`icacls /setowner`），再用 `icacls` 断开继承、只留
   SYSTEM + Administrators 可写；
3. 回读目录 ACL 做校验：所有者必须是 Administrators，且没有任何普通用户组的写权限；
4. 把客户端 exe 的 SHA256 记进 `client-sha256.txt`，此后每次启动客户端前都校验；
5. 复制脚本后立刻比对源与副本的哈希，防止半写/截断的副本被计划任务执行。

哈希基准放在受 ACL 保护的目录里才有意义——否则攻击者连基准一起改掉即可。

### 为什么第 2 步要先抢所有权

`C:\ProgramData` 默认允许普通用户建子目录（`Users:(CI)(AD)`），而且新建目录的所有者是创建者、
带 `CREATOR OWNER` 完全控制。于是存在这样一条路：

```
普通用户抢在 -Install 之前建出 C:\ProgramData\TianyiAutoLogin（成为所有者）
        ↓
管理员 -Install 只改 DACL，所有者还是攻击者
        ↓
Windows 里「所有者」隐式拥有 WRITE_DAC，他把自己加回完全控制
        ↓
改写 TianyiAutoLogin.ps1 → 下次登录以管理员执行
```

只收紧 DACL 是拦不住的，所以必须先换所有者。同理，部署路径**不读 `%ProgramData%` 环境变量**
（提权进程会继承调用者的环境块，普通用户可以用 `setx` 把它指到自己的目录），而是从注册表取
`CommonApplicationData` 的真实路径。

**权限校验不通过时 `-Install` 会直接中止，不会注册计划任务**——宁可装不上，也不带着「没锁住」的
状态去跑一个最高权限任务。

## 使用

```powershell
# 部署 + 注册开机自启（会弹一次 UAC）
powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Install

# 查看当前状态（只读，不动任何东西）
powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -DryRun

# 客户端升级后，重新记录信任的哈希
powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -TrustClient

# 卸载：删计划任务 + 停守护 + 删部署目录
powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Uninstall

# 前台运行（排错用，会占用当前窗口）
powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1
```

### 客户端路径（多数情况不用配）

脚本按这个顺序找客户端：

1. 脚本同目录的 `client-path.txt`（存在就用它，优先级最高）
2. **注册表自动探测**：卸载项里的 `DisplayIcon` / `InstallLocation`、`Run` 项里的 `AutoStart.exe`
3. 常见默认位置 `C:\Program Files (x86)\Chinatelecom\GDPortal`

所以客户端装在 D 盘、E 盘还是自定义目录，一般都能自己认出来，**不需要手动配置**。

只有两种情况需要干预：

- 客户端装在非常规位置、注册表里又没有任何记录 —— 这时 `-Install` 会**明确报错并停下**，
  不会出现"装完了但永远拉不起来"
- 你想让它用另一份客户端

这时在脚本同目录新建 `client-path.txt`，写一行真实路径：

```
D:\Program Files\Chinatelecom\GDPortal
```

> 记事本另存时把"保存类型"选成**所有文件**，否则会存成 `client-path.txt.txt`，脚本读不到。

`-DryRun` 里的「路径来源」会告诉你是 `client-path.txt`、`自动探测` 还是 `自动探测（回退）`
（后者表示配置的路径已失效、脚本自动改正了，建议更新那个文件）。

`-Install` 会把最终解析到的路径写进部署目录，部署后即 `%ProgramData%\TianyiAutoLogin\client-path.txt`。
它和 `client-sha256.txt` 都已在 `.gitignore` 中。

### 部署后有哪些文件

均在 `%ProgramData%\TianyiAutoLogin\`：

| 文件 | 说明 |
|---|---|
| `TianyiAutoLogin.ps1` | 脚本副本，计划任务实际执行的就是它 |
| `天翼校园自动登录.vbs` | 隐藏启动器（GBK 编码，`-Install` 生成） |
| `client-path.txt` | 客户端安装路径 |
| `client-sha256.txt` | 客户端 exe 的 SHA256 基准 |
| `autologin.log` | 运行日志 |
| `watchdog.pid` | 守护进程 PID，卸载时用来精确停进程 |

计划任务名 `TianyiAutoLogin`，触发方式「登录时」+「以最高权限运行」。

> `-Install` 会顺手删掉源码目录里遗留的旧 `天翼校园自动登录.vbs`，避免出现「旧路径 + 新路径」两个入口。

### 源码副本与部署副本会分叉

`-Install` 是**单向复制**：部署之后你再改仓库里的 `TianyiAutoLogin.ps1`，跑着的仍然是
`%ProgramData%` 里那份旧代码，不会自动同步。这不是小事——「以为部署了、其实跑的是旧版」
曾经真的导致过自动登录静默失效。

`-DryRun` 会多打一行 `部署副本` 来暴露这件事：

| 显示 | 含义 |
|---|---|
| `与源码一致` | 跑的就是当前源码 |
| `不一致：改了源码但没重新 -Install` | 需要重新执行 `-Install` |
| `读不到（用管理员运行 -DryRun 才能比对）` | 非管理员无法读取受保护目录，属正常 |

同理，`-DryRun` 里的客户端路径和哈希基准都取自**部署副本**（而不是你当前所在的源码目录），
所以从仓库里跑也不会误报「哈希未配置」。

### 客户端自带的开机自启

客户端装完通常会在注册表里留一项自启，例如：

```
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run
  Esurfing Client in Campus = D:\SomeDir\Chinatelecom_GDPortal\AutoStart.exe
```

它和本脚本的计划任务会在登录时同时拉起同一个客户端。守护只在「进程不存在」时才动手，
所以正常情况下不会双开；`-Install` 和 `-DryRun` 会把这个自启项列出来，真遇到双开/抢窗口，
在客户端设置里关掉自启即可。

## ⚠️ 安全提示

1. **会触发安全软件告警。** `-ExecutionPolicy Bypass` + 隐藏窗口 + 计划任务开机自启，是杀毒软件的典型启发式特征。
   Defender 或校园终端防护可能提示甚至隔离，需要自行加白。
2. **`-Install` 校验失败会中止。** 如果它报「部署目录权限没有锁住」并退出，说明所有权或 DACL 没设置成功，
   计划任务**不会**被注册。按提示手动修好目录权限后重试即可，不要绕过。
3. **客户端升级后需要重新信任。** 官方更新 `ESurfingClient.exe` 后哈希会变，守护会拒绝启动并在日志里写明原因。
   确认升级无误后执行 `-TrustClient`。
4. **自动点击按固定相对坐标工作。** 登录按钮位置是按特定版本客户端量出来的（客户区 533×914 时约 `(0.500, 0.595)`）。
   改版或换分辨率后可能点偏，先 `-DryRun` 确认，或重新标定 `$LoginPointX` / `$LoginPointY`。
5. **点击前校验的是「坐标命中」，不是「窗口在前台」。** 脚本用 `WindowFromPoint` 确认该坐标上最顶层的窗口
   就是客户端（后台进程抢前台常被系统拒绝，所以不能拿前台状态当判据）；检测到锁屏（`LogonUI` 在跑）会直接跳过。
   注意：如果客户端在同一窗口里弹公告/广告/协议弹层，校验仍会通过，点击可能落在弹层上。
6. **贴日志求助前先脱敏。** `autologin.log` 记的是「几点在线、几点掉线、几点点了登录」，属于行为指纹。
   贴到公开 issue 前建议只保留时间附近的几行，或先把时间改成相对值。

## 已知限制

- 只适配 Windows，依赖客户端窗口类名 `wkeWebWindow`（内嵌 wke 网页，没有控件树，`UIA` 定位不到按钮，只能按坐标点）
- 客户端大版本更新后坐标、窗口尺寸可能失效
- 连续 5 次点击登录仍不成功就放弃，等人工处理
- 哈希校验只在 `client-sha256.txt` 存在时生效；从源码目录直接跑属于开发模式，未配置时不校验并会在日志提示

## 免责声明

本项目仅供**个人在自己账号上**做掉线保活使用。

- 不得用于共享账号、代他人登录、绕过计费或规避任何认证机制
- 是否允许在校园网使用此类自动化工具，取决于你所在学校/运营商的使用协议，请自行确认
- 脚本以管理员权限修改计划任务与系统进程，使用风险自负

## License

[MIT](LICENSE)
