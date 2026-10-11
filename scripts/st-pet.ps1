<#
  SillyTavern 控制台 - 桌宠版
  ------------------------------------------------------------
  一只常驻桌面的小人（默认用酒馆自带的 Seraphina），点一下弹出气泡，
  气泡里是按钮：启动 / 停止 / 重启 / 生图桥 / 打开 / 更多 / 设置。

  参考 DeepSeek-Balance-Whale-Widget 的做法，加了这几样：
    - 按压会有 Q 弹反馈（挤扁再弹回来），可关
    - 按压 / 松开 / 启动 / 停止 各有音效，可调音量、可关
    - 拖到屏幕边上自动吸附，吸附在左边时会左右翻转
    - 气泡里带一个「设置」页：大小、透明度、音量、弹跳、吸附、换角色形象
    - 状态直接反映在小人身上：未运行=失落，启动中=紧张，运行中=开心，停止中=沮丧

  用法：
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File scripts\st-pet.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\st-pet.ps1 -Stop

  形象：
    默认直接读酒馆自己的角色图（<酒馆目录>\default\content\Seraphina\*.png），
    所以仓库里不含任何图片。想换形象：
      · 直接点气泡里的「设置 → 换形象…」选一张 PNG，设置会存下来；
      · 或者在 config.json 里写 "pet": { "imageDir": "D:\\我的图\\q版" }，
        目录里按 joy / sadness / nervousness / disappointment / fear / neutral 命名，
        就能按状态换表情；缺哪个用 neutral 顶上。

  音效：
    第一次运行会在 <项目目录>\assets\sounds\ 下生成 4 个很小的 WAV。
    想换成自己的声音，直接覆盖同名文件即可（keep the same filenames）。

  设置保存在 <项目目录>\pet-settings.json（已加进 .gitignore，不会进仓库）。

  编码：本文件为 UTF-8 with BOM。
#>
param(
    [string]$ConfigPath = '',
    [switch]$Stop
)

$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ProjectDir 'config.json' }

$ConsoleScript = Join-Path $ScriptDir 'st-console.ps1'
$PetPidFile = Join-Path $ProjectDir 'logs\pet.pid'
$PetPosFile = Join-Path $ProjectDir 'logs\pet.pos'
$PetCfgFile = Join-Path $ProjectDir 'pet-settings.json'
$SfxDir = Join-Path $ProjectDir 'assets\sounds'

# ------------------------------------------------------------------ -Stop
if ($Stop) {
    if (Test-Path $PetPidFile) {
        $old = (Get-Content -LiteralPath $PetPidFile -Raw).Trim()
        if ($old -match '^\d+$') {
            Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue
            Write-Host "  已关闭桌宠 (pid $old)" -ForegroundColor Green
        }
        Remove-Item -LiteralPath $PetPidFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '  桌宠没有在运行。' -ForegroundColor Yellow
    }
    return
}

. $ConsoleScript -Action none -ConfigPath $ConfigPath

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
} catch {
    Write-Host "  x 无法加载 WPF：$($_.Exception.Message)" -ForegroundColor Red
    return
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host '  ! 需要在 STA 线程下运行，正在用 -STA 重新启动…' -ForegroundColor Yellow
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', $MyInvocation.MyCommand.Path, '-ConfigPath', $ConfigPath)
    return
}

try {
    Add-Type -Namespace StPet -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $h = [StPet.Native]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [StPet.Native]::ShowWindow($h, 0) | Out-Null }
} catch { }

# ---------------------------------------------------------------- 设置
# 默认值来自 config.json 的 pet 段，用户改动写进 pet-settings.json
$Defaults = [ordered]@{
    width        = 212
    customImage  = ''
    imageDir     = ''
    opacity      = 0.78
    fadeWhenIdle = $true
    bounce       = $true
    snapEdge     = $true
    sfx          = $true
    volume       = 0.7
}
if ($Config['pet']) {
    foreach ($k in @($Config['pet'].Keys)) {
        if ($Defaults.Contains([string]$k)) { $Defaults[[string]$k] = $Config['pet'][$k] }
    }
}
$S = $Defaults
if (Test-Path -LiteralPath $PetCfgFile) {
    try {
        $saved = Get-Content -LiteralPath $PetCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($saved.PSObject.Properties.Name)) {
            if ($Defaults.Contains([string]$k)) { $S[[string]$k] = $saved.$k }
        }
    } catch { }
}

function Save-PetSettings {
    try {
        $S | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PetCfgFile -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 音效
function New-WavFile([string]$path, [double]$f0, [double]$f1, [int]$ms, [double]$amp) {
    if (Test-Path -LiteralPath $path) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $rate = 44100
    $n = [int]($rate * $ms / 1000.0)
    $fs = [System.IO.File]::Create($path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $data = $n * 2
    $bw.Write([char[]]'RIFF'); $bw.Write([int](36 + $data)); $bw.Write([char[]]'WAVE')
    $bw.Write([char[]]'fmt '); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([char[]]'data'); $bw.Write([int]$data)
    $phase = 0.0
    $twoPi = 2.0 * [Math]::PI
    for ($i = 0; $i -lt $n; $i++) {
        $p = $i / [double]$n
        $f = $f0 + ($f1 - $f0) * $p
        $phase += $twoPi * $f / $rate
        $attack = [Math]::Min(1.0, $i / [double]([Math]::Max(1, [int]($rate * 0.004))))
        $env = $attack * [Math]::Pow(1.0 - $p, 2.2)
        $s = [Math]::Sin($phase) * $env * $amp
        $bw.Write([int16]([Math]::Round($s * 32000)))
    }
    $bw.Flush(); $bw.Close(); $fs.Close()
}

$SfxSpec = [ordered]@{
    press   = @(780, 560, 70, 0.55)
    release = @(1150, 900, 55, 0.38)
    start   = @(520, 1320, 190, 0.50)
    stop    = @(1100, 420, 200, 0.50)
}
foreach ($k in $SfxSpec.Keys) {
    $sp = $SfxSpec[$k]
    New-WavFile (Join-Path $SfxDir "$k.wav") $sp[0] $sp[1] $sp[2] $sp[3]
}

$SfxPlayers = @{}
function Get-SfxPlayer([string]$name) {
    if ($SfxPlayers.ContainsKey($name)) { return $SfxPlayers[$name] }
    $file = Join-Path $SfxDir "$name.wav"
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $mp = New-Object System.Windows.Media.MediaPlayer
        $mp.Open((New-Object System.Uri($file)))
        $mp.Volume = [double]$S['volume']
        $SfxPlayers[$name] = $mp
        return $mp
    } catch { return $null }
}

function Play-Sfx([string]$name) {
    if (-not [bool]$S['sfx']) { return }
    try {
        $pl = Get-SfxPlayer $name
        if (-not $pl) { return }
        $pl.Volume = [double]$S['volume']
        $pl.Position = [TimeSpan]::Zero
        $pl.Play()
    } catch { }
}

# ---------------------------------------------------------------- 形象
function Resolve-PetImageDir {
    if ($S['imageDir'] -and (Test-Path -LiteralPath $S['imageDir'])) { return $S['imageDir'] }
    foreach ($c in @((Join-Path $TavernDir 'default\content\Seraphina'),
            (Join-Path $TavernDir 'public\img\default-expressions'))) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return ''
}

$PetImageDir = Resolve-PetImageDir
$ExprMap = [ordered]@{
    idle     = @('neutral', 'curiosity')
    running  = @('joy', 'excitement', 'optimism')
    starting = @('nervousness', 'curiosity')
    stopping = @('disappointment', 'sadness')
}
$PetBitmap = @{}
function Get-PetBitmap([string]$state) {
    # 自定义单图优先
    if ($S['customImage'] -and (Test-Path -LiteralPath $S['customImage'])) {
        $key = [string]$S['customImage']
    } else {
        if (-not $PetImageDir) { return $null }
        $names = $ExprMap[$state]; if (-not $names) { $names = $ExprMap['idle'] }
        $key = ''
        foreach ($n in $names) {
            $hit = Get-ChildItem -LiteralPath $PetImageDir -Filter "$n.png" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $key = $hit.FullName; break }
        }
        if (-not $key) {
            $any = Get-ChildItem -LiteralPath $PetImageDir -Filter '*.png' -File -ErrorAction SilentlyContinue |
                Sort-Object { if ($_.Name -match 'neutral') { 0 } else { 1 } } | Select-Object -First 1
            if ($any) { $key = $any.FullName }
        }
        if (-not $key) { return $null }
    }
    if ($PetBitmap.ContainsKey($key)) { return $PetBitmap[$key] }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.UriSource = New-Object System.Uri($key)
        $bmp.EndInit()
        $bmp.Freeze()
        $PetBitmap[$key] = $bmp
        return $bmp
    } catch { return $null }
}

# ---------------------------------------------------------------- 界面
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SillyTavern Pet" Width="250" Height="322"
        WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual"
        FontFamily="Microsoft YaHei UI, Segoe UI" TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="30"/><Setter Property="Margin" Value="2.5"/>
      <Setter Property="FontSize" Value="11.5"/><Setter Property="Padding" Value="0"/>
      <Setter Property="MinWidth" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/><Setter Property="Foreground" Value="#E9EBFA"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="9" Background="#26FFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#40FFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#5CFFFFFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.32"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#08131A"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="9" BorderThickness="1" BorderBrush="#8FA6FF">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#6B7BFF" Offset="0"/><GradientStop Color="#22D3EE" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.32"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="Height" Value="22"/><Setter Property="MinWidth" Value="0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C8CDE8"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,4,12,0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#9AA0C0"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <StackPanel VerticalAlignment="Bottom" Background="{x:Null}">
    <Border x:Name="bubble" Visibility="Collapsed" Margin="4,0,4,8" CornerRadius="14"
            Background="#F0141730" BorderBrush="#5C6B7BFF" BorderThickness="1.2" Padding="12,10,12,10">
      <Grid>
        <!-- 第一页：控制 -->
        <StackPanel x:Name="pageMain">
          <DockPanel>
            <TextBlock x:Name="bTitle" Text="SillyTavern" FontSize="13" FontWeight="Bold"
                       Foreground="#EEF0FB" DockPanel.Dock="Left" VerticalAlignment="Center"/>
            <TextBlock x:Name="bSub" Text="" FontSize="10.5" Foreground="#8E93B4"
                       HorizontalAlignment="Right" Margin="8,4,0,0"/>
          </DockPanel>
          <TextBlock x:Name="bLine1" Text="" FontSize="11.5" Foreground="#B9BEDC" Margin="0,7,0,0" TextWrapping="Wrap"/>
          <TextBlock x:Name="bLine2" Text="" FontSize="11.5" Foreground="#8E93B4" Margin="0,2,0,0" TextWrapping="Wrap"/>
          <UniformGrid Columns="3" Margin="0,9,0,0">
            <Button x:Name="btnStart"   Style="{StaticResource BtnPrimary}" Content="启动"/>
            <Button x:Name="btnStop"    Style="{StaticResource Btn}"        Content="停止"/>
            <Button x:Name="btnRestart" Style="{StaticResource Btn}"        Content="重启"/>
          </UniformGrid>
          <UniformGrid Columns="3" Margin="0,1,0,0">
            <Button x:Name="btnBridge" Style="{StaticResource Btn}" Content="生图桥"/>
            <Button x:Name="btnOpen"   Style="{StaticResource Btn}" Content="打开"/>
            <Button x:Name="btnMore"   Style="{StaticResource Btn}" Content="更多"/>
          </UniformGrid>
          <UniformGrid Columns="1" Margin="0,1,0,0">
            <Button x:Name="btnSettings" Style="{StaticResource Btn}" Content="设置"/>
          </UniformGrid>
        </StackPanel>

        <!-- 第二页：设置 -->
        <StackPanel x:Name="pageSettings" Visibility="Collapsed">
          <DockPanel>
            <TextBlock Text="设置" FontSize="13" FontWeight="Bold" Foreground="#EEF0FB"
                       DockPanel.Dock="Left" VerticalAlignment="Center"/>
            <TextBlock Text="即时生效" FontSize="10" Foreground="#8E93B4"
                       HorizontalAlignment="Right" Margin="8,4,0,0"/>
          </DockPanel>

          <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="56"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="大小" Style="{StaticResource Lbl}"/>
            <Slider x:Name="sldSize" Grid.Column="1" Minimum="140" Maximum="380" TickFrequency="4"/>
            <TextBlock x:Name="lblSize" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
          </Grid>
          <Grid Margin="0,4,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="56"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="不透明度" Style="{StaticResource Lbl}"/>
            <Slider x:Name="sldOpacity" Grid.Column="1" Minimum="0.25" Maximum="1.0"/>
            <TextBlock x:Name="lblOpacity" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
          </Grid>
          <Grid Margin="0,4,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="56"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="音量" Style="{StaticResource Lbl}"/>
            <Slider x:Name="sldVolume" Grid.Column="1" Minimum="0" Maximum="1.0"/>
            <TextBlock x:Name="lblVolume" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
          </Grid>

          <WrapPanel Margin="0,8,0,0">
            <CheckBox x:Name="chkSfx" Content="音效"/>
            <CheckBox x:Name="chkBounce" Content="Q弹"/>
            <CheckBox x:Name="chkSnap" Content="吸附边缘"/>
          </WrapPanel>

          <UniformGrid Columns="2" Margin="0,8,0,0">
            <Button x:Name="btnPick"  Style="{StaticResource Btn}" Content="换形象…"/>
            <Button x:Name="btnReset" Style="{StaticResource Btn}" Content="恢复默认"/>
          </UniformGrid>
          <UniformGrid Columns="2" Margin="0,1,0,0">
            <Button x:Name="btnTest" Style="{StaticResource Btn}" Content="试听音效"/>
            <Button x:Name="btnBack" Style="{StaticResource Btn}" Content="返回"/>
          </UniformGrid>
        </StackPanel>
      </Grid>
    </Border>

    <Grid x:Name="petHost" Background="#01000000">
      <Image x:Name="pet" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Bottom"
             RenderTransformOrigin="0.5,1">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="petScale" ScaleX="1" ScaleY="1"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>
      <Border x:Name="badge" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="8,0,0,10"
              CornerRadius="9" Background="#D20E1024" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="7,3,7,3">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="dot" Width="7" Height="7" Fill="#F43F5E" VerticalAlignment="Center"/>
          <TextBlock x:Name="badgeText" Text="未运行" FontSize="10.5" Foreground="#C8CDE8"
                     Margin="5,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
    </Grid>
  </StackPanel>
</Window>
'@

try {
    $win = [System.Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-Host "  x 界面创建失败：$($_.Exception.Message)" -ForegroundColor Red
    return
}

$g = { param($n) $win.FindName($n) }
$bubble = & $g 'bubble'; $pageMain = & $g 'pageMain'; $pageSettings = & $g 'pageSettings'
$petHost = & $g 'petHost'; $petImg = & $g 'pet'; $petScale = & $g 'petScale'
$badgeText = & $g 'badgeText'; $dot = & $g 'dot'
$bTitle = & $g 'bTitle'; $bSub = & $g 'bSub'; $bLine1 = & $g 'bLine1'; $bLine2 = & $g 'bLine2'
$btnStart = & $g 'btnStart'; $btnStop = & $g 'btnStop'; $btnRestart = & $g 'btnRestart'
$btnBridge = & $g 'btnBridge'; $btnOpen = & $g 'btnOpen'; $btnMore = & $g 'btnMore'
$btnSettings = & $g 'btnSettings'; $btnBack = & $g 'btnBack'; $btnPick = & $g 'btnPick'
$btnReset = & $g 'btnReset'; $btnTest = & $g 'btnTest'
$sldSize = & $g 'sldSize'; $sldOpacity = & $g 'sldOpacity'; $sldVolume = & $g 'sldVolume'
$lblSize = & $g 'lblSize'; $lblOpacity = & $g 'lblOpacity'; $lblVolume = & $g 'lblVolume'
$chkSfx = & $g 'chkSfx'; $chkBounce = & $g 'chkBounce'; $chkSnap = & $g 'chkSnap'

$script:PetH = 321
$script:PetBaseTop = 0
$script:PetExpanded = $false
$script:PetState = ''
$script:BusyUntil = [DateTime]::MinValue
$script:BusyLook = 'starting'
$script:SetupDone = $false

function Apply-PetSize {
    $oldPetH = $script:PetH
    $w = [int]$S['width']
    if ($w -lt 140) { $w = 140 }
    if ($w -gt 380) { $w = 380 }
    $S['width'] = $w
    $script:PetH = [int][Math]::Round($w * 920 / 608)
    $winW = [Math]::Max($w, 252)
    $win.Width = $winW
    $petHost.Width = $winW
    $petHost.Height = $script:PetH
    $petImg.Width = $w
    $petImg.Height = $script:PetH
    $lblSize.Text = "$w"

    if ($script:PetExpanded) {
        # 气泡开着的时候改大小：把窗口上缘（也就是气泡）钉死不动，让小人往下长。
        # 否则窗口下缘不动、小人往上长，气泡会被一起顶上去，跑离鼠标，
        # 拖大小滑块时手感和「一边拖一边躲」一样。
        $bh = $win.Height - $oldPetH
        if ($bh -lt 0) { $bh = 0 }
        $win.Height = $script:PetH + $bh
    } else {
        # 收起状态：脚底不动，往上长
        $win.Top = $win.Top + ($oldPetH - $script:PetH)
        $script:PetBaseTop = [int]$win.Top
        $win.Height = $script:PetH
    }
}

function Apply-PetOpacity {
    if ([bool]$S['fadeWhenIdle'] -and -not $script:PetExpanded -and -not $win.IsMouseOver) {
        $win.Opacity = [double]$S['opacity']
    } else {
        $win.Opacity = 1.0
    }
    $lblOpacity.Text = ("{0}%" -f [int]([double]$S['opacity'] * 100))
}

# ---------------------------------------------------------------- Q 弹反馈
function Invoke-Squash([double]$sx, [double]$sy, [int]$ms, [bool]$elastic) {
    if (-not [bool]$S['bounce']) { return }
    try {
        foreach ($pair in @(@('ScaleX', $sx), @('ScaleY', $sy))) {
            $prop = if ($pair[0] -eq 'ScaleX') { [System.Windows.Media.ScaleTransform]::ScaleXProperty }
                    else { [System.Windows.Media.ScaleTransform]::ScaleYProperty }
            $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
            $anim.To = [double]$pair[1]
            $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms))
            if ($elastic) {
                $e = New-Object System.Windows.Media.Animation.BackEase
                $e.Amplitude = 0.55
                $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
                $anim.EasingFunction = $e
            }
            $petScale.BeginAnimation($prop, $anim)
        }
    } catch { }
}

# 点击的 Q 弹分三步：按下挤扁 -> 松手拉长 -> 带过冲地回弹落定。
# 同样必须建在脚本层。之前原地点击几乎看不到弹，就是因为松手那一下只做了
# 「从挤扁值回到 1.0」这一小段，幅度太小；拖拽时挤扁能一直保持，才有感觉。
$script:BounceStage = 0
$script:BounceTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BounceTimer.Interval = [TimeSpan]::FromMilliseconds(130)
$script:BounceTimer.Add_Tick({
    $script:BounceTimer.Stop()
    if ($script:BounceStage -eq 2) {
        Invoke-Squash 1.0 1.0 430 $true    # 带过冲弹回原状
        $script:BounceStage = 0
    }
})
function Start-ClickBounce {
    if (-not [bool]$S['bounce']) { return }
    Invoke-Squash 0.94 1.10 130 $false     # 先拉长
    $script:BounceStage = 2
    $script:BounceTimer.Stop()
    $script:BounceTimer.Start()
}

# ---------------------------------------------------------------- 吸附 & 翻转
$script:Flip = $false
function Set-Flip([bool]$on) {
    if ($script:Flip -eq $on) { return }
    $script:Flip = $on
    try {
        $tg = $petImg.RenderTransform
        # 只需要水平翻转，不干扰上面那组 ScaleTransform 的动画，所以再套一层
        if ($tg.Children.Count -lt 2) {
            $flip = New-Object System.Windows.Media.ScaleTransform
            $flip.ScaleX = 1; $flip.ScaleY = 1
            $null = $tg.Children.Add($flip)
        }
        $tg.Children[1].ScaleX = $(if ($on) { -1 } else { 1 })
    } catch { }
}

# 吸附动画的计时器必须建在脚本层、状态也放 $script:
# 教训：之前这个 DispatcherTimer 是在 Start-Snap 函数里 new 的，tick 里用的
# $from / $target / $i 都是函数局部变量。函数一返回，那个作用域就没了，tick
# 里的变量失效，窗口根本不动 —— 表现就是「拖完总是弹回左边，摆不了位置」。
$script:SnapFrom = 0.0
$script:SnapTo = 0.0
$script:SnapStep = 0
$script:SnapSteps = 12

$script:SnapTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$script:SnapTimer.Add_Tick({
    $script:SnapStep++
    $p = [Math]::Min(1.0, $script:SnapStep / [double]$script:SnapSteps)
    $eased = 1 - [Math]::Pow(1 - $p, 3)
    $win.Left = $script:SnapFrom + ($script:SnapTo - $script:SnapFrom) * $eased
    if ($p -ge 1.0) {
        $script:SnapTimer.Stop()
        $script:PetBaseTop = [int]$win.Top
        Save-PetPosition   # 动画停下之后再记位置，否则记的是吸附前的坐标
    }
})

function Start-Snap {
    if (-not [bool]$S['snapEdge']) { return }
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w = $win.Width
    $leftTarget = $wa.Left + 6
    $rightTarget = $wa.Right - $w - 6
    $dLeft = $win.Left - $leftTarget
    $dRight = $rightTarget - $win.Left
    # 只有落点离某一边足够近才吸附；离两边都远就停在你放下的地方。
    # 否则拖到哪儿都会被弹到边上，等于没法自由摆放。
    if ([Math]::Min($dLeft, $dRight) -gt 150) { return }
    $toRight = $dRight -lt $dLeft
    Set-Flip (-not $toRight)   # 贴在左边就翻过去面朝屏幕内
    $script:SnapFrom = $win.Left
    $script:SnapTo = $(if ($toRight) { $rightTarget } else { $leftTarget })
    $script:SnapStep = 0
    $script:SnapTimer.Stop()
    $script:SnapTimer.Start()
}

# ---------------------------------------------------------------- 位置
function Restore-PetPosition {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $left = $wa.Right - $win.Width - 24
    $top = $wa.Bottom - $script:PetH - 12
    if (Test-Path -LiteralPath $PetPosFile) {
        $raw = (Get-Content -LiteralPath $PetPosFile -Raw -ErrorAction SilentlyContinue)
        if ($raw -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:,\s*(0|1))?\s*$') {
            $left = [int]$Matches[1]; $top = [int]$Matches[2]
        }
    }
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($left -lt $wa.Left) { $left = $wa.Left }
    if ($top -lt $wa.Top) { $top = $wa.Top }
    if ($left -gt ($wa.Right - 40)) { $left = $wa.Right - $win.Width - 24 }
    if ($top -gt ($wa.Bottom - 40)) { $top = $wa.Bottom - $script:PetH - 12 }
    # 朝哪边由位置决定，比存一个翻转标记可靠：靠左就翻过去面向屏幕内
    Set-Flip (($left + ($win.Width / 2)) -lt ($wa.Left + $wa.Width / 2))
    $win.Left = $left
    $script:PetBaseTop = $top
    $win.Top = $top
}

function Save-PetPosition {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PetPosFile) | Out-Null
        $f = if ($script:Flip) { 1 } else { 0 }
        Set-Content -LiteralPath $PetPosFile -Value ("{0},{1},{2}" -f [int]$win.Left, [int]$script:PetBaseTop, $f) -Encoding ASCII
    } catch { }
}

# ---------------------------------------------------------------- 气泡
function Show-Page([string]$which) {
    if ($which -eq 'settings') {
        $pageMain.Visibility = 'Collapsed'
        $pageSettings.Visibility = 'Visible'
    } else {
        $pageSettings.Visibility = 'Collapsed'
        $pageMain.Visibility = 'Visible'
    }
    if ($script:PetExpanded) { Set-Bubble $true }   # 重算高度
}

function Set-Bubble([bool]$on) {
    if ($on) {
        if (-not $script:PetExpanded) { $script:PetBaseTop = [int]$win.Top }
        $bubble.Visibility = 'Visible'
        $win.UpdateLayout()
        $bh = [Math]::Ceiling($bubble.ActualHeight) + 10
        $win.Top = $script:PetBaseTop - $bh
        $win.Height = $script:PetH + $bh
        $script:PetExpanded = $true
    } else {
        if ($script:PetExpanded) { $script:PetBaseTop = [int]($win.Top + ($win.Height - $script:PetH)) }
        $bubble.Visibility = 'Collapsed'
        $win.Height = $script:PetH
        $win.Top = $script:PetBaseTop
        $script:PetExpanded = $false
    }
    Apply-PetOpacity
}

# ---------------------------------------------------------------- 状态
function Test-PortOpen([int]$p, [int]$timeoutMs = 300) {
    # Get-NetTCPConnection 走 WMI，单次 0.5–2 秒；放在 UI 线程会把桌宠卡住，
    # 直接开一个 TCP 连接试端口，通/不通都是毫秒级。
    if ($p -le 0) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { $client.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Set-PetLook([string]$state) {
    if ($script:PetState -eq $state -and $petImg.Source) { return }
    $bmp = Get-PetBitmap $state
    if ($bmp) { $petImg.Source = $bmp }
    $script:PetState = $state
}

function Refresh-Pet {
    $tp = Test-PortOpen $Port
    $bp = if ($Config['bridge'].enabled) { Test-PortOpen $BridgePort } else { $false }
    $busy = ([DateTime]::Now -lt $script:BusyUntil)

    if ($busy) {
        Set-PetLook $script:BusyLook
        $dot.Fill = [System.Windows.Media.Brushes]::Orange
        $badgeText.Text = $(if ($script:BusyLook -eq 'stopping') { '停止中' } else { '启动中' })
    } elseif ($tp) {
        Set-PetLook 'running'
        $dot.Fill = [System.Windows.Media.Brushes]::SpringGreen
        $badgeText.Text = '运行中'
    } else {
        Set-PetLook 'idle'
        $dot.Fill = [System.Windows.Media.Brushes]::Crimson
        $badgeText.Text = '未运行'
    }

    $bSub.Text = (Get-Date).ToString('HH:mm:ss')
    $bLine1.Text = $(if ($tp) { "酒馆：运行中（:$Port）" } else { '酒馆：未运行' })
    if ($Config['bridge'].enabled) {
        $bLine2.Text = $(if ($bp) { "生图桥：运行中（:$BridgePort）" } else { "生图桥：未运行（:$BridgePort）" })
    } else { $bLine2.Text = '生图桥：已停用' }

    $btnStart.IsEnabled = (-not $tp) -and (-not $busy)
    $btnStop.IsEnabled = $tp -and (-not $busy)
    $btnRestart.IsEnabled = -not $busy
    $btnBridge.IsEnabled = [bool]$Config['bridge'].enabled -and (-not $busy)
    $btnBridge.Content = $(if ($bp) { '停生图桥' } else { '开生图桥' })
}

# ---------------------------------------------------------------- 动作
function Invoke-PetAction([string]$name) {
    if ($name -eq 'bridge') { $name = if (Test-PortOpen $BridgePort) { 'bridge-stop' } else { 'bridge-start' } }
    switch ($name) {
        'start'        { $script:BusyLook = 'starting'; $script:BusyUntil = [DateTime]::Now.AddSeconds(60); Play-Sfx 'start' }
        'restart'      { $script:BusyLook = 'starting'; $script:BusyUntil = [DateTime]::Now.AddSeconds(70); Play-Sfx 'start' }
        'stop'         { $script:BusyLook = 'stopping'; $script:BusyUntil = [DateTime]::Now.AddSeconds(20); Play-Sfx 'stop' }
        'bridge-start' { $script:BusyLook = 'starting'; $script:BusyUntil = [DateTime]::Now.AddSeconds(20) }
        'bridge-stop'  { $script:BusyLook = 'stopping'; $script:BusyUntil = [DateTime]::Now.AddSeconds(20) }
        default        { $script:BusyLook = 'starting'; $script:BusyUntil = [DateTime]::Now.AddSeconds(20) }
    }
    Refresh-Pet
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ConsoleScript, '-Action', $name, '-NoPause', '-ConfigPath', $ConfigPath
    ) | Out-Null
}

# ---------------------------------------------------------------- 设置页事件
function Sync-SettingsUi {
    $sldSize.Value = [double]$S['width']
    $sldOpacity.Value = [double]$S['opacity']
    $sldVolume.Value = [double]$S['volume']
    $chkSfx.IsChecked = [bool]$S['sfx']
    $chkBounce.IsChecked = [bool]$S['bounce']
    $chkSnap.IsChecked = [bool]$S['snapEdge']
    $lblSize.Text = "$([int]$S['width'])"
    $lblOpacity.Text = ("{0}%" -f [int]([double]$S['opacity'] * 100))
    $lblVolume.Text = ("{0}%" -f [int]([double]$S['volume'] * 100))
}

$sldSize.Add_ValueChanged({
    $S['width'] = [int][Math]::Round($sldSize.Value)
    Apply-PetSize
    Save-PetSettings
    Apply-PetOpacity
})
$sldOpacity.Add_ValueChanged({
    $S['opacity'] = [double]$sldOpacity.Value
    Apply-PetOpacity
    Save-PetSettings
    $sldOpacity.ToolTip = $null
})
$sldVolume.Add_ValueChanged({
    $S['volume'] = [double]$sldVolume.Value
    $lblVolume.Text = ("{0}%" -f [int]([double]$S['volume'] * 100))
    Save-PetSettings
})
$chkSfx.Add_Click({ $S['sfx'] = [bool]$chkSfx.IsChecked; Save-PetSettings; if ($S['sfx']) { Play-Sfx 'release' } })
$chkBounce.Add_Click({ $S['bounce'] = [bool]$chkBounce.IsChecked; Save-PetSettings; Invoke-Squash 1.10 0.90 160 $false; Invoke-Squash 1.0 1.0 420 $true })
$chkSnap.Add_Click({ $S['snapEdge'] = [bool]$chkSnap.IsChecked; Save-PetSettings })

$btnSettings.Add_Click({ Show-Page 'settings' })
$btnBack.Add_Click({ Show-Page 'main' })
$btnTest.Add_Click({ Play-Sfx 'start' })

$btnPick.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选一张角色图片（建议透明底 PNG）'
        $dlg.Filter = '图片 (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp|所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $S['customImage'] = $dlg.FileName
            $script:PetState = ''
            Apply-PetSize
            Save-PetSettings
            Refresh-Pet
            Invoke-Squash 1.14 0.86 150 $false
            Invoke-Squash 1.0 1.0 480 $true
            Play-Sfx 'start'
        }
    } catch { }
})

$btnReset.Add_Click({
    $S['customImage'] = ''
    $S['width'] = 212
    $S['opacity'] = 0.78
    $S['volume'] = 0.7
    $S['sfx'] = $true
    $S['bounce'] = $true
    $S['snapEdge'] = $true
    $script:PetState = ''
    Apply-PetSize
    Sync-SettingsUi
    Save-PetSettings
    Refresh-Pet
})

# ---------------------------------------------------------------- 主页面事件
$btnStart.Add_Click({ Invoke-PetAction 'start' })
$btnStop.Add_Click({ Invoke-PetAction 'stop' })
$btnRestart.Add_Click({ Invoke-PetAction 'restart' })
$btnBridge.Add_Click({ Invoke-PetAction 'bridge' })
$btnOpen.Add_Click({ if ($TavernDir) { Start-Process ("http://127.0.0.1:$Port") } })

$btnMore.Add_Click({
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($item in @(
            @{ H = '查看日志文件夹'; A = { if ($LogDir -and (Test-Path $LogDir)) { Start-Process explorer.exe $LogDir } } },
            @{ H = '复制局域网地址'; A = { try { $lan = Get-LocalIPv4; if ($lan) { [System.Windows.Clipboard]::SetText("http://${lan}:$Port") } } catch { } } },
            @{ H = '重新载入形象';   A = { $script:PetState = ''; Refresh-Pet } },
            @{ H = '回到墙边';       A = { Start-Snap } },
            @{ H = '收起气泡';       A = { Set-Bubble $false; Show-Page 'main' } },
            @{ H = '退出桌宠';       A = { $win.Close() } }
        )) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $item.H
        $mi.Add_Click($item.A)
        $cm.Items.Add($mi) | Out-Null
    }
    $cm.PlacementTarget = $btnMore
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Top
    $cm.IsOpen = $true
})

$petHost.Add_MouseLeftButtonDown({
    Play-Sfx 'press'
    Invoke-Squash 1.16 0.84 90 $false      # 按下先挤扁
    $beforeLeft = $win.Left
    $beforeTop = $win.Top
    $dragged = $true
    try { $win.DragMove() } catch { $dragged = $false }
    if ($dragged) {
        $dragged = (([Math]::Abs($win.Left - $beforeLeft) + [Math]::Abs($win.Top - $beforeTop)) -ge 4)
    }
    if ($script:PetExpanded) { $script:PetBaseTop = [int]($win.Top + ($win.Height - $script:PetH)) }
    else { $script:PetBaseTop = [int]$win.Top }
    Play-Sfx 'release'
    Start-ClickBounce                      # 松手：拉长 -> 过冲回弹
    if (-not $dragged) {
        Set-Bubble (-not $script:PetExpanded)
    } else {
        Start-Snap
    }
    Save-PetPosition
})

$petHost.Add_MouseRightButtonUp({
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($item in @(
            @{ H = '打开酒馆'; A = { Start-Process ("http://127.0.0.1:$Port") } },
            @{ H = '启动';     A = { Invoke-PetAction 'start' } },
            @{ H = '停止';     A = { Invoke-PetAction 'stop' } },
            @{ H = '重启';     A = { Invoke-PetAction 'restart' } },
            @{ H = '设置…';    A = { Set-Bubble $true; Show-Page 'settings' } },
            @{ H = '查看日志'; A = { if ($LogDir -and (Test-Path $LogDir)) { Start-Process explorer.exe $LogDir } } },
            @{ H = '退出';     A = { $win.Close() } }
        )) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $item.H
        $mi.Add_Click($item.A)
        $cm.Items.Add($mi) | Out-Null
    }
    $cm.PlacementTarget = $petHost
    $cm.IsOpen = $true
})

$win.Add_MouseEnter({ Apply-PetOpacity })
$win.Add_MouseLeave({ Apply-PetOpacity })
$win.Add_Closed({ Save-PetPosition; Save-PetSettings; Remove-Item -LiteralPath $PetPidFile -Force -ErrorAction SilentlyContinue })

# ---------------------------------------------------------------- 启动
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PetPidFile) | Out-Null
Set-Content -LiteralPath $PetPidFile -Value $PID -Encoding ASCII

$script:SetupDone = $true
$sldSize.Minimum = 140; $sldSize.Maximum = 380
Apply-PetSize
Restore-PetPosition
Sync-SettingsUi
Apply-PetOpacity
$null = Test-PortOpen $Port
Refresh-Pet
# 预热音效：MediaPlayer.Open 是异步的，先打开好，第一次点才有声音
foreach ($k in $SfxSpec.Keys) { $null = Get-SfxPlayer $k }
$win.Show()

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(4)
$timer.Add_Tick({ Refresh-Pet })
$timer.Start()

[System.Windows.Threading.Dispatcher]::Run()
