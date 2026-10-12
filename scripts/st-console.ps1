<#
  SillyTavern 控制台（Windows）
  ------------------------------------------------------------
  一个给 SillyTavern（酒馆）用的命令行/菜单式控制台：
    - 后台隐藏启动、停止、重启、查看状态与日志
    - 自动显示手机访问地址（局域网 IP / Tailscale IP）
    - 可选：同时管理 "Agnes 生图桥"（让酒馆生图走任意 OpenAI 兼容生图 API）

  用法：
    双击桌面快捷方式（由 install.ps1 创建），或：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\st-console.ps1 -Action menu
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\st-console.ps1 -Action status

  配置：
    默认读取项目根目录的 config.json（可从 config.example.json 复制修改）。
    找不到时自动探测酒馆目录与 node.exe，并给出提示。

  编码：本文件为 UTF-8 with BOM，以便 Windows PowerShell 5.1 正确显示中文。
#>
param(
    [ValidateSet('menu', 'start', 'stop', 'restart', 'status', 'logs',
        'bridge-start', 'bridge-stop', 'install-shortcuts', 'install-tasks', 'where',
        'none')]
    [string]$Action = 'menu',
    [string]$ConfigPath = '',
# 供桌宠（st-pet.ps1）等非交互调用：结束后不要停下来等回车。
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$script:TaskInstallFailed = $false

# ---------------------------------------------------------------- 路径与配置

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ProjectDir 'config.json' }

function Find-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
        'D:\nodejs\node.exe',
        'C:\nodejs\node.exe'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return 'node.exe'
}

function Test-TavernDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    if (-not (Test-Path $dir)) { return $false }
    return (Test-Path (Join-Path $dir 'server.js'))
}

function Find-TavernDir {
    $candidates = @()
    $roots = @('C:', 'D:', 'E:', 'F:', 'G:')
    foreach ($r in $roots) {
        foreach ($n in @('SillyTavern', 'sillytavern', 'silly tavern')) {
            $candidates += "$r\$n"
        }
        $candidates += "$r\Program Files\SillyTavern"
    }
    $candidates += (Join-Path $env:USERPROFILE 'SillyTavern')
    $candidates += (Join-Path $env:LOCALAPPDATA 'SillyTavern')
    foreach ($r in $roots) {
        if (-not (Test-Path "$r\")) { continue }
        Get-ChildItem "$r\" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'tavern' } | ForEach-Object { $candidates += $_.FullName }
    }
    $valid = $candidates | Sort-Object -Unique | Where-Object { Test-TavernDir $_ } | ForEach-Object {
        $settings = Join-Path $_ 'data\default-user\settings.json'
        $hasData = Test-Path $settings
        $mtime = [datetime]'1970-01-01'
        if ($hasData) { $mtime = (Get-Item $settings).LastWriteTime }
        [pscustomobject]@{ Path = $_; HasData = $hasData; Mtime = $mtime }
    } | Sort-Object HasData, Mtime -Descending
    if ($valid) { return $valid[0].Path }
    return ''
}

function Get-ConsoleConfig {
    $defaults = [ordered]@{
        tavernDir = ''
        nodeExe   = ''
        port      = 8000
        host      = '127.0.0.1'
        logsDir   = 'logs'
        outLog    = 'st.out.log'
        errLog    = 'st.err.log'
        bridge    = [ordered]@{
            enabled    = $true
            port       = 7861
            script     = 'scripts/agnes-sd-bridge.mjs'
            configFile = '.secrets/agnes-bridge.json'
        }
        tasks     = [ordered]@{
            tavern = 'SillyTavern-AutoStart'
            bridge = 'Agnes-SDBridge-AutoStart'
        }
        shortcuts = [ordered]@{
            enabled = $true
            prefix  = 'Tavern'
        }
        # 桌宠（st-pet.ps1）用的外观设置
        pet       = [ordered]@{
            width        = 212     # 桌面上的宽度（像素，140–380）
            customImage  = ''      # 单张自定义形象（在气泡「设置 → 换形象…」里选）
            imageDir     = ''      # 留空 = 用酒馆自带角色图
            opacity      = 0.78    # 不碰它的时候多淡
            fadeWhenIdle = $true   # 是否启用上面那个「变淡」
            bounce       = $true   # 按压 Q 弹反馈
            snapEdge     = $true   # 拖到屏幕边上自动吸附
            sfx          = $true   # 音效开关
            volume       = 0.7     # 音效音量 0–1
        }
    }

    $cfg = $defaults
    if (Test-Path $ConfigPath) {
        try {
            $user = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $user.PSObject.Properties) {
                if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($q in $p.Value.PSObject.Properties) { $cfg[$p.Name][$q.Name] = $q.Value }
                } else {
                    $cfg[$p.Name] = $p.Value
                }
            }
        } catch {
            Write-Host "  ! 配置文件解析失败，使用默认值：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not $cfg.nodeExe) { $cfg.nodeExe = Find-NodeExe }
    if (-not (Test-TavernDir $cfg.tavernDir)) {
        $found = Find-TavernDir
        if ($found) { $cfg.tavernDir = $found }
    }
    $cfg.port = [int]$cfg.port
    $cfg.bridge.port = [int]$cfg.bridge.port
    $cfg.tavernDir = [string]$cfg.tavernDir
    return $cfg
}

$Config = Get-ConsoleConfig
$Port = $Config.port
$TavernDir = $Config.tavernDir
$NodeExe = $Config.nodeExe
$LogDir = Join-Path $TavernDir $Config.logsDir
$OutLog = Join-Path $LogDir $Config.outLog
$ErrLog = Join-Path $LogDir $Config.errLog
$BridgePort = $Config.bridge.port
$BridgeScriptPath = Join-Path $ProjectDir $Config.bridge.script
$BridgeConfigPath = Join-Path $ProjectDir $Config.bridge.configFile
$TavernTask = $Config.tasks.tavern
$BridgeTask = $Config.tasks.bridge

function Get-TavernPid {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.OwningProcess }
    return $null
}

function Get-BridgePid {
    if (-not $Config.bridge.enabled) { return $null }
    $c = Get-NetTCPConnection -LocalPort $BridgePort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.OwningProcess }
    return $null
}

# 光看「谁占着端口」不足以认定它就是酒馆：8000 / 7861 很常见，别把别人的程序杀了。
# 杀进程之前一律先核对进程名与命令行。
function Test-ProcLooksLike([int]$ProcId, [string]$Pattern) {
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop
        if (-not $ci) { return $false }
        if ($ci.Name -notmatch '^(node|nodejs)\.exe$') { return $false }
        if ([string]::IsNullOrWhiteSpace($ci.CommandLine)) { return $false }
        return ($ci.CommandLine -like "*$Pattern*")
    } catch { return $false }
}

function Get-TavernPattern { 'server.js' }
function Get-BridgePattern { Split-Path -Leaf $BridgeScriptPath }

function Get-LocalIPv4 {
    # 排除虚拟网卡（Clash/Tailscale/WireGuard/WSL/Hyper-V/蓝牙等），优先有默认网关的物理网卡
    $exclude = 'Clash|Meta Tunnel|Tailscale|WireGuard|vEthernet|Hyper-V|Loopback|VPN|TAP-|Bluetooth|Virtual|WSL'
    try {
        $cands = Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
            $_.NetAdapter.Status -eq 'Up' -and
            $_.IPv4Address -and
            $_.InterfaceAlias -notmatch $exclude -and
            $_.InterfaceDescription -notmatch $exclude
        }
        $withGw = $cands | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        $pick = $withGw
        if (-not $pick) { $pick = $cands | Select-Object -First 1 }
        if ($pick) { return ($pick.IPv4Address | Select-Object -First 1).IPAddress }
    } catch { }
    return ''
}

function Get-TailscaleIPv4 {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $exe)) { return '' }
    $ip = (& $exe ip -4 2>$null | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
    if ($ip) { return $ip.Trim() }
    return ''
}

function Show-Status {
    Write-Host ''
    $p = Get-TavernPid
    if ($p) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        $since = '?'
        if ($proc) { $since = $proc.StartTime.ToString('MM-dd HH:mm') }
        Write-Host '  酒馆状态 : ' -NoNewline; Write-Host '运行中' -ForegroundColor Green -NoNewline
        Write-Host "  (pid $p, 启动于 $since)"
    } else {
        Write-Host '  酒馆状态 : ' -NoNewline; Write-Host '未运行' -ForegroundColor Red
    }

    if ($Config.bridge.enabled) {
        $bp = Get-BridgePid
        if ($bp) {
            Write-Host '  生图桥   : ' -NoNewline; Write-Host '运行中' -ForegroundColor Green -NoNewline
            Write-Host "  (pid $bp, 端口 $BridgePort)"
        } else {
            Write-Host '  生图桥   : ' -NoNewline; Write-Host '未运行' -ForegroundColor Red -NoNewline
            Write-Host '  (点「启动」会一起拉起)'
        }
    }

    $lan = Get-LocalIPv4
    $ts = Get-TailscaleIPv4
    Write-Host "  酒馆目录 : $TavernDir"
    Write-Host "  node     : $NodeExe"
    if ($lan) { Write-Host "  本机访问 : http://${lan}:$Port" }
    Write-Host "  本机回环 : http://127.0.0.1:$Port"
    if ($ts) { Write-Host "  手机访问 : http://${ts}:$Port   (Tailscale)" } else { Write-Host '  手机访问 : (未检测到 Tailscale，可自行用局域网 IP)' }
    Write-Host "  日志目录 : $LogDir"
    Write-Host ''
}

function Start-Tavern {
    if (-not (Test-TavernDir $TavernDir)) {
        Write-Host "  x 酒馆目录无效：$TavernDir" -ForegroundColor Red
        Write-Host '    请在 config.json 里设置正确的 tavernDir（即含 server.js 的目录）' -ForegroundColor Yellow
        return
    }
    if (Get-TavernPid) { Write-Host '  它已经在运行了，不用重复启动。' -ForegroundColor Yellow; return }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $env:NODE_ENV = 'production'
    # 端口显式传给 server.js：config.json 里的 port 才是准的。
    # 不传的话端口只由酒馆自己的 config.yaml 决定，两边一旦对不上，
    # 状态永远显示「未运行」，点启动还会再拉起一个撞端口立刻退出的实例。
    Start-Process -FilePath $NodeExe -ArgumentList @('server.js', '--port', "$Port") -WorkingDirectory $TavernDir `
        -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
    Write-Host '  正在启动' -NoNewline
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 2
        Write-Host '.' -NoNewline
        $p = Get-TavernPid
        if ($p) {
            Write-Host ''
            Write-Host "  酒馆已启动 (pid $p)" -ForegroundColor Green
            Start-Bridge
            if (Get-BridgePid) { Write-Host "  生图桥已就绪 (pid $(Get-BridgePid))" -ForegroundColor Green }
            return
        }
    }
    Write-Host ''
    Write-Host '  x 启动失败，错误日志末尾：' -ForegroundColor Red
    Get-Content $ErrLog -Tail 15 -ErrorAction SilentlyContinue
}

function Stop-Tavern {
    $p = Get-TavernPid
    if (-not $p) { Write-Host '  它本来就没在运行。' -ForegroundColor Yellow; return }
    if (-not (Test-ProcLooksLike $p (Get-TavernPattern))) {
        Write-Host "  ! 端口 $Port 被 pid $p 占用，但它不像酒馆（不是 node server.js），我不会动它。" -ForegroundColor Red
        Write-Host '    如果确认要结束它，请自行在任务管理器里处理。' -ForegroundColor Yellow
        return
    }
    Write-Host "  正在停止酒馆 (pid $p) ..."
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    if ($TavernTask) { Stop-ScheduledTask -TaskName $TavernTask -ErrorAction SilentlyContinue }
    Stop-Bridge
    Start-Sleep -Seconds 2
    if (Get-TavernPid) { Write-Host '  ! 端口仍被占用，可能没杀干净，请再执行一次停止' -ForegroundColor Red }
    else { Write-Host '  已停止（手机现在连不上了，想玩再点「启动」）' -ForegroundColor Green }
}

function Start-Bridge {
    if (-not $Config.bridge.enabled) { return }
    if (Get-BridgePid) { return }
    if (-not (Test-Path $BridgeScriptPath)) {
        Write-Host "  ! 找不到生图桥脚本：$BridgeScriptPath" -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path $BridgeConfigPath)) {
        Write-Host "  ! 生图桥还没配置：$BridgeConfigPath" -ForegroundColor Yellow
        Write-Host '    复制 scripts/agnes-bridge.example.json 过去并填入 apiKey 即可。' -ForegroundColor Yellow
        return
    }
    $bridgeLogDir = Join-Path $ProjectDir 'logs'
    New-Item -ItemType Directory -Force -Path $bridgeLogDir | Out-Null
    Start-Process -FilePath $NodeExe -ArgumentList @($Config.bridge.script, '--config', $BridgeConfigPath) `
        -WorkingDirectory $ProjectDir -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $bridgeLogDir 'agnes-bridge.out.log') `
        -RedirectStandardError (Join-Path $bridgeLogDir 'agnes-bridge.err.log')
    for ($i = 1; $i -le 12; $i++) { Start-Sleep -Seconds 1; if (Get-BridgePid) { return } }
    # 12 秒还没起来，把错误日志亮出来，别让用户只看到一句「未运行」
    Write-Host '  ! 生图桥没能启动，错误日志末尾：' -ForegroundColor Red
    $berr = Join-Path $bridgeLogDir 'agnes-bridge.err.log'
    if (Test-Path $berr) { Get-Content $berr -Tail 12 } else { Write-Host "    (没有 err 日志，看看 $BridgeConfigPath 是否配好)" -ForegroundColor Yellow }
}

function Stop-Bridge {
    $bp = Get-BridgePid
    if (-not $bp) { return }
    if (-not (Test-ProcLooksLike $bp (Get-BridgePattern))) {
        Write-Host "  ! 端口 $BridgePort 被 pid $bp 占用，但它不是生图桥，跳过。" -ForegroundColor Yellow
        return
    }
    Stop-Process -Id $bp -Force -ErrorAction SilentlyContinue
    if ($BridgeTask) { Stop-ScheduledTask -TaskName $BridgeTask -ErrorAction SilentlyContinue }
}

function Show-Logs {
    Write-Host ''
    $access = Join-Path $TavernDir 'data\access.log'
    Write-Host '  --- 最近访问（data\access.log）---' -ForegroundColor Cyan
    if (Test-Path $access) { Get-Content $access -Tail 12 } else { Write-Host '  (还没有访问日志)' }
    Write-Host ''
    Write-Host '  --- 运行日志末尾 ---' -ForegroundColor Cyan
    if (Test-Path $OutLog) { Get-Content $OutLog -Tail 10 } else { Write-Host '  (还没有运行日志)' }
    if (Test-Path $ErrLog) {
        $err = Get-Content $ErrLog -Tail 6
        if ($err) { Write-Host ''; Write-Host '  --- 错误日志末尾 ---' -ForegroundColor DarkYellow; $err }
    }
    if ($Config.bridge.enabled) {
        $blog = Join-Path $ProjectDir 'logs'
        Write-Host ''
        Write-Host '  --- 生图桥日志末尾 ---' -ForegroundColor Cyan
        foreach ($f in @('agnes-bridge.log', 'agnes-bridge.out.log', 'agnes-bridge.err.log')) {
            $p = Join-Path $blog $f
            if (Test-Path $p) {
                $tail = Get-Content $p -Tail 8 -ErrorAction SilentlyContinue
                if ($tail) { Write-Host "  [$f]"; $tail }
            }
        }
    }
    Write-Host ''
}

function New-ConsoleShortcut {
    param([string]$Name, [string]$ScriptAction, [string]$Description, [string]$IconPath)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop ($Name + '.lnk')
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\st-console.ps1`" -Action $ScriptAction"
    $s.WorkingDirectory = $ProjectDir
    $s.Description = $Description
    if ($IconPath -and (Test-Path $IconPath)) { $s.IconLocation = $IconPath }
    $s.Save()
    return $lnk
}

function Install-Shortcuts {
    if (-not $Config.shortcuts.enabled) { Write-Host '  配置里已禁用快捷方式（shortcuts.enabled=false）' -ForegroundColor Yellow; return }
    $prefix = $Config.shortcuts.prefix
    $icon = Join-Path $TavernDir 'public\favicon.ico'
    $list = @(
        @{ Name = "$prefix Console"; Action = 'menu';  Desc = '启动/停止/查看酒馆状态' },
        @{ Name = "$prefix Start";   Action = 'start'; Desc = '启动酒馆' },
        @{ Name = "$prefix Stop";    Action = 'stop';  Desc = '停止酒馆' }
    )
    foreach ($it in $list) {
        $lnk = New-ConsoleShortcut -Name $it.Name -ScriptAction $it.Action -Description $it.Desc -IconPath $icon
        Write-Host "  已创建快捷方式: $lnk" -ForegroundColor Green
    }
    $petLnk = New-PetShortcut -Name "$prefix Pet" -Description '桌面小挂件：点一下弹按钮' -IconPath $icon
    Write-Host "  已创建快捷方式: $petLnk" -ForegroundColor Green
}

function New-PetShortcut {
    param([string]$Name, [string]$Description, [string]$IconPath)
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop ($Name + '.lnk')
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    # -WindowStyle Hidden 只用来藏掉控制台；桌宠窗口本身由脚本自己强制显示出来。
    $s.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptDir\st-pet.ps1`""
    $s.WorkingDirectory = $ProjectDir
    $s.Description = $Description
    if ($IconPath -and (Test-Path $IconPath)) { $s.IconLocation = $IconPath }
    $s.Save()
    return $lnk
}

function Install-Tasks {
    # 计划任务通过一个 .cmd 包装器启动，这样从任务启动的进程也会写日志（便于事后查死因）
    $logRoot = Join-Path $ProjectDir 'logs'
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    # cmd.exe 执行批处理用的是 OEM 代码页，不是 ANSI 的；写错了非 ASCII 路径会变成 "?"
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)

    if ($TavernTask) {
        $wrapper = Join-Path $logRoot 'run-tavern.cmd'
        # 日志目录用 if not exist 兜底建一次：cmd 打不开重定向目标时会整行不执行，
        # 于是 node 根本不跑、任务每登录一次失败一次（目录没了也一样）
        $content = "@echo off`r`ncd /d `"$TavernDir`"`r`nif not exist `"$LogDir`" mkdir `"$LogDir`"`r`n`"$NodeExe`" server.js --port $Port 1>>`"$OutLog`" 2>>`"$ErrLog`"`r`n"
        [IO.File]::WriteAllText($wrapper, $content, $oem)
        $a1 = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$wrapper`"" -WorkingDirectory $TavernDir
        $t1 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERNAME"
        $s1 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
        try {
            Register-ScheduledTask -TaskName $TavernTask -Action $a1 -Trigger $t1 -Settings $s1 -RunLevel Highest -Force -ErrorAction Stop | Out-Null
            Write-Host "  已注册计划任务（登录时启动酒馆，带日志）: $TavernTask" -ForegroundColor Green
            Write-Host "      包装器: $wrapper"
        } catch {
            Write-Host "  x 注册计划任务失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host '    注册开机自启需要管理员权限，请用「以管理员身份运行」再试。' -ForegroundColor Yellow
            $script:TaskInstallFailed = $true
        }
    }

    if ($Config.bridge.enabled -and $BridgeTask) {
        $bOut = Join-Path $logRoot 'agnes-bridge.out.log'
        $bErr = Join-Path $logRoot 'agnes-bridge.err.log'
        $wrapper2 = Join-Path $logRoot 'run-bridge.cmd'
        $content2 = "@echo off`r`ncd /d `"$ProjectDir`"`r`n`"$NodeExe`" `"$BridgeScriptPath`" --config `"$BridgeConfigPath`" 1>>`"$bOut`" 2>>`"$bErr`"`r`n"
        [IO.File]::WriteAllText($wrapper2, $content2, $oem)
        $a2 = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"$wrapper2`"" -WorkingDirectory $ProjectDir
        $t2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERNAME"
        $s2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
        try {
            Register-ScheduledTask -TaskName $BridgeTask -Action $a2 -Trigger $t2 -Settings $s2 -RunLevel Highest -Force -ErrorAction Stop | Out-Null
            Write-Host "  已注册计划任务（登录时启动生图桥，带日志）: $BridgeTask" -ForegroundColor Green
            Write-Host "      包装器: $wrapper2"
        } catch {
            Write-Host "  x 注册生图桥计划任务失败：$($_.Exception.Message)" -ForegroundColor Red
            $script:TaskInstallFailed = $true
        }
    }
}

function Show-ConfigInfo {
    Write-Host ''
    Write-Host "  配置文件 : $ConfigPath"
    Write-Host "  项目目录 : $ProjectDir"
    Write-Host "  酒馆目录 : $TavernDir"
    Write-Host "  node     : $NodeExe"
    Write-Host "  端口     : 酒馆 $Port / 生图桥 $BridgePort"
    Write-Host ''
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host '=========================================' -ForegroundColor Cyan
        Write-Host '        SillyTavern 控制台' -ForegroundColor Cyan
        Write-Host '=========================================' -ForegroundColor Cyan
        Show-Status
        Write-Host '  [1] 启动酒馆      [2] 停止酒馆'
        Write-Host '  [3] 重启酒馆      [4] 查看状态/访问地址'
        Write-Host '  [5] 查看日志      [6] 安装桌面快捷方式'
        Write-Host '  [7] 注册开机自启（计划任务）'
        Write-Host '  [8] 显示配置信息'
        Write-Host '  [0] 退出'
        Write-Host ''
        $c = Read-Host '  请输入数字后回车'
        switch ($c) {
            '1' { Start-Tavern; Write-Host ''; Read-Host '  按回车返回菜单' }
            '2' { Stop-Tavern; Write-Host ''; Read-Host '  按回车返回菜单' }
            '3' { Stop-Tavern; Start-Tavern; Write-Host ''; Read-Host '  按回车返回菜单' }
            '4' { Show-Status; Write-Host ''; Read-Host '  按回车返回菜单' }
            '5' { Show-Logs; Write-Host ''; Read-Host '  按回车返回菜单' }
            '6' { Install-Shortcuts; Write-Host ''; Read-Host '  按回车返回菜单' }
            '7' { Install-Tasks; Write-Host ''; Read-Host '  按回车返回菜单' }
            '8' { Show-ConfigInfo; Write-Host ''; Read-Host '  按回车返回菜单' }
            '0' { return }
            default { }
        }
    }
}

switch ($Action) {
    'none'              { }   # 只加载配置与函数，供 st-pet.ps1 点源复用
    'status'            { Show-Status }
    'where'             { Show-ConfigInfo }
    'logs'              { Show-Logs }
    'install-shortcuts' { Install-Shortcuts }
    # 失败要带非零退出码，否则 install.ps1 会照着「安装完成」继续往下报喜
    'install-tasks'     { Install-Tasks; if ($script:TaskInstallFailed) { exit 1 } }
    'bridge-start'      { Start-Bridge; Write-Host '  生图桥已处理' }
    'bridge-stop'       { Stop-Bridge; Write-Host '  生图桥已停止' }
    'start'             { Start-Tavern; Write-Host ''; if (-not $NoPause) { Read-Host '  按回车关闭窗口' } }
    'stop'              { Stop-Tavern; Write-Host ''; if (-not $NoPause) { Read-Host '  按回车关闭窗口' } }
    'restart'           { Stop-Tavern; Start-Tavern; Write-Host ''; if (-not $NoPause) { Read-Host '  按回车关闭窗口' } }
    default             { Show-Menu }
}
