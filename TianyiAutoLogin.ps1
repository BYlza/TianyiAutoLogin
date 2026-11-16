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
#   * 客户端没有任何开机自启项，开机必须由本脚本拉起。
#   * 客户端被拉起后如果停在登录页不会自己拨号，脚本会自动点一次「登录」按钮。
#     该界面是内嵌网页（窗口类 wkeWebWindow），没有控件树，只能按客户区相对坐标点击。
#   * 脚本常驻运行（不退出），平时不写日志、不弹窗；只在状态变化时记一行。
#
# 安全设计：
#   * -Install 会把脚本本体部署到 %ProgramData%\TianyiAutoLogin，并把该目录 ACL
#     收紧为「仅 SYSTEM + Administrators」，去掉普通用户的写权限。
#     计划任务以最高权限运行；若脚本留在用户可写目录，任何用户态程序都能改写它，
#     从而在下次登录时静默拿到管理员权限。
#   * -Install 同时把客户端 exe 的 SHA256 记进 client-sha256.txt。此后每次启动客户端
#     前都会校验，不匹配就拒绝启动（防止客户端被替换后以管理员权限执行任意程序）。
#     官方升级客户端后，重新执行一次 -TrustClient 记录新哈希。
#   * 自动点击前会校验前台窗口确实是客户端窗口，不匹配就放弃本次点击。
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
$DeployDir  = Join-Path $env:ProgramData 'TianyiAutoLogin'
$TaskName   = 'TianyiAutoLogin'
$MutexName  = 'Global\TianyiAutoLoginWatchdog'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
if (Test-Path $ClientPathFile) {
    $rawCfg = Get-Content $ClientPathFile -Raw -ErrorAction SilentlyContinue
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

# ---------- 客户端完整性校验 ----------
# 把哈希文件放在受 ACL 保护的部署目录里才有意义：普通用户改不了基准值。
$script:lastTrustLog = [datetime]::MinValue

function Get-TrustState {
    # 返回：none（未配置） / ok / mismatch / missing
    if (-not (Test-Path $ClientHashFile)) { return 'none' }
    $want = Get-Content $ClientHashFile -Raw -ErrorAction SilentlyContinue
    if ($want) { $want = $want.Trim().TrimStart([char]0xFEFF).Trim() }
    if (-not $want) { return 'none' }
    if (-not (Test-Path $ClientExe)) { return 'missing' }
    try { $got = (Get-FileHash -Path $ClientExe -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return 'missing' }
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
    [void][Ty.TyWin32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 400

    # 抢前台可能被系统拒绝（前台锁定等），没抢到就不点，避免点到别的窗口
    if ([Ty.TyWin32]::GetForegroundWindow() -ne $h) {
        Write-Log '窗口未切到前台，跳过本次点击'
        return $false
    }

    $rect = New-Object 'Ty.TyWin32+RECT'
    if (-not [Ty.TyWin32]::GetClientRect($h, [ref]$rect)) { return $false }
    if ($rect.Right -le 0 -or $rect.Bottom -le 0) { return $false }

    $pt = New-Object 'Ty.TyWin32+POINT'
    $pt.X = [int]($rect.Right * $LoginPointX)
    $pt.Y = [int]($rect.Bottom * $LoginPointY)
    [void][Ty.TyWin32]::ClientToScreen($h, [ref]$pt)

    # 算坐标到真正点击之间还有几十毫秒，再确认一次前台没被抢走
    if ([Ty.TyWin32]::GetForegroundWindow() -ne $h) {
        Write-Log '点击前前台窗口已变化，已取消本次点击'
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

# ---------- 部署 / 卸载 ----------
function Invoke-Elevate {
    param([string]$Switch)
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
    $h | Out-File (Join-Path $dir 'client-sha256.txt') -Encoding ASCII -Force
    Write-Host "已记录客户端哈希：$h"
    return $true
}

if ($Install) {
    # 客户端以管理员权限运行，安装步骤也需提权，保证后续排错时权限一致
    if (-not (Test-Admin)) {
        Invoke-Elevate '-Install'
        Write-Host '请在弹出的 UAC 窗口中确认，以完成安装。'
        exit 0
    }

    $dstPs1  = Join-Path $DeployDir 'TianyiAutoLogin.ps1'
    $dstVbs  = Join-Path $DeployDir '天翼校园自动登录.vbs'
    $dstCfg  = Join-Path $DeployDir 'client-path.txt'

    # 1) 建部署目录
    if (-not (Test-Path $DeployDir)) {
        New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null
    }

    # 2) 收紧 ACL：断开继承，只留 SYSTEM 与 Administrators（用 SID，避免中文系统组名问题）
    $aclOk = $false
    try {
        & icacls.exe $DeployDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
        $aclOk = ($LASTEXITCODE -eq 0)
    } catch { }
    if (-not $aclOk) {
        Write-Host "⚠ ACL 收紧失败。脚本仍会被提权运行，建议手动检查 $DeployDir 的权限，确保普通用户不可写。"
    }

    # 3) 部署脚本本体
    if (-not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($dstPs1), [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $dstPs1 -Force
    }

    # 4) 客户端路径：把当前解析到的路径写进部署目录（部署后没有它就会退回默认值）
    $ClientDir | Out-File $dstCfg -Encoding UTF8 -Force

    # 5) 记录客户端哈希，作为后续启动前的校验基准
    [void](Save-ClientHash $DeployDir)

    # 6) 生成隐藏运行的 VBS 启动器（wscript 按 ANSI 读，必须用 Default 编码写）
    #    第三个参数 False = 不等待，wscript 立刻退出、PowerShell 守护进程留在后台
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
    } catch {
        Write-Host "安装失败：$($_.Exception.Message)"
        exit 1
    }

    # 8) 清掉旧入口：从仓库目录安装时，原目录里的 VBS 已失效，留着会造成双重启动
    if (-not $IsDeployed) {
        $staleVbs = Join-Path (Split-Path -Parent $PSCommandPath) '天翼校园自动登录.vbs'
        if ((Test-Path $staleVbs) -and -not [string]::Equals($staleVbs, $dstVbs, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $staleVbs -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ("安装完成：`n  部署目录: {0}`n  脚本副本: {1}`n  计划任务: {2}（登录时自动运行，已在后台启动）`n  日志位置: {3}" -f $DeployDir, $dstPs1, $TaskName, (Join-Path $DeployDir 'autologin.log'))

    # 立即拉起来跑一遍，不用等下次登录
    # 先停旧守护：它可能跑的是旧路径旧版本，还占着全局互斥量；
    # 不停掉的话，新守护抢不到互斥量会直接 exit 0，等于没换上。
    $killed = Stop-DaemonProcesses
    if ($killed.Count -gt 0) {
        Write-Host ("已停止旧守护进程：{0}" -f ($killed -join ', '))
        Start-Sleep -Seconds 2
    }
    try { & schtasks.exe /Run /TN $TaskName *> $null } catch { }
    exit 0
}

if ($TrustClient) {
    if (-not (Test-Admin)) {
        Invoke-Elevate '-TrustClient'
        Write-Host '请在弹出的 UAC 窗口中确认。'
        exit 0
    }
    $target = $DeployDir
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
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
    $trustTxt = switch (Get-TrustState) {
        'ok'       { '通过' }
        'none'     { '未配置（-Install 会生成）' }
        'mismatch' { '失败：客户端已变更，需 -TrustClient 重新信任' }
        'missing'  { '失败：客户端文件不存在' }
        default    { '未知' }
    }
    $taskTxt = '未注册'
    try {
        & schtasks.exe /Query /TN $TaskName *> $null
        if ($LASTEXITCODE -eq 0) { $taskTxt = '已注册' }
    } catch {
        $taskTxt = '查询失败（权限或策略限制）'
    }

    Write-Host ("脚本位置    : {0}{1}" -f $ScriptDir, $(if ($IsDeployed) { '（已部署，受 ACL 保护）' } else { '（开发副本，未部署）' }))
    Write-Host ("部署目录    : {0}  {1}" -f $DeployDir, $(if (Test-Path $DeployDir) { '存在' } else { '不存在' }))
    Write-Host ("计划任务    : {0}  {1}" -f $TaskName, $taskTxt)
    Write-Host ("客户端路径  : {0}  {1}" -f $ClientExe, $(if (Test-Path $ClientExe) { '存在' } else { '不存在' }))
    Write-Host ("哈希校验    : {0}" -f $trustTxt)
    Write-Host ("客户端      : {0}" -f $clTxt)
    Write-Host ("网络连通    : {0}" -f $(if ($on) { '在线' } else { '离线' }))
    Write-Host ("掉线判定    : 连续 {0} 次探测失败（约 {1} 秒）" -f $OfflineSamples, ($OfflineSamples * $PollSec))
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
