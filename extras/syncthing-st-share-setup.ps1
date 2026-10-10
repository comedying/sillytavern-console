<#
  在“另一台电脑”上运行：把 Syncthing 的共享文件夹指向本机真实的 SillyTavern 数据目录
  ----------------------------------------------------------------------------------
  目的：让两台电脑的 SillyTavern 共享聊天记录 / 角色卡 / 世界书等（双向同步）。

  它会做：
    1. 定位本机 Syncthing 配置（或按参数指定）与 API Key
    2. 定位本机 SillyTavern 数据目录（或按参数指定）
    3. 把指定共享文件夹的路径改到该数据目录，并打开 staggered 版本保留（防误删）
    4. 写入 .stignore（排除易冲突/体积大/含密钥的项目）
    5. 补上 .stfolder 标记（Syncthing v2 必需，否则报 folder marker missing）
    6. 可选：给对端设备加固定地址（例如走 Tailscale 的 100.x.y.z）

  用法示例：
    powershell -ExecutionPolicy Bypass -File syncthing-st-share-setup.ps1
    powershell -ExecutionPolicy Bypass -File syncthing-st-share-setup.ps1 `
        -TavernDataDir "D:\SillyTavern\data\default-user" `
        -PeerDeviceID "KFRHOEI-JLRHV3C-6R2L22Y-MVJDGQK-7JYRCTF-QH4VT4N-ONOBC6P-XCIQTQS" `
        -PeerAddress "tcp://100.77.85.29:22000"

  注意：两台电脑不要同时编辑同一个聊天，否则会产生 *.sync-conflict-* 副本。
#>
param(
    [string]$TavernDataDir = '',
    [string]$SyncthingConfigDir = '',
    [string]$FolderId = 'sillytavern-chats',
    [string]$PeerDeviceID = '',
    [string]$PeerAddress = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "  $m" }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [X]  $m" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host '=== Syncthing ⇄ SillyTavern 数据共享 适配 ===' -ForegroundColor Cyan

# ---------------------------------------------------------------- 1. 找 Syncthing 配置
Write-Host ''
Write-Host '1) 定位 Syncthing 配置'

$configCandidates = @()
if ($SyncthingConfigDir) { $configCandidates += $SyncthingConfigDir }
$configCandidates += @(
    (Join-Path $env:LOCALAPPDATA 'Syncthing'),
    (Join-Path $env:APPDATA 'Syncthing'),
    'C:\ProgramData\Syncthing',
    'D:\Syncthing\config',
    'F:\Syncthing\config',
    'G:\Syncthing\config'
)
# 从正在运行的进程命令行里找 --home=
Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -match '--?home[= ]"?([^"]+)"?') { $configCandidates = @($Matches[1]) + $configCandidates }
}

$configPath = ''
foreach ($c in $configCandidates) {
    if ($c -and (Test-Path (Join-Path $c 'config.xml'))) { $configPath = (Join-Path $c 'config.xml'); break }
}
if (-not $configPath) { Fail "找不到 Syncthing 的 config.xml，请用 -SyncthingConfigDir 指定（例如 D:\Syncthing\config）" }
Ok "配置文件: $configPath"

[xml]$cfgXml = Get-Content $configPath -Raw
$apiKey = $cfgXml.configuration.gui.apikey
$guiAddress = $cfgXml.configuration.gui.address
if (-not $apiKey) { Fail '配置里没有 API Key' }
if ($guiAddress -match '^0\.0\.0\.0') { $guiAddress = $guiAddress -replace '^0\.0\.0\.0', '127.0.0.1' }
$api = "http://$guiAddress/rest"
Info "API: $api"
$headers = @{ 'X-API-Key' = $apiKey; 'Content-Type' = 'application/json' }

try { $null = Invoke-RestMethod -Uri "$api/system/status" -Headers $headers -TimeoutSec 8 }
catch { Fail "连不上本机 Syncthing API（$api）。请先启动 Syncthing 再运行本脚本。" }

# ---------------------------------------------------------------- 2. 找酒馆数据目录
Write-Host ''
Write-Host '2) 定位 SillyTavern 数据目录'

function Test-DataDir([string]$d) {
    if ([string]::IsNullOrWhiteSpace($d)) { return $false }
    return (Test-Path (Join-Path $d 'settings.json')) -or (Test-Path (Join-Path $d 'chats'))
}

if (-not (Test-DataDir $TavernDataDir)) {
    $found = ''
    $roots = @('C:', 'D:', 'E:', 'F:', 'G:')
    $cands = @()
    foreach ($r in $roots) {
        foreach ($n in @('SillyTavern', 'sillytavern', 'silly tavern')) { $cands += "$r\$n" }
        $cands += "$r\Program Files\SillyTavern"
    }
    foreach ($c in $cands) {
        $d = Join-Path $c 'data\default-user'
        if (Test-DataDir $d) { $found = $d; break }
    }
    if (-not $found) {
        foreach ($r in $roots) {
            if (-not (Test-Path "$r\")) { continue }
            Get-ChildItem "$r\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'tavern' } | ForEach-Object {
                $d = Join-Path $_.FullName 'data\default-user'
                if (-not $found -and (Test-DataDir $d)) { $found = $d }
            }
        }
    }
    $TavernDataDir = $found
}
if (-not (Test-DataDir $TavernDataDir)) {
    Fail ' 找不到酒馆数据目录，请用 -TavernDataDir "D:\SillyTavern\data\default-user" 指定'
}
Ok "酒馆数据目录: $TavernDataDir"

# ---------------------------------------------------------------- 3. 改文件夹路径
Write-Host ''
Write-Host '3) 调整 Syncthing 共享文件夹'

try { $folder = Invoke-RestMethod -Uri "$api/config/folders/$FolderId" -Headers $headers -TimeoutSec 10 }
catch { Fail "本机 Syncthing 里没有文件夹 id=$FolderId。请先在 Syncthing 网页里接受该文件夹的共享邀请，再运行本脚本。" }

Info "改前: path=$($folder.path)  label=$($folder.label)"
$oldPath = $folder.path
if ($folder.path -eq $TavernDataDir) {
    Ok '路径已经正确，无需修改'
} elseif ($DryRun) {
    Warn2 "[DryRun] 将把 $($folder.path) 改为 $TavernDataDir"
} else {
    $folder.path = $TavernDataDir
    $folder.label = 'SillyTavern 数据'
    $folder.type = 'sendreceive'
    $folder.versioning = @{ type = 'staggered'; params = @{ cleanoutDays = '0'; maxAge = '720h' } }
    $body = $folder | ConvertTo-Json -Depth 12 -Compress
    Invoke-RestMethod -Method Put -Uri "$api/config/folders/$FolderId" -Headers $headers -Body $body -TimeoutSec 20 | Out-Null
    Ok "已改为: $TavernDataDir（版本保留 staggered 30 天）"
}

# ---------------------------------------------------------------- 4. .stignore + 标记
Write-Host ''
Write-Host '4) 写入 .stignore 与文件夹标记'

$stignorePath = Join-Path $TavernDataDir '.stignore'
if ($DryRun) {
    Warn2 "[DryRun] 将写入 $stignorePath"
} else {
    @'
// ===== SillyTavern 数据同步 排除规则 =====
(?i)backups
(?i)extensions
(?i)vectors
(?i)assets
(?i)thumbnails
(?i)_cache
(?i)settings.json
(?i)settings.json.*
(?i)secrets.json
(?i)stats.json
(?i)content.log
(?i)*.sync-conflict-*
'@ | Set-Content -LiteralPath $stignorePath -Encoding UTF8
    Ok "已写入 $stignorePath"
}

$markerDir = Join-Path $TavernDataDir '.stfolder'
if (Test-Path $markerDir) {
    Ok '.stfolder 标记已存在'
} elseif ($DryRun) {
    Warn2 "[DryRun] 将创建 $markerDir"
} else {
    # 优先从旧路径复制（保留 Syncthing 自己的标记文件），否则新建目录
    $oldMarker = Join-Path $oldPath '.stfolder'
    if ($oldPath -and (Test-Path $oldMarker)) {
        Copy-Item -LiteralPath $oldMarker -Destination $markerDir -Recurse -Force
        Ok "已从旧路径复制标记: $oldMarker"
    } else {
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
        Ok "已创建标记目录: $markerDir"
    }
}

# ---------------------------------------------------------------- 5. 对端固定地址（可选）
if ($PeerDeviceID -and $PeerAddress) {
    Write-Host ''
    Write-Host '5) 给对端设备加固定地址'
    try {
        $devs = Invoke-RestMethod -Uri "$api/config/devices" -Headers $headers -TimeoutSec 10
        $peer = $devs | Where-Object { $_.deviceID -eq $PeerDeviceID }
        if ($peer) {
            if ($peer.addresses -notcontains $PeerAddress) {
                $peer.addresses = @($peer.addresses) + $PeerAddress
                $pb = $peer | ConvertTo-Json -Depth 8 -Compress
                Invoke-RestMethod -Method Put -Uri "$api/config/devices/$PeerDeviceID" -Headers $headers -Body $pb -TimeoutSec 20 | Out-Null
                Ok "已添加固定地址 $PeerAddress"
            } else { Ok '固定地址已存在' }
        } else { Warn2 '对端设备不在本机配置里（先在网页里接受它的连接）' }
    } catch { Warn2 "加固定地址失败: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 6. 触发扫描 + 看状态
Write-Host ''
Write-Host '6) 触发扫描并查看状态'
if (-not $DryRun) {
    try { Invoke-RestMethod -Method Post -Uri "$api/db/scan?folder=$FolderId" -Headers $headers -TimeoutSec 20 | Out-Null } catch { }
    Start-Sleep -Seconds 6
    try {
        $st = Invoke-RestMethod -Uri "$api/db/status?folder=$FolderId" -Headers $headers -TimeoutSec 15
        Info "state=$($st.state)  localFiles=$($st.localFiles)  localBytes=$([math]::Round($st.localBytes/1MB,1))MB  needFiles=$($st.needFiles)"
        if ($st.state -eq 'error') { Warn2 '文件夹仍处于 error 状态，请到 Syncthing 网页查看具体报错' }
    } catch { Warn2 "查询状态失败: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host '完成。下一步：' -ForegroundColor Green
Write-Host '  - 打开 Syncthing 网页确认文件夹已同步（正在接收另一台电脑的数据）'
Write-Host '  - 两台电脑都会看到同一份聊天记录/角色卡/世界书'
Write-Host '  - 注意：不要两台同时编辑同一个聊天，冲突会产生 *.sync-conflict-* 副本'
Write-Host ''
