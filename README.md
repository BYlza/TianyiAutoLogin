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
| 自动登录 | 拉起后若 8 秒内仍未联网，按客户区相对坐标点一次「登录」按钮，最多 5 次；点击前会确认前台窗口确实是客户端 |
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

所以 `-Install` 会做三件事：

1. 把脚本本体复制到 `%ProgramData%\TianyiAutoLogin\`；
2. 用 `icacls` 把该目录的 ACL 收紧为**仅 SYSTEM + Administrators**，断开继承、移除普通用户写权限；
3. 把客户端 exe 的 SHA256 记进 `client-sha256.txt`，此后每次启动客户端前都校验。

哈希基准放在受 ACL 保护的目录里才有意义——否则攻击者连基准一起改掉即可。

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

### 配置客户端路径

脚本默认按 `C:\Program Files (x86)\Chinatelecom\GDPortal` 找客户端。装到别处时，**二选一**：

1. 改脚本顶部的 `$ClientDir`；或
2. 在脚本同目录建 `client-path.txt`（部署后即 `%ProgramData%\TianyiAutoLogin\client-path.txt`），
   里面写一行真实路径：

   ```
   E:\Tools\Chinatelecom_GDPortal
   ```

`-Install` 会把这个文件一起带到部署目录。它和 `client-sha256.txt` 都已在 `.gitignore` 中。

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

## ⚠️ 安全提示

1. **会触发安全软件告警。** `-ExecutionPolicy Bypass` + 隐藏窗口 + 计划任务开机自启，是杀毒软件的典型启发式特征。
   Defender 或校园终端防护可能提示甚至隔离，需要自行加白。
2. **务必确认部署目录的 ACL 生效。** `-Install` 若提示 `ACL 收紧失败`，说明 `icacls` 没跑成功，
   此时脚本仍会被提权运行但普通用户可能可写 —— 请手动检查目录权限。
3. **客户端升级后需要重新信任。** 官方更新 `ESurfingClient.exe` 后哈希会变，守护会拒绝启动并在日志里写明原因。
   确认升级无误后执行 `-TrustClient`。
4. **自动点击按固定相对坐标工作。** 登录按钮位置是按特定版本客户端量出来的（客户区 533×914 时约 `(0.500, 0.595)`）。
   改版或换分辨率后可能点偏，先 `-DryRun` 确认，或重新标定 `$LoginPointX` / `$LoginPointY`。
5. **点击会抢占前台。** 脚本在点击前会校验前台窗口确实是客户端窗口，不匹配就放弃本次点击；检测到锁屏也会跳过。

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
