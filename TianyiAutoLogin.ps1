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
# 用法：
#   安装开机自启并立即启动： powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Install
#   卸载（含停止守护）：     powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -Uninstall
#   当前状态自检一次：       powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1 -DryRun
#   前台运行守护（排错用）： powershell -ExecutionPolicy Bypass -File TianyiAutoLogin.ps1
# ============================================================
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------- 配置 ----------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path

# 天翼校园客户端安装目录。默认值只是常见安装位置，请按自己机器的实际路径修改；
# 也可以不改脚本，直接在本脚本同目录新建 client-path.txt 写一行真实路径
#（该文件已被 .gitignore 忽略，不会误提交）。
$ClientDir      = 'C:\Program Files (x86)\Chinatelecom\GDPortal'
$ClientPathFile = Join-Path $ScriptDir 'client-path.txt'
if (Test-Path $ClientPathFile) {
    $override = Get-Content $ClientPathFile -Raw -ErrorAction SilentlyContinue
    if ($override) { $override = $override.Trim() }
    if ($override) { $ClientDir = $override }
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

$VbsPath    = Join-Path $ScriptDir '天翼校园自动登录.vbs'
$LogFile    = Join-Path $ScriptDir 'autologin.log'
$TaskName   = 'TianyiAutoLogin'
$MutexName  = 'Global\TianyiAutoLoginWatchdog'

function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# 日志超过 1MB 就滚动一次，避免无限增长
function Rotate-Log {
    if (Test-Path $LogFile) {
        if ((Get-Item $LogFile).Length -gt 1MB) {
            Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
        }
    }
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

# ---------- 自动点击“登录”按钮 ----------
# 客户端界面是内嵌网页（窗口类名 wkeWebWindow），UIA 拿不到任何控件，
# 只能按客户区相对坐标点。实测：客户区 533×914 时登录按钮中心在 (0.500, 0.595)。
# 注意：已连接页面的同位置是空白区，点错也没有副作用（不会点到下面的“断开”）。
$LoginPointX = 0.500
$LoginPointY = 0.595

function Initialize-Win32 {
    if ('Ty.TyWin32' -as [type]) { return $true }
    try {
        Add-Type -Name 'TyWin32' -Namespace 'Ty' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
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

function Invoke-LoginClick {
    if (-not (Initialize-Win32)) { return $false }
    $p = Get-Client | Select-Object -First 1
    if (-not $p) { return $false }
    $h = $p.MainWindowHandle
    if ($h -eq 0) { return $false }

    [void][Ty.TyWin32]::ShowWindow($h, 9)              # SW_RESTORE，最小化也能点
    [void][Ty.TyWin32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 400

    $rect = New-Object 'Ty.TyWin32+RECT'
    if (-not [Ty.TyWin32]::GetClientRect($h, [ref]$rect)) { return $false }
    if ($rect.Right -le 0 -or $rect.Bottom -le 0) { return $false }

    $pt = New-Object 'Ty.TyWin32+POINT'
    $pt.X = [int]($rect.Right * $LoginPointX)
    $pt.Y = [int]($rect.Bottom * $LoginPointY)
    [void][Ty.TyWin32]::ClientToScreen($h, [ref]$pt)

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
    Start-Process $ClientExe
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

# ---------- 安装 / 卸载 ----------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Install) {
    # 客户端以管理员权限运行，安装步骤也需提权，保证后续排错时权限一致
    if (-not (Test-Admin)) {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Install'
        Write-Host '请在弹出的 UAC 窗口中确认，以完成安装。'
        exit 0
    }
    # 生成隐藏运行的 VBS 启动器（wscript 按 ANSI 读，必须用 Default 编码写）
    # 第三个参数 False = 不等待，wscript 立刻退出、PowerShell 守护进程留在后台
    $ps1 = $PSCommandPath
    $vbsLines = @(
        'Set ws = CreateObject("WScript.Shell")'
        'ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ps1 + '""", 0, False'
    )
    Set-Content -Path $VbsPath -Value $vbsLines -Encoding Default

    # 注册“登录时以最高权限运行”的计划任务（隐藏窗口、免 UAC）
    # 部分环境 Register-ScheduledTask 会被安全策略拦截，改用 schtasks.exe 更稳
    try {
        $tr = 'wscript.exe "' + $VbsPath + '"'
        & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RL HIGHEST /F 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks create exit code $LASTEXITCODE" }
        "OK" | Out-File (Join-Path $ScriptDir 'install_result.txt') -Encoding UTF8
    } catch {
        "FAIL: $($_.Exception.Message)" | Out-File (Join-Path $ScriptDir 'install_result.txt') -Encoding UTF8
        Write-Host "安装失败：$($_.Exception.Message)"
        exit 1
    }

    # 立即拉起来跑一遍，不用等下次登录
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null

    Write-Host "安装完成：`n  启动器: $VbsPath`n  计划任务: $TaskName（登录时自动运行，已在后台启动）"
    exit 0
}

if ($Uninstall) {
    if (-not (Test-Admin)) {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Uninstall'
        exit 0
    }
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    if (Test-Path $VbsPath) { Remove-Item $VbsPath -Force }
    # 顺手停掉还在跑的守护进程
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*TianyiAutoLogin.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-Host '已卸载开机自启，并停止守护进程。'
    exit 0
}

# ============================================================
# 自检（只报告，不动任何东西）
# ============================================================
if ($DryRun) {
    $cl = Get-Client
    $on = Test-Online
    $clTxt = if ($cl.Count -gt 0) {
        "PID=$($cl[0].Id) 已运行 $([int]((Get-Date) - $cl[0].StartTime).TotalSeconds) 秒 标题='$($cl[0].MainWindowTitle)'"
    } else {
        '未运行（守护会拉起）'
    }
    Write-Host ("客户端      : {0}" -f $clTxt)
    Write-Host ("网络连通    : {0}" -f $(if ($on) { '在线' } else { '离线' }))
    Write-Host ("掉线判定    : 连续 {0} 次探测失败（约 {1} 秒）" -f $OfflineSamples, ($OfflineSamples * $PollSec))
    Write-Host ("计划任务    : {0}" -f $TaskName)
    exit 0
}

# ============================================================
# 守护主循环（常驻，静默）
# ============================================================
# 单实例：已有守护在跑就直接退出，避免重复启动
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) { exit 0 }

Rotate-Log
Write-Log '===== 守护启动 ====='

$lastStart    = [datetime]::MinValue
$lastRestart  = [datetime]::MinValue
$offlineHits  = 0
$restartTries = 0
$state        = 'init'      # init / online / offline

while ($true) {
    $cl = Get-Client

    if ($cl.Count -eq 0) {
        # 进程不在 = 网必断，直接拉起并顺手点登录（限速，避免短时间内反复起进程）
        if (((Get-Date) - $lastStart).TotalSeconds -ge $StartGapSec) {
            Write-Log '客户端进程不在，拉起'
            try {
                Start-ClientAndLogin
                $lastStart = Get-Date
            } catch {
                Write-Log "拉起失败：$($_.Exception.Message)"
            }
            $offlineHits = 0
            $state = 'init'
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

    Start-Sleep -Seconds $PollSec
}
