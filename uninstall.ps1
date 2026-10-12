<#
  uninstall.ps1 — SillyTavern 控制台 卸载
  ------------------------------------------------------------
  默认只做“无痕卸载”：
    - 删除本工具创建的桌面快捷方式
    - 注销本工具注册的计划任务
    - 停止由本工具启动的进程（酒馆 / 生图桥）

  加 -Purge 才会额外删除 config.json、.secrets\、logs\（这些是本地私有数据）。
  本脚本绝不触碰 SillyTavern 自身的目录与数据。
#>
param(
    [switch]$Purge,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ProjectDir 'config.json'
$ConsoleScript = Join-Path $ProjectDir 'scripts\st-console.ps1'

function Write-Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [!]  $t" -ForegroundColor Yellow }

$port = 8000
$bridgePort = 7861
$tavernTask = 'SillyTavern-AutoStart'
$bridgeTask = 'Agnes-SDBridge-AutoStart'
$prefix = 'Tavern'

if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.port) { $port = [int]$cfg.port }
        if ($cfg.bridge.port) { $bridgePort = [int]$cfg.bridge.port }
        if ($cfg.tasks.tavern) { $tavernTask = $cfg.tasks.tavern }
        if ($cfg.tasks.bridge) { $bridgeTask = $cfg.tasks.bridge }
        if ($cfg.shortcuts.prefix) { $prefix = $cfg.shortcuts.prefix }
    } catch { Write-Warn2 "config.json 读取失败，使用默认值：$($_.Exception.Message)" }
}

Write-Host '== 停止进程'
# 先看桌宠（它自己记着 pid）
$petPidFile = Join-Path $ProjectDir 'logs\pet.pid'
if (Test-Path $petPidFile) {
    $pp = (Get-Content $petPidFile -Raw -ErrorAction SilentlyContinue)
    if ($pp -and $pp.Trim() -match '^\d+$') {
        $pp = [int]$pp.Trim()
        if (Get-Process -Id $pp -ErrorAction SilentlyContinue) {
            Stop-Process -Id $pp -Force -ErrorAction SilentlyContinue
            Write-Ok "已停止桌宠 (pid $pp)"
        }
    }
    Remove-Item -LiteralPath $petPidFile -Force -ErrorAction SilentlyContinue
}

# 端口上的进程要核对身份再杀：8000 / 7861 很常见，别把别人占着的程序干掉
function Test-PortOwnerIsOurs([int]$ProcId) {
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop
        if (-not $ci) { return $false }
        if ($ci.Name -notmatch '^(node|nodejs)\.exe$') { return $false }
        if ([string]::IsNullOrWhiteSpace($ci.CommandLine)) { return $false }
        return ($ci.CommandLine -like '*server.js*' -or $ci.CommandLine -like '*agnes-sd-bridge*' -or $ci.CommandLine -like "*$ProjectDir*")
    } catch { return $false }
}
foreach ($p in @($port, $bridgePort)) {
    $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) {
        if (Test-PortOwnerIsOurs $c.OwningProcess) {
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Ok "已停止端口 $p 上的进程 (pid $($c.OwningProcess))"
        } else {
            Write-Warn2 "端口 $p 被 pid $($c.OwningProcess) 占用，但它不像是本工具启动的 node，已跳过"
        }
    }
}

Write-Host '== 注销计划任务'
foreach ($t in @($tavernTask, $bridgeTask)) {
    if ($t -and (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "已注销 $t"
    }
}

Write-Host '== 删除快捷方式'
$desktop = [Environment]::GetFolderPath('Desktop')
Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    $sh = New-Object -ComObject WScript.Shell
    $target = ''
    try { $target = $sh.CreateShortcut($_.FullName).Arguments } catch { }
    if ($target -like "*st-console.ps1*" -or $target -like "*st-pet.ps1*") {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Ok "已删除 $($_.Name)"
    }
}
# 兜底：按配置前缀名字删（含桌宠）
foreach ($n in @("$prefix Console", "$prefix Start", "$prefix Stop", "$prefix Pet")) {
    $lnk = Join-Path $desktop ($n + '.lnk')
    if (Test-Path $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Ok "已删除 $n.lnk" }
}

if ($Purge) {
    Write-Host '== 清理本地私有数据 (-Purge)'
    if (-not $Force) {
        $ans = Read-Host '  将删除 config.json / .secrets / logs，确认？输入 yes 继续'
        if ($ans -ne 'yes') { Write-Warn2 '已取消数据清理'; exit 0 }
    }
    foreach ($item in @('config.json', '.secrets', 'logs')) {
        $full = Join-Path $ProjectDir $item
        # 安全校验：必须位于本项目目录内
        $resolvedParent = Split-Path -Parent $full
        if ($resolvedParent -ne $ProjectDir) { Write-Warn2 "跳过可疑路径：$full"; continue }
        if (Test-Path $full) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "已删除 $item"
        }
    }
}

Write-Host ''
Write-Host '卸载完成。SillyTavern 本身的目录与聊天数据未被改动。' -ForegroundColor Green
