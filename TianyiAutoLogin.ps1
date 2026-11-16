# ============================================================
# 天翼校园自动登录守护脚本
# 功能：开机自启 -> 拉起客户端 -> 静默驻留 -> 掉了（进程没了 / 断网）就自动拉起
#
# 行为说明（2026-11-16 实测后定稿）：
#   * 登录成功后**不关闭窗口、不结束进程**，就让它挂在托盘里。窗口归你管。
#   * 保活由 ESurfingClient.exe 自己完成，杀掉它必断网；所以本脚本只在
#     "已经断网" 时才重启客户端，绝不会在正常在线时去动它。
#   * Config\ConnectSetting.ini 的 connState 是残留值（进程已消失时仍可能是 1），
#     不能当在线判据；一律以真实连通性（ping / TCP）为准。
#   * 客户端通常自带开机自启（HKLM\SOFTWARE\WOW6432Node\...\Run 里的
#     "Esurfing Client in Campus"）。登录时会和本脚本的计划任务同时拉起同一客户端；
#     守护只在"进程不存在"时才动手，正常情况下不会双开。-Install / -DryRun 会把
#     这类自启项列出来，真撞上了就在客户端设置里关掉。
#   * 客户端被拉起后如果停在登录页不会自己拨号，脚本会自动点一次「登录」按钮。
#     该界面是内嵌网页（窗口类 wkeWebWindow），没有控件树，只能按客户区相对坐标点击。
#   * 脚本常驻运行（不退出），平时不写日志、不弹窗；只在状态变化时记一行。
#
# 安全设计：
#   * -Install 会把脚本本体部署到 %ProgramData%\TianyiAutoLogin，并把该目录 ACL
#     收紧为「仅 SYSTEM + Administrators」，去掉普通用户的写权限。
#     计划任务以最高权限运行；若脚本留在用户可写目录，任何用户态程序都能改写它，
#     从而在下次登录时静默拿到管理员权限。
#   * 部署目录的路径**不读 %ProgramData% 环境变量**：提权进程会继承调用者的环境块，
#     普通用户可以用 setx 把它指向自己完全控制的目录。这里改用注册表里的
#     CommonApplicationData 真实路径。
#   * 收紧 ACL 之前先 icacls /setowner 把所有者换成 Administrators。Windows 里
#     「属主」隐式拥有 READ_CONTROL + WRITE_DAC，只改 DACL 不换属主的话，抢在安装前
#     建出同名目录的人（C:\ProgramData 默认允许 Users 建子目录）可以把自己加回来。
#   * 权限校验不通过就中止安装，绝不会带着「没锁住」的状态去注册最高权限任务。
#   * -Install 同时把客户端 exe 的 SHA256 记进 client-sha256.txt。此后每次启动客户端
#     前都会校验，不匹配就拒绝启动（防止客户端被替换后以管理员权限执行任意程序）。
#     官方升级客户端后，重新执行一次 -TrustClient 记录新哈希。
#   * -Install 复制脚本后会立刻比对源与部署副本的哈希，防止半写/截断的副本被计划任务执行。
#   * 自动点击前会校验点击坐标上最顶层的窗口确实是客户端（WindowFromPoint），
#     不匹配就放弃本次点击；锁屏（LogonUI 在跑）直接跳过。
#
# 用法：
#   部署 + 开机自启： powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Install
#   卸载（含停守护）： powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Uninstall
#   状态自检一次：     powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -DryRun
#   客户端升级后信任： powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -TrustClient
#   前台运行守护：     powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1
# ============================================================
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$TrustClient
)

$ErrorActionPreference = 'Continue'

# ---------- 路径 ----------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

# 不要用 $env:ProgramData。提权时子进程继承调用者的环境块，普通用户可以
# `setx ProgramData D:\某处` 把它指到自己完全控制的位置 —— 那样"受保护目录"
# 的父目录可被整体替换，ACL 再严也没意义。改读注册表里的真实路径。
$ProgramDataRoot = $null
try { $ProgramDataRoot = [Environment]::GetFolderPath('CommonApplicationData') } catch { }
if (-not $ProgramDataRoot) { $ProgramDataRoot = Join-Path $env:SystemDrive 'ProgramData' }

$DeployDir  = Join-Path $ProgramDataRoot 'TianyiAutoLogin'
$TaskName   = 'TianyiAutoLogin'
$MutexName  = 'Global\TianyiAutoLoginWatchdog'
$AdminsSid  = 'S-1-5-32-544'   # BUILTIN\Administrators

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 判断"存在/不存在/存在但看不见"。不能用 Test-Path：它会为通配符解析去列举父目录，
# 父目录 ACL 一收紧就抛 AccessDenied —— 但里面的文件本身可能是可读的（部署目录就
# 单独给日志开了 Users:(R)）。这里改用 .NET 的属性检查，只在需要区分"没这个文件"
# 和"看不见这个目录"时才去列举父目录。
# 返回：存在 = $true / 不存在 = $false / 存在但当前权限看不见 = $null
function Test-PathAccessible([string]$Path) {
    try {
        if ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)) { return $true }
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        $leaf   = [System.IO.Path]::GetFileName($Path)
        if (-not $parent -or -not [System.IO.Directory]::Exists($parent)) { return $false }
        $hits = [System.IO.Directory]::GetFileSystemEntries($parent, $leaf)
        if ($hits -and $hits.Count -gt 0) { return $true }
        return $false
    } catch { return $null }
}

# -Install 通常是从普通窗口触发提权的：它跑在**另一个**控制台窗口里，出错一闪就关，
# 用户根本看不到原因。所以安装过程同时写一份日志到 ProgramData 根目录（那里 Users
# 有读权限），失败后可以直接打开看。
$script:InstallLog = Join-Path $ProgramDataRoot 'TianyiAutoLogin-install.log'
$script:AclDiag = ''
function Write-InstallLog([string]$msg) {
    Write-Host $msg
    try {
        Add-Content -LiteralPath $script:InstallLog -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# 当前跑的是部署副本还是仓库里的开发副本
$IsDeployed = $false
try {
    $a = [IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')
    $b = [IO.Path]::GetFullPath($DeployDir).TrimEnd('\')
    $IsDeployed = [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
} catch { }

# 运行时文件都跟着脚本走：部署后即落在 %ProgramData%\TianyiAutoLogin
$ClientPathFile = Join-Path $ScriptDir 'client-path.txt'
$ClientHashFile = Join-Path $ScriptDir 'client-sha256.txt'
$VbsPath        = Join-Path $ScriptDir '天翼校园自动登录.vbs'
$LogFile        = Join-Path $ScriptDir 'autologin.log'
$PidFile        = Join-Path $ScriptDir 'watchdog.pid'

# ---------- 配置 ----------
# 天翼校园客户端安装目录。默认值只是常见安装位置，请按自己机器的实际路径修改；
# 也可以不改脚本，直接在本脚本同目录新建 client-path.txt 写一行真实路径
#（该文件已被 .gitignore 忽略，不会误提交）。
$ClientDir = 'C:\Program Files (x86)\Chinatelecom\GDPortal'
if ((Test-PathAccessible $ClientPathFile) -eq $true) {
    $rawCfg = Get-Content -LiteralPath $ClientPathFile -Raw -ErrorAction SilentlyContinue
    if ($rawCfg) {
        $rawCfg = $rawCfg.Trim().TrimStart([char]0xFEFF).Trim()
        if ($rawCfg) { $ClientDir = $rawCfg }
    }
}
$ClientExe      = Join-Path $ClientDir 'ESurfingClient.exe'
$PingTarget     = '223.5.5.5'    # 阿里 DNS
$TcpHost        = '223.5.5.5'    # ping 被屏蔽时改用 TCP 探测
$TcpPort        = 53
$PollSec        = 15             # 巡检间隔
$OfflineSamples = 4              # 连续几次探测失败算掉线（4 × 15s ≈ 1 分钟）
$StartGapSec    = 60             # 两次拉起客户端的最小间隔
$RestartGapSec  = 300            # 两次重启客户端的最小间隔
$ClientGraceSec = 120            # 客户端刚起的 2 分钟内不重启，留出登录时间

function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

# 日志超过 1MB 就滚动一次，避免无限增长
function Rotate-Log {
    if (Test-Path $LogFile) {
        if ((Get-Item $LogFile).Length -gt 1MB) {
            Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
        }
    }
}

# 只给 Users 读权限：不提升权限也能看日志，但拿不到写权限，篡改不了。
# 部署目录本身仍然只有 SYSTEM + Administrators 可写。
function Grant-LogRead {
    if (-not (Test-Path $LogFile)) { return }
    try { & icacls.exe $LogFile /grant '*S-1-5-32-545:R' *> $null } catch { }
}

# ---------- 客户端完整性校验 ----------
# 把哈希文件放在受 ACL 保护的部署目录里才有意义：普通用户改不了基准值。
$script:lastTrustLog = [datetime]::MinValue

function Get-TrustState {
    # 返回：none（未配置） / ok / mismatch / missing / denied（无权读基准）
    # HashFile / Exe 可显式指定：-DryRun 从源码目录跑时要看**部署副本**的基准，
    # 否则会误报"未配置"（基准只在 %ProgramData% 里）。
    param([string]$HashFile, [string]$Exe)
    if (-not $HashFile) { $HashFile = $ClientHashFile }
    if (-not $Exe) { $Exe = $ClientExe }

    $hasHash = Test-PathAccessible $HashFile
    if ($null -eq $hasHash) { return 'denied' }
    if (-not $hasHash) { return 'none' }

    $want = $null
    try { $want = Get-Content -LiteralPath $HashFile -Raw -ErrorAction Stop } catch { return 'denied' }
    if ($want) { $want = $want.Trim().TrimStart([char]0xFEFF).Trim() }
    if (-not $want) { return 'none' }

    $hasExe = Test-PathAccessible $Exe
    if ($null -eq $hasExe) { return 'denied' }
    if (-not $hasExe) { return 'missing' }

    try { $got = (Get-FileHash -Path $Exe -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return 'missing' }
    if ($got -eq $want) { return 'ok' }
    return 'mismatch'
}

function Test-ClientTrusted {
    switch (Get-TrustState) {
        'ok'   { return $true }
        'none' {
            if (((Get-Date) - $script:lastTrustLog).TotalMinutes -ge 5) {
                Write-Log '未配置客户端哈希校验（执行 -Install 或 -TrustClient 生成 client-sha256.txt）'
                $script:lastTrustLog = Get-Date
            }
            return $true
        }
        default {
            if (((Get-Date) - $script:lastTrustLog).TotalMinutes -ge 5) {
                Write-Log ("客户端校验失败（{0}）：{1}。若确为官方升级，执行 -TrustClient 重新信任；否则不要启动。" -f (Get-TrustState), $ClientExe)
                $script:lastTrustLog = Get-Date
            }
            return $false
        }
    }
}

# 启动客户端前的统一闸门：路径存在 + 哈希可信
function Test-ClientReady {
    if (-not (Test-Path $ClientExe)) {
        if (((Get-Date) - $script:lastTrustLog).TotalMinutes -ge 5) {
            Write-Log ("客户端不存在：{0}（检查 client-path.txt）" -f $ClientExe)
            $script:lastTrustLog = Get-Date
        }
        return $false
    }
    return (Test-ClientTrusted)
}

# ---------- 连通性探测 ----------
function Test-TcpPort([string]$target, [int]$port, [int]$timeoutMs = 2000) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($target, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $c.Close()
    }
}

# 在线 = ping 通，或 ping 被屏蔽时 TCP 通。不读 ini，不看 connState
function Test-Online {
    try {
        if (Test-Connection -ComputerName $PingTarget -Count 1 -Quiet -ErrorAction Stop) { return $true }
    } catch { }
    return (Test-TcpPort $TcpHost $TcpPort)
}

function Get-Client {
    return @(Get-Process -Name ESurfingClient -ErrorAction SilentlyContinue)
}

function Get-ClientUptimeSec {
    $p = Get-Client
    if ($p.Count -eq 0) { return -1 }
    try { return [int]((Get-Date) - $p[0].StartTime).TotalSeconds } catch { return -1 }
}

# ---------- 自动点击「登录」按钮 ----------
# 客户端界面是内嵌网页（窗口类名 wkeWebWindow），UIA 拿不到任何控件，
# 只能按客户区相对坐标点。实测：客户区 533×914 时登录按钮中心在 (0.500, 0.595)。
# 注意：已连接页面的同位置是空白区，点错也没有副作用（不会点到下面的「断开」）。
$LoginPointX = 0.500
$LoginPointY = 0.595

function Initialize-Win32 {
    if ('Ty.TyWin32' -as [type]) { return $true }
    try {
        Add-Type -Name 'TyWin32' -Namespace 'Ty' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint gaFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr hWnd, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr hWnd, ref POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, System.UIntPtr dwExtraInfo);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
        return $true
    } catch {
        Write-Log "加载 Win32 接口失败：$($_.Exception.Message)"
        return $false
    }
}

# 锁屏时前台不是普通桌面，点坐标会落空甚至点错，直接跳过
function Test-SessionLocked {
    return [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)
}

function Invoke-LoginClick {
    if (-not (Initialize-Win32)) { return $false }
    if (Test-SessionLocked) {
        Write-Log '会话已锁定，跳过自动点击'
        return $false
    }
    $p = Get-Client | Select-Object -First 1
    if (-not $p) { return $false }
    $h = $p.MainWindowHandle
    if ($h -eq 0) { return $false }

    [void][Ty.TyWin32]::ShowWindow($h, 9)              # SW_RESTORE，最小化也能点
    # 尽力抢前台；被系统前台锁定拒绝也无所谓，后面按坐标判定，不依赖它
    [void][Ty.TyWin32]::SetForegroundWindow($h)
    # 只抬 z 序、不激活：SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    [void][Ty.TyWin32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x13)
    Start-Sleep -Milliseconds 400

    $rect = New-Object 'Ty.TyWin32+RECT'
    if (-not [Ty.TyWin32]::GetClientRect($h, [ref]$rect)) { return $false }
    if ($rect.Right -le 0 -or $rect.Bottom -le 0) { return $false }

    $pt = New-Object 'Ty.TyWin32+POINT'
    $pt.X = [int]($rect.Right * $LoginPointX)
    $pt.Y = [int]($rect.Bottom * $LoginPointY)
    [void][Ty.TyWin32]::ClientToScreen($h, [ref]$pt)

    # 关键校验：要点的那个屏幕坐标上，最顶层窗口必须是客户端窗口（或它的子窗口）。
    # 不能拿「客户端是不是前台」当判据 —— 后台进程抢前台常被系统的前台锁定拒绝，
    # 那样会永远判定失败、一次都点不出去，自动登录就彻底失效了。
    $hit  = [Ty.TyWin32]::WindowFromPoint($pt)
    $root = [Ty.TyWin32]::GetAncestor($hit, 2)          # GA_ROOT
    if ($root -ne $h) {
        Write-Log ("点击坐标处不是客户端窗口（hit={0} root={1}），跳过本次点击" -f $hit, $root)
        return $false
    }

    $old = New-Object 'Ty.TyWin32+POINT'
    $hadOld = [Ty.TyWin32]::GetCursorPos([ref]$old)

    [void][Ty.TyWin32]::SetCursorPos($pt.X, $pt.Y)
    Start-Sleep -Milliseconds 200
    [Ty.TyWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # 左键按下
    Start-Sleep -Milliseconds 90
    [Ty.TyWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # 左键抬起
    Start-Sleep -Milliseconds 200
    if ($hadOld) { [void][Ty.TyWin32]::SetCursorPos($old.X, $old.Y) }

    Write-Log ("已点击登录按钮 ({0},{1})，客户区 {2}x{3}" -f $pt.X, $pt.Y, $rect.Right, $rect.Bottom)
    return $true
}

# 拉起客户端并在需要时点登录：已联网就不点，优先让客户端自己拨号
function Start-ClientAndLogin {
    if (-not (Test-ClientReady)) { return }
    try {
        Start-Process -FilePath $ClientExe -WorkingDirectory $ClientDir -ErrorAction Stop
    } catch {
        Write-Log "启动客户端失败：$($_.Exception.Message)"
        return
    }
    Start-Sleep -Seconds 8
    for ($i = 1; $i -le 5; $i++) {
        if ((Get-Client).Count -eq 0) { Write-Log '拉起后进程又消失'; return }
        if (Test-Online) {
            if ($i -eq 1) { Write-Log '客户端已自动联网' } else { Write-Log '点击登录后已联网' }
            return
        }
        [void](Invoke-LoginClick)
        Start-Sleep -Seconds 10
        if (Test-Online) { Write-Log '点击登录后已联网'; return }
    }
    Write-Log '连续 5 次点击登录仍未联网，等人工处理'
}

# ---------- 部署目录权限 ----------
# 为什么必须先抢所有权：Windows 里"属主"隐式拥有 READ_CONTROL + WRITE_DAC，不管
# DACL 写成什么样，属主都能把自己重新加回完全控制。而 C:\ProgramData 默认给
# BUILTIN\Users 的是 (CI)(AD,WD,WEA,WA)，普通用户**可以在这里建子目录**、并因
# CREATOR OWNER 规则成为属主。于是存在这样一条路：抢先建出
# C:\ProgramData\TianyiAutoLogin → 管理员 -Install 只改 DACL → 属主仍是攻击者
# → 他把自己加回去 → 改写脚本 → 下次登录以管理员执行。
# 所以：先 /setowner 换成 Administrators，再设 DACL，最后回读校验。

function Set-DeployDirAcl {
    param([string]$Dir)

    # 1) 先拿所有权。用 takeown /a 而不是 icacls /setowner：
    #    把所有者设成"Administrators 组"需要 SeRestorePrivilege，这个特权在提权进程里
    #    默认是关闭的，icacls 不会自己启用它 → /setowner 静默失败、退出码非 0。
    #    takeown 会自己启用所需特权，/a 表示把所有者给 Administrators 组。
    $ownerOut = & takeown.exe /f $Dir /a /r /d y 2>&1 | Out-String
    $ownerExit = $LASTEXITCODE

    # 2) 修子对象：/reset 让它们重新从父目录继承。
    #    这同时会清掉任何历史遗留的"显式"ACE（包括被人加的 Users:(F)）。
    #    必须在 3) 之前做：先改父目录再 reset 孩子，孩子中间会短暂失去全部权限。
    $childExit = 0
    $childOut = ''
    $children = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)
    if ($children.Count -gt 0) {
        $childOut = & icacls.exe (Join-Path $Dir '*') /reset /T /C 2>&1 | Out-String
        $childExit = $LASTEXITCODE
    }

    # 3) 父目录：断开继承 + 只留 SYSTEM 与 Administrators。
    #    ⚠ 这里**绝对不能加 /T**。上一版写成 /inheritance:r /grant:r ... /T，
    #    递归时父目录先断开继承，子文件瞬间变成"空 DACL"（谁都读写不了），
    #    随后 icacls 也没法再给它们授权 —— 部署副本就这样被锁死，
    #    表现为 Get-FileHash 读不到、Copy-Item 报"访问被拒绝"。
    #    父目录加上 (OI)(CI) 的 ACE 后，子对象会自动继承，不需要递归。
    $aclOut = & icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' "*${AdminsSid}:(OI)(CI)F" 2>&1 | Out-String
    $aclExit = $LASTEXITCODE

    # 失败时把命令输出的最后几行留下来，方便事后定位（提权窗口一闪就没）
    $detail = ''
    if ($ownerExit -ne 0 -or $childExit -ne 0 -or $aclExit -ne 0) {
        $lines = @(($ownerOut + $childOut + $aclOut) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4)
        $detail = ' :: ' + ($lines -join ' / ')
    }
    $script:AclDiag = ('takeown={0}, childReset={1}, icacls={2}{3}' -f $ownerExit, $childExit, $aclExit, $detail)
    return ($ownerExit -eq 0 -and $aclExit -eq 0)
}

# 目标文件可能还带着上一次留下的坏 ACL（空 DACL / 拒绝写），直接覆盖会"访问被拒绝"。
# 先删再建最稳：删除走父目录的 DELETE_CHILD 权限，不受文件自身 DACL 限制。
function Remove-FileIfExists([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch {
        Write-InstallLog ("提示：删除旧文件失败（{0}）：{1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

function Test-DeployDirAcl {
    # 回读校验：属主必须是 Administrators/SYSTEM，且没有给普通用户组任何"非只读"权限
    param([string]$Dir)
    $res = [pscustomobject]@{ Ok = $false; Owner = ''; Weak = @() }
    try { $acl = Get-Acl -LiteralPath $Dir -ErrorAction Stop } catch { return $res }

    try { $res.Owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value }
    catch { $res.Owner = [string]$acl.Owner }

    # 只读权限的组合：读数据/读属性/读权限/同步/列目录/执行
    $readOnly = [int][System.Security.AccessControl.FileSystemRights]'Read, ReadAndExecute, ReadData, ReadAttributes, ReadExtendedAttributes, ReadPermissions, Synchronize, ListDirectory, ExecuteFile, Traverse'
    $weakSids = @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-32-546', 'S-1-5-32-547', 'S-1-3-0')  # Users / Authenticated Users / Everyone / Guests / Power Users / CREATOR OWNER

    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = ''
        try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = [string]$ace.IdentityReference }
        if ($weakSids -notcontains $sid) { continue }
        if ((([int]$ace.FileSystemRights) -band (-bnot $readOnly)) -ne 0) {
            $res.Weak += ('{0}:{1}' -f $sid, $ace.FileSystemRights)
        }
    }

    $ownerOk = ($res.Owner -eq $AdminsSid)
    $res.Ok = ($ownerOk -and $res.Weak.Count -eq 0)
    return $res
}

# ---------- 客户端自带的开机自启 ----------
# 客户端装完通常会在 HKLM 的 Run 里留一项，登录时和本脚本的计划任务同时拉起。
# 守护只在"进程不存在"时才动手，所以一般不会双开；但要把这件事说清楚，别让
# "客户端没有自启"这个错误前提继续写进注释和 README。
function Get-ClientAutostart {
    $found = @()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $keys) {
        $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $val = [string]$p.Value
            if ($val -notmatch 'ESurfing|GDPortal|JSPortal|AutoStart\.exe') { continue }
            $exe = $val.Trim()
            if ($exe.StartsWith('"')) {
                $end = $exe.IndexOf('"', 1)
                if ($end -gt 1) { $exe = $exe.Substring(1, $end - 1) }
            } else {
                $exe = ($exe -split ' ')[0]
            }
            $exeExists = $false
            if ($exe) { $exeExists = [bool](Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue) }
            $found += [pscustomobject]@{
                Key    = $k
                Name   = $p.Name
                Value  = $val
                Exists = $exeExists
            }
        }
    }
    return $found
}

# ---------- 源码副本 vs 部署副本 ----------
# -Install 是单向复制，之后改源码不会同步。没有这个检查，"以为部署了、其实跑的是
# 旧版"就会静默发生（上一轮那个点击判定失效就是这么来的）。
function Get-DeployDrift {
    $dst = Join-Path $DeployDir 'TianyiAutoLogin.ps1'
    $hasDst = Test-PathAccessible $dst
    if ($null -eq $hasDst) { return 'unreadable' }   # 目录存在但没权限（普通用户）
    if (-not $hasDst) { return 'none' }
    try {
        $srcHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $dstHash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch { return 'unreadable' }
    if ($srcHash -eq $dstHash) { return 'same' }
    return 'drift'
}

# ---------- 部署 / 卸载 ----------
function Invoke-Elevate {
    param([string]$Switch)
    # -NoProfile 是必须的：不加的话提权进程会先加载当前用户的 $PROFILE
    # （Documents\WindowsPowerShell\profile.ps1，普通用户可写），
    # 任何用户态程序往那儿写几行，代码就会在管理员进程里执行。
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",$Switch
}

# 停掉「计划任务拉起的隐藏守护」。
# 判据是命令行同时含脚本名与 -WindowStyle Hidden：用户自己开的调试窗口没有
# -WindowStyle Hidden，不会被误杀；反过来，按 *TianyiAutoLogin.ps1* 通配杀进程
# 会把编辑器里的终端一起带走。
# 注意：旧守护以管理员运行，非提权上下文读不到它的 CommandLine，所以本函数只在
# 已提权的 -Install / -Uninstall 里调用。
function Stop-DaemonProcesses {
    $killed = @()
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -and
            $_.CommandLine -like '*TianyiAutoLogin.ps1*' -and
            $_.CommandLine -like '*-WindowStyle Hidden*'
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $killed += $_.ProcessId
        }
    return $killed
}

# 把客户端哈希记到指定目录
function Save-ClientHash([string]$dir) {
    if (-not (Test-Path $ClientExe)) {
        Write-Host "客户端不存在，跳过哈希记录：$ClientExe"
        return $false
    }
    $h = (Get-FileHash -Path $ClientExe -Algorithm SHA256).Hash
    $hashPath = Join-Path $dir 'client-sha256.txt'
    [void](Remove-FileIfExists $hashPath)      # 旧文件可能带着坏 ACL，先删再写
    $h | Out-File $hashPath -Encoding ASCII -Force
    Write-Host "已记录客户端哈希：$h"
    return $true
}

if ($Install) {
    # 客户端以管理员权限运行，安装步骤也需提权，保证后续排错时权限一致
    if (-not (Test-Admin)) {
        try { Invoke-Elevate '-Install' }
        catch {
            Write-Host ("提权失败（UAC 被取消？）：{0}" -f $_.Exception.Message)
            Write-Host '未做任何改动。重新运行并允许管理员权限即可。'
            exit 1
        }
        Write-Host '请在弹出的 UAC 窗口中确认，以完成安装。'
        Write-Host ("安装过程会记录到：{0}" -f $script:InstallLog)
        Write-Host '（提权窗口一闪而过时，用记事本打开上面这个文件看失败原因）'
        exit 0
    }

    Write-InstallLog '===== -Install 开始（已提权）====='
    Write-InstallLog ("部署目录: {0}" -f $DeployDir)

    $dstPs1  = Join-Path $DeployDir 'TianyiAutoLogin.ps1'
    $dstVbs  = Join-Path $DeployDir '天翼校园自动登录.vbs'
    $dstCfg  = Join-Path $DeployDir 'client-path.txt'

    # 1) 建部署目录；先记下"装之前是什么状态"，用于判断有没有被人抢建
    $dirExisted = Test-Path $DeployDir
    $oldOwner = ''
    if ($dirExisted) {
        try { $oldOwner = (Get-Acl -LiteralPath $DeployDir -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        Write-InstallLog ("目录已存在，原所有者: {0}" -f $(if ($oldOwner) { $oldOwner } else { '读取失败' }))
    } else {
        New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
        Write-InstallLog '目录不存在，已新建'
    }

    # 2) 抢所有权 + 收紧 ACL，然后**回读校验**；锁不住就中止，不注册最高权限任务
    [void](Set-DeployDirAcl $DeployDir)
    $aclState = Test-DeployDirAcl $DeployDir
    if (-not $aclState.Ok) {
        Write-InstallLog ''
        Write-InstallLog '安装中止：部署目录权限没有锁住，不能带着这个状态注册最高权限计划任务。'
        Write-InstallLog ("  目录      : {0}" -f $DeployDir)
        Write-InstallLog ("  当前属主  : {0}（期望 {1} = Administrators）" -f $aclState.Owner, $AdminsSid)
        Write-InstallLog ("  命令结果  : {0}" -f $script:AclDiag)
        if ($aclState.Weak.Count -gt 0) {
            Write-InstallLog ("  残留弱权限: {0}" -f ($aclState.Weak -join '; '))
        }
        Write-InstallLog '  处理办法：以管理员身份打开该目录属性 -> 安全 -> 高级，把所有者改成'
        Write-InstallLog '  Administrators 并移除普通用户的写权限，然后重新执行 -Install。'
        exit 1
    }
    Write-InstallLog ("权限校验通过：所有者 {0}，无普通用户组写权限" -f $aclState.Owner)

    # 功能自检：DACL 读起来正确 ≠ 真的能写。子对象 DACL 被清空、额外限制策略等
    # 都会让"校验通过"但写不进去。这里真写一个探针文件，早报错比在复制时炸清楚。
    $probe = Join-Path $DeployDir '.write-probe'
    $canWrite = $false
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
        $canWrite = $true
    } catch {
        Write-InstallLog ("  探针写入失败：{0}" -f $_.Exception.Message)
    }
    if ($canWrite) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    if (-not $canWrite) {
        Write-InstallLog '安装中止：目录权限看起来正确，但管理员实际写不进去。'
        Write-InstallLog ("  命令结果: {0}" -f $script:AclDiag)
        Write-InstallLog '  常见原因：目录里有被抽空 DACL 的子对象，或安全软件拦截了对该目录的写入。'
        exit 1
    }
    Write-InstallLog '写入自检通过'
    if ($dirExisted -and $oldOwner -and $oldOwner -ne $AdminsSid) {
        Write-InstallLog ("注意：部署目录原先的所有者是 {0}，已收回给 Administrators。" -f $oldOwner)
    }

    # 3) 部署脚本本体，并立刻比对哈希（防止半写/截断的副本被计划任务执行）
    $samePath = $false
    try {
        $samePath = [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($dstPs1), [StringComparison]::OrdinalIgnoreCase)
    } catch { }
    if (-not $samePath) {
        Write-InstallLog ("复制脚本 -> {0}" -f $dstPs1)
        [void](Remove-FileIfExists $dstPs1)
        try {
            Copy-Item -LiteralPath $PSCommandPath -Destination $dstPs1 -Force -ErrorAction Stop
        } catch {
            Write-InstallLog ("安装中止：复制脚本失败：{0}" -f $_.Exception.Message)
            exit 1
        }

        # 复制后立刻确认目标还在。杀软把它当可疑文件隔离掉时，这里会是 False。
        $existsNow = [IO.File]::Exists($dstPs1)
        $sizeNow = -1
        if ($existsNow) { try { $sizeNow = ([IO.FileInfo]$dstPs1).Length } catch { } }
        Write-InstallLog ("复制完成：目标存在={0} 大小={1} 字节" -f $existsNow, $sizeNow)

        # 刚写下去的文件可能正被杀软实时扫描占用，这时 Get-FileHash 会抛
        # sharing violation、返回空哈希（本次安装就是栽在这里）。重试几次；
        # 实在读不到就退回"比大小"——我们的目标是防止半写/截断，不是防并发攻击。
        $srcHash = $null
        $dstHash = $null
        for ($i = 1; $i -le 5; $i++) {
            try {
                $h1 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
                $h2 = (Get-FileHash -LiteralPath $dstPs1 -Algorithm SHA256 -ErrorAction Stop).Hash
                $srcHash = $h1
                $dstHash = $h2
                break
            } catch {
                if ($i -lt 5) { Start-Sleep -Milliseconds 400 }
                else { Write-InstallLog ("哈希读不到（{0}），改用文件大小比对" -f $_.Exception.Message) }
            }
        }

        if ($srcHash -and $dstHash) {
            if ($srcHash -ne $dstHash) {
                Write-InstallLog ("安装中止：脚本复制后校验不一致（源 {0} / 部署 {1}）。" -f $srcHash, $dstHash)
                exit 1
            }
            Write-InstallLog ("脚本副本已写入并校验一致（{0}）" -f $srcHash)
        } else {
            $lenSrc = 0
            $lenDst = -1
            try { $lenSrc = ([IO.FileInfo]$PSCommandPath).Length } catch { }
            if ([IO.File]::Exists($dstPs1)) { try { $lenDst = ([IO.FileInfo]$dstPs1).Length } catch { } }
            if ($lenSrc -ne $lenDst) {
                Write-InstallLog ("安装中止：脚本副本大小不一致（源 {0} 字节 / 部署 {1} 字节，-1 表示不存在）。" -f $lenSrc, $lenDst)
                if ($lenDst -eq -1) {
                    Write-InstallLog '  目标文件在复制后消失了——通常是安全软件（火绒/Defender）把它隔离了。'
                    Write-InstallLog '  把 C:\ProgramData\TianyiAutoLogin 和本脚本加入白名单/排除项后重试。'
                }
                exit 1
            }
            Write-InstallLog ("脚本副本已写入（大小一致 {0} 字节；哈希读不到，已跳过内容比对）" -f $lenSrc)
        }
    }

    # 4) 客户端路径：把当前解析到的路径写进部署目录（部署后没有它就会退回默认值）
    [void](Remove-FileIfExists $dstCfg)
    $ClientDir | Out-File $dstCfg -Encoding UTF8 -Force

    # 5) 记录客户端哈希，作为后续启动前的校验基准
    [void](Save-ClientHash $DeployDir)

    # 6) 生成隐藏运行的 VBS 启动器（wscript 按 ANSI 读，必须用 Default 编码写）
    #    第三个参数 False = 不等待，wscript 立刻退出、PowerShell 守护进程留在后台
    [void](Remove-FileIfExists $dstVbs)
    $vbsLines = @(
        'Set ws = CreateObject("WScript.Shell")'
        'ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $dstPs1 + '""", 0, False'
    )
    Set-Content -Path $dstVbs -Value $vbsLines -Encoding Default

    # 7) 注册「登录时以最高权限运行」的计划任务（隐藏窗口、免 UAC）
    try {
        $tr = 'wscript.exe "' + $dstVbs + '"'
        & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RL HIGHEST /F *> $null
        if ($LASTEXITCODE -ne 0) { throw "schtasks create exit code $LASTEXITCODE" }
        Write-InstallLog '计划任务已注册'
    } catch {
        Write-InstallLog "安装失败：$($_.Exception.Message)"
        exit 1
    }

    # 8) 清掉旧入口：从仓库目录安装时，原目录里的 VBS 已失效，留着会造成双重启动
    if (-not $IsDeployed) {
        $staleVbs = Join-Path (Split-Path -Parent $PSCommandPath) '天翼校园自动登录.vbs'
        if ((Test-Path $staleVbs) -and -not [string]::Equals($staleVbs, $dstVbs, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $staleVbs -Force -ErrorAction SilentlyContinue
        }
    }

    Write-InstallLog ("安装完成：`n  部署目录: {0}（所有者 Administrators，仅 SYSTEM/Administrators 可写）`n  脚本副本: {1}`n  计划任务: {2}（登录时自动运行，已在后台启动）`n  日志位置: {3}" -f $DeployDir, $dstPs1, $TaskName, (Join-Path $DeployDir 'autologin.log'))

    # 9) 客户端自带的开机自启会跟计划任务撞车，装完顺手报一下
    $autostart = @(Get-ClientAutostart)
    if ($autostart.Count -gt 0) {
        Write-InstallLog ''
        Write-InstallLog '提示：客户端自带开机自启，登录时会和本计划任务同时拉起同一客户端：'
        foreach ($a in $autostart) {
            $tail = if ($a.Exists) { '' } else { '（目标不存在，死项，可以删）' }
            Write-InstallLog ("  [{0}] {1} = {2}{3}" -f $a.Name, $a.Key, $a.Value, $tail)
        }
        Write-InstallLog '  守护只在「进程不存在」时才拉起，一般不会双开；遇到双开/抢窗口就在客户端设置里关掉自启。'
    }

    # 10) 立即拉起来跑一遍，不用等下次登录
    # 先停旧守护：它可能跑的是旧路径旧版本，还占着全局互斥量；
    # 不停掉的话，新守护抢不到互斥量会直接 exit 0，等于没换上。
    $killed = Stop-DaemonProcesses
    if ($killed.Count -gt 0) {
        Write-InstallLog ("已停止旧守护进程：{0}" -f ($killed -join ', '))
        Start-Sleep -Seconds 2
    }
    try { & schtasks.exe /Run /TN $TaskName *> $null } catch { }
    Write-InstallLog '已触发计划任务，守护进程应在数秒内启动'
    exit 0
}

if ($TrustClient) {
    if (-not (Test-Admin)) {
        try { Invoke-Elevate '-TrustClient' }
        catch {
            Write-Host ("提权失败（UAC 被取消？）：{0}" -f $_.Exception.Message)
            exit 1
        }
        Write-Host '请在弹出的 UAC 窗口中确认。'
        Write-Host ("过程会记录到：{0}" -f $script:InstallLog)
        exit 0
    }
    $target = $DeployDir
    if (-not (Test-Path $target)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }
    # 每次都重设一遍（幂等）：老版本装的目录可能只改了 DACL、属主还是普通用户，
    # 这里顺手把它修好，而不是直接拒绝。
    [void](Set-DeployDirAcl $target)
    $aclState = Test-DeployDirAcl $target
    if (-not $aclState.Ok) {
        Write-Host ("失败：{0} 的权限未锁住（属主 {1}；{2}），写入的哈希基准不可信。先修目录权限再重试。" -f $target, $aclState.Owner, $script:AclDiag)
        exit 1
    }
    [void](Save-ClientHash $target)
    Write-Host ("已更新信任的客户端哈希，位置：{0}" -f (Join-Path $target 'client-sha256.txt'))
    exit 0
}

if ($Uninstall) {
    if (-not (Test-Admin)) {
        Invoke-Elevate '-Uninstall'
        exit 0
    }

    try { & schtasks.exe /Delete /TN $TaskName /F *> $null } catch { }
    if (Test-Path $VbsPath) { Remove-Item -LiteralPath $VbsPath -Force -ErrorAction SilentlyContinue }

    # 停守护：优先按 PID 文件，并核对确实是跑本脚本的 powershell，避免误杀复用了 PID 的进程
    $stopped = $false
    if (Test-Path $PidFile) {
        $rawPid = Get-Content $PidFile -Raw -ErrorAction SilentlyContinue
        if ($rawPid) { $rawPid = $rawPid.Trim() }
        if ($rawPid -match '^\d+$') {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$rawPid" -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -eq 'powershell.exe' -and $proc.CommandLine -like '*TianyiAutoLogin.ps1*') {
                Stop-Process -Id ([int]$rawPid) -Force -ErrorAction SilentlyContinue
                $stopped = $true
            }
        }
    }

    # 兜底：只杀「计划任务拉起的隐藏守护」（命令行含脚本名 + -WindowStyle Hidden），
    # 不用 *TianyiAutoLogin.ps1* 泛匹配，避免误杀编辑器里的调试终端。
    $killed = Stop-DaemonProcesses
    if ($killed.Count -gt 0) { $stopped = $true }

    # 删部署目录（只认带本脚本的那个目录，避免误删别的东西）
    if ((Test-Path $DeployDir) -and (Test-Path (Join-Path $DeployDir 'TianyiAutoLogin.ps1'))) {
        Remove-Item -Path $DeployDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("已卸载：计划任务已删除，部署目录已清理，守护进程{0}。" -f $(if ($stopped) { '已停止' } else { '未在运行' }))
    exit 0
}

# ============================================================
# 自检（只报告，不动任何东西）
# ============================================================
if ($DryRun) {
    $cl = Get-Client
    $on = Test-Online
    $clTxt = if ($cl.Count -gt 0) {
        "PID=$($cl[0].Id) 已运行 $([int]((Get-Date) - $cl[0].StartTime).TotalSeconds) 秒"
    } else {
        '未运行（守护会拉起）'
    }

    # 运行体已经迁到部署目录了。从源码目录跑自检时，客户端路径和哈希基准都必须
    # 看**部署副本**，否则会拿源码目录里不存在的 client-sha256.txt 误报"未配置"。
    $deployedPs1 = Join-Path $DeployDir 'TianyiAutoLogin.ps1'
    # $true=存在 / $false=没有部署 / $null=存在但当前权限读不到
    $deployProbe = Test-PathAccessible $deployedPs1
    # 读不到时也要按"部署副本"来判，否则会退回源码目录、误报"哈希未配置"
    $checkDir    = if ($deployProbe -eq $false) { $ScriptDir } else { $DeployDir }
    $checkCfgFile  = Join-Path $checkDir 'client-path.txt'
    $checkHashFile = Join-Path $checkDir 'client-sha256.txt'

    $checkClientDir = $ClientDir
    if ((Test-PathAccessible $checkCfgFile) -eq $true) {
        $rawCfg = Get-Content -LiteralPath $checkCfgFile -Raw -ErrorAction SilentlyContinue
        if ($rawCfg) {
            $rawCfg = $rawCfg.Trim().TrimStart([char]0xFEFF).Trim()
            if ($rawCfg) { $checkClientDir = $rawCfg }
        }
    }
    $checkClientExe = Join-Path $checkClientDir 'ESurfingClient.exe'

    $trustTxt = switch (Get-TrustState -HashFile $checkHashFile -Exe $checkClientExe) {
        'ok'       { '通过' }
        'none'     { '未配置（-Install 会生成）' }
        'mismatch' { '失败：客户端已变更，需 -TrustClient 重新信任' }
        'missing'  { '失败：客户端文件不存在' }
        'denied'   { '读不到基准（用管理员运行 -DryRun 才能看）' }
        default    { '未知' }
    }
    $driftTxt = switch (Get-DeployDrift) {
        'none'       { '无部署副本（-Install 会创建）' }
        'same'       { '与源码一致' }
        'drift'      { '不一致：改了源码但没重新 -Install，跑的还是旧版' }
        'unreadable' { '读不到（用管理员运行 -DryRun 才能比对）' }
        default      { '未知' }
    }
    $taskTxt = '未注册'
    try {
        & schtasks.exe /Query /TN $TaskName *> $null
        if ($LASTEXITCODE -eq 0) { $taskTxt = '已注册' }
    } catch {
        $taskTxt = '查询失败（权限或策略限制）'
    }

    Write-Host ("脚本位置    : {0}{1}" -f $ScriptDir, $(if ($IsDeployed) { '（已部署，受 ACL 保护）' } else { '（开发副本，未部署）' }))
    Write-Host ("部署目录    : {0}  {1}" -f $DeployDir, $(if ((Test-PathAccessible $DeployDir) -eq $true) { '存在' } else { '不存在' }))
    Write-Host ("部署副本    : {0}" -f $driftTxt)
    Write-Host ("计划任务    : {0}  {1}" -f $TaskName, $taskTxt)
    Write-Host ("客户端路径  : {0}  {1}" -f $checkClientExe, $(if (Test-Path $checkClientExe) { '存在' } else { '不存在' }))
    Write-Host ("哈希校验    : {0}" -f $trustTxt)
    Write-Host ("客户端      : {0}" -f $clTxt)
    Write-Host ("网络连通    : {0}" -f $(if ($on) { '在线' } else { '离线' }))
    Write-Host ("掉线判定    : 连续 {0} 次探测失败（约 {1} 秒）" -f $OfflineSamples, ($OfflineSamples * $PollSec))

    $autostart = @(Get-ClientAutostart)
    if ($autostart.Count -gt 0) {
        $alive = @($autostart | Where-Object { $_.Exists })
        Write-Host ("客户端自启  : 发现 {0} 项（有效 {1} 项），登录时会和计划任务同时拉起" -f $autostart.Count, $alive.Count)
        foreach ($a in $autostart) {
            Write-Host ("              [{0}] {1}{2}" -f $a.Name, $a.Value, $(if ($a.Exists) { '' } else { '（死项）' }))
        }
    } else {
        Write-Host '客户端自启  : 未发现（开机只靠本脚本拉起）'
    }

    # 部署副本的日志才有诊断价值（仓库目录那份是开发模式留下的）
    $deployLog = Join-Path $DeployDir 'autologin.log'
    if ((Test-PathAccessible $deployLog) -eq $true) {
        Write-Host ''
        Write-Host '--- 部署副本最近日志 ---'
        try {
            Get-Content $deployLog -Tail 12 -Encoding UTF8 -ErrorAction Stop | ForEach-Object { Write-Host ('  ' + $_) }
        } catch {
            Write-Host '  （当前权限读不到，需管理员）'
        }
    }
    exit 0
}

# ============================================================
# 守护主循环（常驻，静默）
# ============================================================
# 单实例：已有守护在跑就直接退出，避免重复启动
# Global\ 需要 SeCreateGlobalPrivilege（仅管理员有），非提权运行时退回 Local\
$mutexName = if (Test-Admin) { $MutexName } else { 'Local\TianyiAutoLoginWatchdog' }
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    if (-not $mutex.WaitOne(0)) { exit 0 }
} catch {
    # 拿不到互斥量就别硬跑，避免双守护互相重启客户端
    exit 0
}

$PID | Out-File $PidFile -Encoding ASCII -Force

Rotate-Log
Write-Log ("===== 守护启动（{0}）=====" -f $(if ($IsDeployed) { '部署副本' } else { '开发副本' }))
Grant-LogRead
if (-not $IsDeployed -and ((Test-PathAccessible (Join-Path $DeployDir 'TianyiAutoLogin.ps1')) -eq $true)) {
    Write-Log '注意：当前跑的是源码副本，正式部署副本在 ProgramData，两者可能不一致（改了源码请重新 -Install）'
}
if (Get-TrustState -eq 'none') { Write-Log '客户端哈希校验未启用' }

$lastStart    = [datetime]::MinValue
$lastRestart  = [datetime]::MinValue
$offlineHits  = 0
$restartTries = 0
$state        = 'init'      # init / online / offline / blocked

while ($true) {
    $cl = Get-Client

    if ($cl.Count -eq 0) {
        # 进程不在 = 网必断，直接拉起并顺手点登录（限速，避免短时间内反复起进程）
        if (((Get-Date) - $lastStart).TotalSeconds -ge $StartGapSec) {
            if (Test-ClientReady) {
                Write-Log '客户端进程不在，拉起'
                try {
                    Start-ClientAndLogin
                    $lastStart = Get-Date
                } catch {
                    Write-Log "拉起失败：$($_.Exception.Message)"
                }
                $offlineHits = 0
                $state = 'init'
            } else {
                if ($state -ne 'blocked') { Write-Log '客户端校验未通过，已停止自动拉起'; $state = 'blocked' }
                $lastStart = Get-Date          # 同样限速，别每 15 秒刷一次
            }
        }
    }
    elseif (Test-Online) {
        if ($state -ne 'online') {
            Write-Log '网络在线'
            $state = 'online'
            $restartTries = 0
        }
        $offlineHits = 0
    }
    else {
        $offlineHits++
        if ($state -ne 'offline') {
            Write-Log '检测到离线，开始计数'
            $state = 'offline'
        }

        if ($offlineHits -ge $OfflineSamples) {
            $up   = Get-ClientUptimeSec
            $gap  = if ($restartTries -ge 3) { 900 } else { $RestartGapSec }
            $wait = ((Get-Date) - $lastRestart).TotalSeconds

            # 只在客户端已经稳定运行过、且距上次重启足够久时才动手
            if ($up -ge $ClientGraceSec -and $wait -ge $gap) {
                # 先确认能起来再杀：校验不过就杀掉只会让你彻底断网
                if (-not (Test-ClientReady)) {
                    if ($state -ne 'blocked') { Write-Log '客户端校验未通过，跳过重启'; $state = 'blocked' }
                } else {
                    Write-Log ("离线约 {0} 秒，重启客户端（第 {1} 次尝试）" -f ($offlineHits * $PollSec), ($restartTries + 1))
                    $stopped = $false
                    try {
                        Get-Client | Stop-Process -Force -ErrorAction Stop
                        $stopped = $true
                    } catch {
                        Write-Log "结束客户端进程失败：$($_.Exception.Message)"
                    }

                    if ($stopped) {
                        Start-Sleep -Seconds 3
                        if ((Get-Client).Count -eq 0) {
                            try {
                                Start-ClientAndLogin
                                $lastStart   = Get-Date
                                $lastRestart = Get-Date
                                $restartTries++
                                $offlineHits = 0
                                $state = 'init'
                            } catch {
                                Write-Log "重启客户端失败：$($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
        }
    }

    Start-Sleep -Seconds $PollSec
}
