<#
  install.ps1 — SillyTavern 控制台 一键安装
  ------------------------------------------------------------
  做的事：
    1. 生成 config.json（自动探测酒馆目录与 node.exe）
    2. 准备生图桥配置 .secrets/agnes-bridge.json（从示例复制）
    3. 创建桌面快捷方式（可在配置里关掉）
    4. 注册登录自启计划任务（可 -NoTasks 跳过）

  用法示例：
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -TavernDir "D:\SillyTavern" -Port 8000
    powershell -ExecutionPolicy Bypass -File install.ps1 -NoTasks -NoShortcuts -NoBridge

  本脚本不会修改 SillyTavern 自身的任何文件。
#>
param(
    [string]$TavernDir = '',
    [int]$Port = 0,
    [switch]$NoShortcuts,
    [switch]$NoTasks,
    [switch]$NoBridge
)

$ErrorActionPreference = 'Continue'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ProjectDir 'config.json'
$ExampleConfig = Join-Path $ProjectDir 'config.example.json'
$ConsoleScript = Join-Path $ProjectDir 'scripts\st-console.ps1'
$BridgeExample = Join-Path $ProjectDir 'scripts\agnes-bridge.example.json'

function Write-Head($t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Write-Err2($t) { Write-Host "  [X]  $t" -ForegroundColor Red }

Write-Host '=========================================' -ForegroundColor Cyan
Write-Host '   SillyTavern 控制台 · 安装' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. 前置检查
Write-Head '1/5 环境检查'

if (-not (Test-Path $ConsoleScript)) {
    Write-Err2 "找不到主脚本：$ConsoleScript"
    exit 1
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Write-Ok "node: $($node.Source)" }
else {
    $nodeCandidates = @("$env:ProgramFiles\nodejs\node.exe", 'D:\nodejs\node.exe', 'C:\nodejs\node.exe')
    $found = $nodeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { Write-Ok "node: $found" } else { Write-Warn2 '没检测到 node，可在 config.json 里手写 nodeExe 路径' }
}

# ---------------------------------------------------------------- 2. 探测酒馆目录
Write-Head '2/5 定位 SillyTavern 目录'

function Test-Tavern([string]$d) {
    if ([string]::IsNullOrWhiteSpace($d)) { return $false }
    return ((Test-Path $d) -and (Test-Path (Join-Path $d 'server.js')))
}

$detected = ''
if (-not (Test-Tavern $TavernDir)) {
    $roots = @('C:', 'D:', 'E:', 'F:', 'G:')
    $cands = @()
    foreach ($r in $roots) {
        foreach ($n in @('SillyTavern', 'sillytavern', 'silly tavern')) { $cands += "$r\$n" }
        $cands += "$r\Program Files\SillyTavern"
    }
    $cands += (Join-Path $env:USERPROFILE 'SillyTavern')
    $cands += (Join-Path $env:LOCALAPPDATA 'SillyTavern')
    foreach ($r in $roots) {
        if (-not (Test-Path "$r\")) { continue }
        Get-ChildItem "$r\" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'tavern' } | ForEach-Object { $cands += $_.FullName }
    }
    $valid = $cands | Sort-Object -Unique | Where-Object { Test-Tavern $_ } | ForEach-Object {
        $settings = Join-Path $_ 'data\default-user\settings.json'
        $hasData = Test-Path $settings
        $mtime = [datetime]'1970-01-01'
        if ($hasData) { $mtime = (Get-Item $settings).LastWriteTime }
        [pscustomobject]@{ Path = $_; HasData = $hasData; Mtime = $mtime }
    } | Sort-Object HasData, Mtime -Descending
    if ($valid) {
        $detected = $valid[0].Path
        if ($valid.Count -gt 1) {
            Write-Warn2 "发现多个酒馆副本，已选最近使用的：$detected"
            $valid | Select-Object -Skip 1 | ForEach-Object { Write-Warn2 "  忽略：$($_.Path)" }
        }
    }
}

if (Test-Tavern $TavernDir) { Write-Ok "使用参数指定的目录：$TavernDir" }
elseif ($detected) { $TavernDir = $detected; Write-Ok "自动探测到：$TavernDir" }
else {
    if (Test-Path $ConfigPath) {
        $old = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (Test-Tavern $old.tavernDir) { $TavernDir = $old.tavernDir; Write-Ok "沿用已有配置：$TavernDir" }
    }
}
if (-not (Test-Tavern $TavernDir)) {
    Write-Warn2 '没找到酒馆目录（需要是含 server.js 的那个目录）'
    Write-Warn2 '安装继续，但请编辑 config.json 里的 tavernDir，例如：'
    Write-Warn2 '  "tavernDir": "D:\\\\SillyTavern"'
    if (-not $TavernDir) { $TavernDir = 'C:\SillyTavern' }
}

# ---------------------------------------------------------------- 3. 写配置
Write-Head '3/5 生成 config.json'

if (Test-Path $ConfigPath) {
    Write-Warn2 'config.json 已存在，保留原有配置（只更新本次显式传入的项）'
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $cfg = Get-Content $ExampleConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Ok '已从 config.example.json 生成'
}

$cfg.tavernDir = $TavernDir
if ($Port -gt 0) { $cfg.port = $Port }
if ($node) { $cfg.nodeExe = $node.Source }
if ($NoBridge) { $cfg.bridge.enabled = $false }
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Ok "写入：$ConfigPath"

# ---------------------------------------------------------------- 4. 生图桥配置
Write-Head '4/5 生图桥配置（可选功能）'

if ($NoBridge -or -not $cfg.bridge.enabled) {
    Write-Warn2 '已跳过（bridge.enabled = false）'
} else {
    $secretsDir = Join-Path $ProjectDir '.secrets'
    New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
    $bridgeCfg = Join-Path $ProjectDir $cfg.bridge.configFile
    if (Test-Path $bridgeCfg) {
        Write-Ok "已存在：$bridgeCfg"
    } else {
        Copy-Item -LiteralPath $BridgeExample -Destination $bridgeCfg
        Write-Ok "已创建：$bridgeCfg"
        Write-Warn2 '记得打开它，把 apiKey 换成你自己的（该文件已被 .gitignore 忽略）'
    }
}

# ---------------------------------------------------------------- 5. 快捷方式与任务
Write-Head '5/5 快捷方式与开机自启'

$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$script:StepFailed = $false

if ($NoShortcuts) { Write-Warn2 '已跳过桌面快捷方式（-NoShortcuts）' }
else {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $ConsoleScript -Action install-shortcuts
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "桌面快捷方式创建失败（退出码 $LASTEXITCODE）"; $script:StepFailed = $true }
}

if ($NoTasks) { Write-Warn2 '已跳过计划任务（-NoTasks）' }
else {
    # 注册计划任务要管理员权限；失败必须让用户知道，否则会以为自启已经装好
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $ConsoleScript -Action install-tasks
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "开机自启注册失败（退出码 $LASTEXITCODE）——多半是没以管理员身份运行"
        Write-Warn2 '  自启没装上，但其它都装好了；需要的话用管理员 PowerShell 再跑一次本脚本'
        $script:StepFailed = $true
    }
}

# ---------------------------------------------------------------- 收尾
Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
if ($script:StepFailed) {
    Write-Host '   安装完成（有步骤失败，见上面的 [!]）' -ForegroundColor Yellow
} else {
    Write-Host '   安装完成' -ForegroundColor Green
}
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  下一步：'
Write-Host '   1) 双击桌面快捷方式「* Console」，或运行：'
Write-Host "      powershell -ExecutionPolicy Bypass -File `"$ConsoleScript`" -Action menu"
Write-Host '   2) 在菜单里按 [1] 启动酒馆'
Write-Host '   3) 想让手机也能玩：安装 Tailscale 并登录同一账号，'
Write-Host '      控制台状态里会自动显示 http://<tailscale-ip>:<port>'
Write-Host '   4) 想用生图桥：填好 .secrets/agnes-bridge.json 的 apiKey，'
Write-Host '      然后在酒馆「图像生成」里把源设为 Stable Diffusion Web UI (AUTOMATIC1111)，'
Write-Host "      地址填 http://127.0.0.1:$($cfg.bridge.port)"
Write-Host ''
