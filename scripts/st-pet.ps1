<#
  SillyTavern 控制台 - 桌宠版
  ------------------------------------------------------------
  一只常驻桌面的小人（默认用酒馆自带的 Seraphina）：
    · 点小人     -> 冒泡对话框（状态 + 启动 / 停止）
    · 点右上角小方块 -> 功能面板（重启 / 生图桥 / 打开 / 更多 / 设置）
    · 右键小人   -> 快捷菜单

  参考 DeepSeek-Balance-Whale-Widget 的做法，加了这几样：
    - 按压会有 Q 弹反馈（挤扁 -> 拉长 -> 过冲落定），可关
    - 按压 / 松开 / 启动 / 停止 各有音效，可调音量、可关
    - 拖到屏幕边上自动吸附，吸附在左边时会左右翻转
    - 面板里带一个「设置」页：大小、透明度、音量、弹跳、呼吸、吸附、换角色形象
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

  几何：主窗口永远就是「小人本身」（宽高 = 小人尺寸），气泡挂在主窗口上是
  一个独立的 Popup。这样「小人位置」就是「窗口位置」，不存在「窗口高度一会儿
  含气泡、一会儿不含」的双份状态，改大小时也就不会再算错把气泡顶飞。
  气泡每次定位都按当前小人位置现算（见 Set-BubblePos），不留缓存坐标。

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
    # 路径要自己带引号：Start-Process 是把参数拼成命令行的，带空格的路径会被拆开
    $argLine = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f `
        $MyInvocation.MyCommand.Path, $ConfigPath
    Start-Process -FilePath $exe -ArgumentList $argLine
    return
}

try {
    Add-Type -Namespace StPet -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
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
    breath       = $false
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
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink"    Color="#EEF0FB"/>
    <SolidColorBrush x:Key="InkDim" Color="#8E93B4"/>
    <SolidColorBrush x:Key="InkMid" Color="#B9BEDC"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="31"/><Setter Property="Margin" Value="2.5"/>
      <Setter Property="FontSize" Value="11.5"/><Setter Property="Padding" Value="0"/>
      <Setter Property="MinWidth" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/><Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="9" Background="#26FFFFFF" BorderBrush="#2EFFFFFF" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#3DFFFFFF"/><Setter TargetName="bd" Property="BorderBrush" Value="#4DFFFFFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#59FFFFFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
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
            <Border x:Name="bd" CornerRadius="9" BorderThickness="1" BorderBrush="#9FB2FF">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#7B8AFF" Offset="0"/><GradientStop Color="#3ED9F0" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource InkDim}"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style TargetType="Slider">
      <Setter Property="Height" Value="20"/><Setter Property="MinWidth" Value="0"/>
      <Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="#30FFFFFF"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.DecreaseLarge}" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="#8FA6FF" VerticalAlignment="Center"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.IncreaseLarge}" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="13" Height="13" Cursor="Hand">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid>
                          <Ellipse Fill="#0B0E1E" Opacity="0.55" Margin="1,1.5,0.5,0"/>
                          <Ellipse x:Name="knob" Fill="#F3F5FF"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="knob" Property="Fill" Value="#FFFFFF"/></Trigger>
                          <Trigger Property="IsDragging" Value="True"><Setter TargetName="knob" Property="Fill" Value="#BFD0FF"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C8CDE8"/><Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,4,11,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="15" Height="15" CornerRadius="4.5" VerticalAlignment="Center"
                      Background="#1AFFFFFF" BorderBrush="#3DFFFFFF" BorderThickness="1">
                <Path x:Name="tick" Data="M 3.1,7.7 L 6.1,10.5 L 11.5,4.3" Stroke="#0B1020" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#8FA6FF"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#B9C6FF"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#8FA6FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <!-- 小人：主窗口就是这一块，宽高 = 小人尺寸 -->
    <Grid x:Name="petHost" Background="#01000000">
      <Image x:Name="pet" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Bottom"
             RenderTransformOrigin="0.5,1">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="petScale"  ScaleX="1" ScaleY="1"/>
            <ScaleTransform x:Name="petBreath" ScaleX="1" ScaleY="1"/>
            <ScaleTransform x:Name="petFlip"   ScaleX="1" ScaleY="1"/>
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

      <!-- 收起来的小方块：钉在小人右上角，点它展开功能面板（宽高在代码里给） -->
      <Border x:Name="squareHost" HorizontalAlignment="Right" VerticalAlignment="Top"
              CornerRadius="8" Background="#C8121630" BorderBrush="#4D8FA6FF" BorderThickness="1"
              Cursor="Hand" ToolTip="更多功能">
        <Path x:Name="squareGlyph" Data="M 0,0 M 7,8.5 H 19 M 7,13 H 19 M 7,17.5 H 19"
              Stroke="#DCE2FF" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
              HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Grid>

    <!-- 冒泡对话框：点角色弹出来，只放状态和启动/停止 —— 独立弹窗，小人怎么动它都不会被带着跑 -->
    <Popup x:Name="bubblePopup" AllowsTransparency="True" Placement="Absolute" StaysOpen="False"
           PopupAnimation="None" HorizontalOffset="0" VerticalOffset="0">
      <Grid x:Name="bubble" Width="198" Background="{x:Null}">
        <Grid.RenderTransform>
          <TranslateTransform x:Name="bubbleTt" X="0" Y="0"/>
        </Grid.RenderTransform>
        <Canvas>
          <Path x:Name="bubblePath" StrokeThickness="1.2">
            <Path.Stroke><SolidColorBrush Color="#6E7FA8FF"/></Path.Stroke>
            <Path.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
                <GradientStop Color="#F41B2038" Offset="0"/>
                <GradientStop Color="#F0121530" Offset="0.55"/>
                <GradientStop Color="#F30D1029" Offset="1"/>
              </LinearGradientBrush>
            </Path.Fill>
            <Path.Effect>
              <DropShadowEffect BlurRadius="7" ShadowDepth="2" Direction="270" Opacity="0.45" Color="#000000"/>
            </Path.Effect>
          </Path>
        </Canvas>

        <Border x:Name="bubbleBody" Margin="6,5,6,15" Padding="12,10,12,10">
          <StackPanel>
            <DockPanel>
              <Ellipse x:Name="bubDot" Width="7" Height="7" Fill="#F43F5E" DockPanel.Dock="Left"
                       VerticalAlignment="Center"/>
              <TextBlock x:Name="bubText" Text="酒馆 未运行" FontSize="12" Foreground="{StaticResource Ink}"
                         Margin="7,0,0,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <UniformGrid Columns="2" Margin="0,9,0,0">
              <Button x:Name="btnStart" Style="{StaticResource BtnPrimary}" Content="启动"/>
              <Button x:Name="btnStop"  Style="{StaticResource Btn}"        Content="停止"/>
            </UniformGrid>
          </StackPanel>
        </Border>
      </Grid>
    </Popup>

    <!-- 功能面板：点小方块展开，钉在小方块旁边；改大小时它站在原地不动 -->
    <Popup x:Name="panelPopup" AllowsTransparency="True" Placement="Absolute" StaysOpen="False"
           PopupAnimation="None" HorizontalOffset="0" VerticalOffset="0">
      <Grid x:Name="panel" Width="240" Background="{x:Null}">
        <Grid.RenderTransform>
          <TranslateTransform x:Name="panelTt" X="0" Y="0"/>
        </Grid.RenderTransform>
        <Canvas>
          <Path x:Name="panelPath" StrokeThickness="1.2">
            <Path.Stroke><SolidColorBrush Color="#6E7FA8FF"/></Path.Stroke>
            <Path.Fill>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
                <GradientStop Color="#F41B2038" Offset="0"/>
                <GradientStop Color="#F0121530" Offset="0.55"/>
                <GradientStop Color="#F30D1029" Offset="1"/>
              </LinearGradientBrush>
            </Path.Fill>
            <Path.Effect>
              <DropShadowEffect BlurRadius="7" ShadowDepth="2" Direction="270" Opacity="0.45" Color="#000000"/>
            </Path.Effect>
          </Path>
        </Canvas>

        <Border x:Name="panelBody" Margin="6,5,6,6" Padding="13,11,13,10">
          <Grid>
            <!-- 第一页：功能 -->
            <StackPanel x:Name="pageMain">
              <DockPanel>
                <TextBlock x:Name="bTitle" Text="SillyTavern" FontSize="13.5" FontWeight="Bold"
                           Foreground="{StaticResource Ink}" DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="bSub" Text="" FontSize="10" Foreground="{StaticResource InkDim}"
                           HorizontalAlignment="Right" VerticalAlignment="Center" Margin="8,2,0,0"/>
              </DockPanel>

              <Grid Margin="0,9,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="dotTavern" Width="7" Height="7" Fill="#F43F5E" VerticalAlignment="Center"/>
                  <TextBlock x:Name="bLine1" Text="" FontSize="11" Foreground="{StaticResource InkMid}"
                             Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <Ellipse x:Name="dotBridge" Width="7" Height="7" Fill="#6B7280" VerticalAlignment="Center"/>
                  <TextBlock x:Name="bLine2" Text="" FontSize="11" Foreground="{StaticResource InkMid}"
                             Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>

              <Border Height="1" Background="#1FFFFFFF" Margin="0,10,0,9"/>

              <UniformGrid Columns="3">
                <Button x:Name="btnRestart" Style="{StaticResource Btn}" Content="重启"/>
                <Button x:Name="btnBridge"  Style="{StaticResource Btn}" Content="生图桥"/>
                <Button x:Name="btnOpen"    Style="{StaticResource Btn}" Content="打开"/>
              </UniformGrid>
              <UniformGrid Columns="2" Margin="0,1,0,0">
                <Button x:Name="btnMore"     Style="{StaticResource Btn}" Content="更多"/>
                <Button x:Name="btnSettings" Style="{StaticResource Btn}" Content="设置"/>
              </UniformGrid>
            </StackPanel>

            <!-- 第二页：设置 -->
            <StackPanel x:Name="pageSettings" Visibility="Collapsed">
              <DockPanel>
                <TextBlock Text="设置" FontSize="13.5" FontWeight="Bold" Foreground="{StaticResource Ink}"
                           DockPanel.Dock="Left" VerticalAlignment="Center"/>
                <TextBlock Text="即时生效" FontSize="10" Foreground="{StaticResource InkDim}"
                           HorizontalAlignment="Right" VerticalAlignment="Center" Margin="8,2,0,0"/>
              </DockPanel>

              <Grid Margin="0,11,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="36"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="大小" Style="{StaticResource Lbl}"/>
                <Slider x:Name="sldSize" Grid.Column="1" Minimum="140" Maximum="380" SmallChange="4" LargeChange="20"/>
                <TextBlock x:Name="lblSize" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
              </Grid>
              <Grid Margin="0,7,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="36"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="不透明度" Style="{StaticResource Lbl}"/>
                <Slider x:Name="sldOpacity" Grid.Column="1" Minimum="0.25" Maximum="1.0" SmallChange="0.02" LargeChange="0.1"/>
                <TextBlock x:Name="lblOpacity" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
              </Grid>
              <Grid Margin="0,7,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="52"/><ColumnDefinition Width="*"/><ColumnDefinition Width="36"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="音量" Style="{StaticResource Lbl}"/>
                <Slider x:Name="sldVolume" Grid.Column="1" Minimum="0" Maximum="1.0" SmallChange="0.02" LargeChange="0.1"/>
                <TextBlock x:Name="lblVolume" Grid.Column="2" Style="{StaticResource Lbl}" TextAlignment="Right"/>
              </Grid>

              <WrapPanel Margin="0,10,0,0">
                <CheckBox x:Name="chkSfx" Content="音效"/>
                <CheckBox x:Name="chkBounce" Content="Q弹"/>
                <CheckBox x:Name="chkBreath" Content="呼吸"/>
                <CheckBox x:Name="chkSnap" Content="吸附边缘"/>
              </WrapPanel>

              <UniformGrid Columns="2" Margin="0,9,0,0">
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
      </Grid>
    </Popup>
  </Grid>
</Window>
'@

try {
    $win = [System.Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-Host "  x 界面创建失败：$($_.Exception.Message)" -ForegroundColor Red
    return
}

$g = { param($n) $win.FindName($n) }
$bubblePopup = & $g 'bubblePopup'
$bubble = & $g 'bubble'; $bubblePath = & $g 'bubblePath'; $bubbleTt = & $g 'bubbleTt'
$panelPopup = & $g 'panelPopup'
$panel = & $g 'panel'; $panelPath = & $g 'panelPath'; $panelTt = & $g 'panelTt'
$squareHost = & $g 'squareHost'; $squareGlyph = & $g 'squareGlyph'
$bubDot = & $g 'bubDot'; $bubText = & $g 'bubText'
$pageMain = & $g 'pageMain'; $pageSettings = & $g 'pageSettings'
$petHost = & $g 'petHost'; $petImg = & $g 'pet'
$petScale = & $g 'petScale'; $petBreath = & $g 'petBreath'; $petFlip = & $g 'petFlip'
$badgeText = & $g 'badgeText'; $dot = & $g 'dot'
$dotTavern = & $g 'dotTavern'; $dotBridge = & $g 'dotBridge'
$bTitle = & $g 'bTitle'; $bSub = & $g 'bSub'; $bLine1 = & $g 'bLine1'; $bLine2 = & $g 'bLine2'
$btnStart = & $g 'btnStart'; $btnStop = & $g 'btnStop'; $btnRestart = & $g 'btnRestart'
$btnBridge = & $g 'btnBridge'; $btnOpen = & $g 'btnOpen'; $btnMore = & $g 'btnMore'
$btnSettings = & $g 'btnSettings'; $btnBack = & $g 'btnBack'; $btnPick = & $g 'btnPick'
$btnReset = & $g 'btnReset'; $btnTest = & $g 'btnTest'
$sldSize = & $g 'sldSize'; $sldOpacity = & $g 'sldOpacity'; $sldVolume = & $g 'sldVolume'
$lblSize = & $g 'lblSize'; $lblOpacity = & $g 'lblOpacity'; $lblVolume = & $g 'lblVolume'
$chkSfx = & $g 'chkSfx'; $chkBounce = & $g 'chkBounce'; $chkSnap = & $g 'chkSnap'; $chkBreath = & $g 'chkBreath'

if (-not $bubblePopup -or -not $petImg -or -not $bubblePath) {
    Write-Host '  x 界面元素没找齐，XAML 可能被改坏了。' -ForegroundColor Red
    return
}

$script:PetW = 212
$script:PetH = 321
$script:PetExpanded = $false
$script:PetState = ''
$script:BusyUntil = [DateTime]::MinValue
$script:BusyLook = 'starting'

# 气泡外形参数：外圈留出阴影的余量，尾巴朝下指小人
$script:ShapeL = 6.0; $script:ShapeT = 5.0; $script:ShapeR = 6.0; $script:ShapeB = 6.0
$script:TailH = 9.0; $script:TailW = 18.0; $script:Corner = 13.0
$script:GapPet = 7.0    # 尾巴尖到小人头顶的距离
$script:LastShapeH = -1; $script:LastShapeW = -1; $script:LastTailX = -99999
$script:LastPanelH = -1; $script:LastPanelW = -1
$script:BubbleX = [double]::NaN; $script:BubbleY = [double]::NaN
$script:PanelX = [double]::NaN; $script:PanelY = [double]::NaN
$script:AnchorW = 0                 # 上次「重新贴靠」时小人的宽度，用来判断是不是在改大小
$script:LastTopmost = [DateTime]::MinValue
$script:SqSize = 26.0               # 小方块边长（要和 XAML 里的观感一致）
$script:SqPad = 4.0                 # 小方块离小人右上角多远

function New-Pt([double]$x, [double]$y) {
    return (New-Object System.Windows.Point($x, $y))
}

function Get-PetWinW([int]$w) {
    if ($w -lt 140) { return 140 } elseif ($w -gt 380) { return 380 } else { return $w }
}

# ---------------------------------------------------------------- 主窗口几何
# 主窗口 = 小人本身。脚底定位：底边不动，长高往上长。
function Clamp-PetPos {
    try {
        if ([double]::IsNaN($win.Left) -or [double]::IsNaN($win.Top)) { return }
        $wa = [System.Windows.SystemParameters]::WorkArea
        $l = [Math]::Round($win.Left)
        $t = [Math]::Round($win.Top)
        if ($l -lt $wa.Left) { $l = $wa.Left }
        if ($l -gt ($wa.Right - $win.Width)) { $l = $wa.Right - $win.Width }
        if ($t -lt $wa.Top) { $t = $wa.Top }
        # 脚可以站到任务栏上沿，但不许整个沉到屏幕外面去
        if ($t -gt ($wa.Bottom - $win.Height)) { $t = $wa.Bottom - $win.Height }
        if ($l -ne $win.Left) { $win.Left = $l }
        if ($t -ne $win.Top) { $win.Top = $t }
    } catch { }
}

function Apply-PetSize {
    $oldH = $script:PetH
    $oldW = $win.Width
    $w = Get-PetWinW ([int]$S['width'])
    $S['width'] = $w
    $script:PetW = $w
    $script:PetH = [int][Math]::Round($w * 920 / 608)

    $wa = [System.Windows.SystemParameters]::WorkArea
    # 贴右墙的往屏幕内侧长（右缘不动），否则左缘不动
    if (-not [double]::IsNaN($win.Left) -and ($wa.Right - ($win.Left + $oldW)) -lt 48) {
        $win.Left = [Math]::Round($win.Left - ($w - $oldW))
    }
    if (-not [double]::IsNaN($win.Top)) { $win.Top = [Math]::Round($win.Top + ($oldH - $script:PetH)) }
    $win.Width = $w
    $win.Height = $script:PetH
    $petImg.Width = $w
    $petImg.Height = $script:PetH
    $lblSize.Text = "$w"
    Clamp-PetPos
}

function Apply-PetOpacity {
    if ([bool]$S['fadeWhenIdle'] -and -not $script:PetExpanded -and -not $win.IsMouseOver) {
        $win.Opacity = [double]$S['opacity']
    } else {
        $win.Opacity = 1.0
    }
    $lblOpacity.Text = ("{0}%" -f [int]([double]$S['opacity'] * 100))
}

# ---------------------------------------------------------------- 气泡外形
function Add-Line($fig, [double]$x, [double]$y) {
    $s = New-Object System.Windows.Media.LineSegment
    $s.Point = New-Pt $x $y
    [void]$fig.Segments.Add($s)
}
function Add-Arc($fig, [double]$x, [double]$y, [double]$r) {
    $s = New-Object System.Windows.Media.ArcSegment
    $s.Point = New-Pt $x $y
    $s.Size = New-Object System.Windows.Size($r, $r)
    $s.IsLargeArc = $false
    $s.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    [void]$fig.Segments.Add($s)
}

# 圆角矩形（+ 可选朝下的小尾巴）；tailX 是尾巴尖在气泡内的横坐标，<0 表示不带尾巴。
# W/H 由调用方传进来（和定位用的是同一份测量值）：自己再去读 ActualHeight
# 有风险 —— 切页那一瞬间布局还没稳定，读到的瞬时值和实际尺寸对不上，
# 尾巴就会按错的 H 画出来、被窗口裁掉一截。
function Update-Shape($path, [double]$tailX, [double]$W, [double]$H) {
    try {
        if ($W -lt 60 -or $H -lt 40) { return }
        $L = $script:ShapeL; $T = $script:ShapeT; $R = $script:ShapeR; $B = $script:ShapeB
        $tw = $script:TailW; $rad = $script:Corner
        $th = $(if ($tailX -ge 0) { $script:TailH } else { 0.0 })
        $x0 = $L; $x1 = $W - $R; $y0 = $T; $y1 = $H - $B - $th
        if (($y1 - $y0) -lt 30) { return }
        if ($tailX -ge 0) {
            $lo = $x0 + $rad + $tw / 2
            $hi = $x1 - $rad - $tw / 2
            if ($tailX -lt $lo) { $tailX = $lo }
            if ($tailX -gt $hi) { $tailX = $hi }
        }

        $fig = New-Object System.Windows.Media.PathFigure
        $fig.IsClosed = $true
        $fig.StartPoint = New-Pt ($x0 + $rad) $y0
        Add-Line $fig ($x1 - $rad) $y0
        Add-Arc  $fig $x1 ($y0 + $rad) $rad
        Add-Line $fig $x1 ($y1 - $rad)
        Add-Arc  $fig ($x1 - $rad) $y1 $rad
        if ($tailX -ge 0) {
            Add-Line $fig ($tailX + $tw / 2) $y1
            Add-Line $fig $tailX ($y1 + $th)
            Add-Line $fig ($tailX - $tw / 2) $y1
        }
        Add-Line $fig ($x0 + $rad) $y1
        Add-Arc  $fig $x0 ($y1 - $rad) $rad
        Add-Line $fig $x0 ($y0 + $rad)
        Add-Arc  $fig ($x0 + $rad) $y0 $rad

        $geo = New-Object System.Windows.Media.PathGeometry
        [void]$geo.Figures.Add($fig)
        $path.Data = $geo
    } catch { }
}

function Set-PopupTopmost($visual, [switch]$Force) {
    # WPF 的 Popup 窗口不会继承 owner 的 Topmost（只跟着 owner 的 z 序），
    # 弹窗会被别的置顶/靠前的窗口压住甚至挡住点击。手动把它钉到 topmost。
    # 但不能每次重新定位都调：拖动小人时定位是逐帧跑的，密集的 SetWindowPos
    # 会把拖拽的鼠标捕获打断（表现就是拖到一半小人不动了）。所以做个节流。
    if (-not $Force) {
        if (([DateTime]::Now - $script:LastTopmost).TotalMilliseconds -lt 1500) { return }
    }
    $script:LastTopmost = [DateTime]::Now
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($visual)
        if ($src -and $src.Handle -ne [IntPtr]::Zero) {
            [void][StPet.Native]::SetWindowPos($src.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
        }
    } catch { }
}

# 弹窗自己尺寸变了（切页）时重新定位。必须「合并 + 延后」：
# 定位动作本身会改 popup 偏移、进而触发布局，直接在 SizeChanged 里同步调用
# 会变成 SizeChanged -> 改偏移 -> 再布局 -> SizeChanged 的自激循环，
# 最后弹窗窗口和内容尺寸对不上（尾巴被裁掉一截）。
$script:PosQueued = $false
function Request-PopupPos {
    if ($script:PosQueued) { return }
    $script:PosQueued = $true
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action] {
                $script:PosQueued = $false
                Set-BubblePos
                Set-PanelPos
            }) | Out-Null
    } catch { $script:PosQueued = $false }
}

# 小方块在主窗口里的位置（DIP）—— 面板就贴在它旁边
function Get-SquareBox {
    $m = $script:SqPad
    return @{
        X = $win.Left + $win.Width - $m - $script:SqSize
        Y = $win.Top + $m
        W = $script:SqSize
        H = $script:SqSize
    }
}

# 冒泡对话框：底边贴小人头顶、水平居中，尾巴指着头顶
function Set-BubblePos {
    if (-not $bubblePopup.IsOpen) { return }
    try {
        if ([double]::IsNaN($win.Left) -or [double]::IsNaN($win.Top)) { return }
        $w = $bubble.ActualWidth; $h = $bubble.ActualHeight
        if ($w -lt 10) { $w = 198 }
        if ($h -lt 10) { $h = 120 }
        $wa = [System.Windows.SystemParameters]::WorkArea

        # 改大小时弹窗「就地不动」：之前每次都贴着小人重新居中，结果贴右墙的
        # 小人一边长大一边被拉回屏幕内，弹窗跟着横着漂，正在拖的滑块就被带跑了
        $resized = ($script:AnchorW -gt 0) -and ($win.Width -ne $script:AnchorW) -and (-not [double]::IsNaN($script:BubbleX))
        if ($resized) {
            $x = $script:BubbleX; $y = $script:BubbleY
        } else {
            $x = $win.Left + ($win.Width - $w) / 2
            $y = $win.Top - $h - $script:GapPet
            $script:AnchorW = $win.Width
        }
        if ($x -lt ($wa.Left + 4)) { $x = $wa.Left + 4 }
        if (($x + $w) -gt ($wa.Right - 4)) { $x = $wa.Right - 4 - $w }
        if ($y -lt ($wa.Top + 4)) { $y = $wa.Top + 4 }
        if (($y + $h) -gt ($wa.Bottom - 4)) { $y = $wa.Bottom - 4 - $h }
        $script:BubbleX = $x; $script:BubbleY = $y
        $tx = [Math]::Round($x); $ty = [Math]::Round($y)
        # 值没变就不写：写 popup 偏移本身会触发布局，反复写会自激成死循环
        if ($bubblePopup.HorizontalOffset -ne $tx) { $bubblePopup.HorizontalOffset = $tx }
        if ($bubblePopup.VerticalOffset -ne $ty) { $bubblePopup.VerticalOffset = $ty }
        # 尾巴永远指着小人的头顶（贴边时气泡被拉回来，尾巴跟着偏）
        $tailX = [Math]::Round($win.Left + $win.Width / 2 - $x)
        if ($h -ne $script:LastShapeH -or $tailX -ne $script:LastTailX -or $w -ne $script:LastShapeW) {
            $script:LastShapeH = $h; $script:LastTailX = $tailX; $script:LastShapeW = $w
            Update-Shape $bubblePath $tailX $w $h
        }
        Set-PopupTopmost $bubble
    } catch { }
}

# 功能面板：贴在小方块旁边（优先摆在左边，放不下就摆右边），
# 展开之后位置就钉住了 —— 拖大小滑块时它一动不动。
function Set-PanelPos {
    if (-not $panelPopup.IsOpen) { return }
    try {
        if ([double]::IsNaN($win.Left) -or [double]::IsNaN($win.Top)) { return }
        $w = $panel.ActualWidth; $h = $panel.ActualHeight
        if ($w -lt 10) { $w = 240 }
        if ($h -lt 10) { $h = 160 }
        $wa = [System.Windows.SystemParameters]::WorkArea
        $resized = ($script:AnchorW -gt 0) -and ($win.Width -ne $script:AnchorW) -and (-not [double]::IsNaN($script:PanelX))
        if ($resized) {
            $x = $script:PanelX; $y = $script:PanelY
        } else {
            $sq = Get-SquareBox
            $x = $sq.X - $w - 6
            if ($x -lt ($wa.Left + 4)) { $x = $sq.X + $sq.W + 6 }   # 左边放不下就摆右边
            $y = $sq.Y
            $script:AnchorW = $win.Width
        }
        if ($x -lt ($wa.Left + 4)) { $x = $wa.Left + 4 }
        if (($x + $w) -gt ($wa.Right - 4)) { $x = $wa.Right - 4 - $w }
        if ($y -lt ($wa.Top + 4)) { $y = $wa.Top + 4 }
        if (($y + $h) -gt ($wa.Bottom - 4)) { $y = $wa.Bottom - 4 - $h }
        $script:PanelX = $x; $script:PanelY = $y
        $tx = [Math]::Round($x); $ty = [Math]::Round($y)
        if ($panelPopup.HorizontalOffset -ne $tx) { $panelPopup.HorizontalOffset = $tx }
        if ($panelPopup.VerticalOffset -ne $ty) { $panelPopup.VerticalOffset = $ty }
        if ($h -ne $script:LastPanelH -or $w -ne $script:LastPanelW) {
            $script:LastPanelH = $h; $script:LastPanelW = $w
            Update-Shape $panelPath -1 $w $h
        }
        Set-PopupTopmost $panel
    } catch { }
}

# ---------------------------------------------------------------- 弹窗开关
# 两个弹窗：冒泡对话框（点小人）和功能面板（点小方块）。
# 都用 StaysOpen=False —— 点空白处 WPF 自己会把它们收起来，不用自己装钩子。
function Open-Popup($root, $tt, $popup, [bool]$on, [string]$which) {
    if ($on) {
        if (-not $popup.IsOpen) {
            # 每次打开都重新贴靠一次（清掉上次的位置缓存）
            if ($which -eq 'bubble') { $script:BubbleX = [double]::NaN; $script:BubbleY = [double]::NaN }
            else { $script:PanelX = [double]::NaN; $script:PanelY = [double]::NaN }
            $script:AnchorW = 0
            $root.Visibility = 'Visible'
            $popup.IsOpen = $true
            $root.UpdateLayout()
            if ($which -eq 'bubble') { Set-BubblePos } else { Set-PanelPos }
            Request-PopupPos      # 布局没走完时量不到真实高度，下一帧再校一次
            if ([bool]$S['bounce']) {
                # 基值必须是动画的终点：FillBehavior=Stop 的动画播完后会退回基值，
                # 基值若还停在起点，弹窗就会永久歪着（尾巴被窗口底边裁掉一截）
                $root.Opacity = 1.0
                $tt.Y = 0
                $fa = New-Object System.Windows.Media.Animation.DoubleAnimation
                $fa.From = 0.15; $fa.To = 1.0
                $fa.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
                $fe = New-Object System.Windows.Media.Animation.CubicEase
                $fe.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
                $fa.EasingFunction = $fe
                $fa.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fa)
                $sa = New-Object System.Windows.Media.Animation.DoubleAnimation
                $sa.From = 7; $sa.To = 0
                $sa.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(170))
                $sa.EasingFunction = $fe
                $sa.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $sa)
            }
        }
    } else {
        if ($popup.IsOpen) { $popup.IsOpen = $false }
        $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        try { $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null) } catch { }
        $tt.Y = 0
        $root.Opacity = 1.0
    }
}

# 「有没有弹窗开着」只影响闲置变淡：开着就不淡
function Update-PetExpanded {
    $script:PetExpanded = ($bubblePopup.IsOpen -or $panelPopup.IsOpen)
    Apply-PetOpacity
}

# 互斥：打开一个就把另一个收起来，免得两块板叠在一起
function Set-Bubble([bool]$on) {
    if ($on) { Open-Popup $panel $panelTt $panelPopup $false 'panel' }
    Open-Popup $bubble $bubbleTt $bubblePopup $on 'bubble'
    Update-PetExpanded
}

function Set-Panel([bool]$on) {
    if ($on) { Open-Popup $bubble $bubbleTt $bubblePopup $false 'bubble' }
    Open-Popup $panel $panelTt $panelPopup $on 'panel'
    Update-PetExpanded
}

function Show-Page([string]$which) {
    if ($which -eq 'settings') {
        $pageMain.Visibility = 'Collapsed'
        $pageSettings.Visibility = 'Visible'
    } else {
        $pageSettings.Visibility = 'Collapsed'
        $pageMain.Visibility = 'Visible'
    }
    if ($panelPopup.IsOpen) {
        $panel.UpdateLayout()
        # 换页后高度变了，重新贴回小方块旁边
        $script:AnchorW = 0
        Set-PanelPos
        Request-PopupPos
    }
}

# ---------------------------------------------------------------- Q 弹反馈
# 用关键帧一次性描述「挤扁 -> 拉长 -> 过冲落定」。
# 之前拆成几段动画 + 计时器接力，衔接处会掉帧；原地点击那一下幅度也偏小。
function New-SquashAnim([object[]]$frames) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    foreach ($f in $frames) {
        $kf = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame
        $kf.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds([int]$f[0]))
        $kf.Value = [double]$f[1]
        $mode = [string]$f[2]
        if ($mode -eq 'over') {
            $fn = New-Object System.Windows.Media.Animation.BackEase
            $fn.Amplitude = 0.65
            $fn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $kf.EasingFunction = $fn
        } elseif ($mode -eq 'out') {
            $fn = New-Object System.Windows.Media.Animation.CubicEase
            $fn.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
            $kf.EasingFunction = $fn
        }
        [void]$a.KeyFrames.Add($kf)
    }
    return $a
}

$script:SquashSpec = @{
    press   = @{ X = @(@(0, 1.00, ''), @(90, 1.16, 'out'));
                 Y = @(@(0, 1.00, ''), @(90, 0.84, 'out')) }
    release = @{ X = @(@(0, 1.16, ''), @(110, 0.93, 'out'), @(430, 1.0, 'over'));
                 Y = @(@(0, 0.84, ''), @(110, 1.10, 'out'), @(430, 1.0, 'over')) }
    poke    = @{ X = @(@(0, 1.00, ''), @(120, 1.15, 'out'), @(430, 1.0, 'over'));
                 Y = @(@(0, 1.00, ''), @(120, 0.85, 'out'), @(430, 1.0, 'over')) }
}

function Invoke-Squash([string]$kind) {
    if (-not [bool]$S['bounce']) { return }
    try {
        $spec = $script:SquashSpec[$kind]; if (-not $spec) { return }
        $petScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-SquashAnim $spec.X))
        $petScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-SquashAnim $spec.Y))
    } catch { }
}

# 呼吸：很轻的一点起伏，让小人不像一张贴纸。
# 注意：这是「持续动画」，WPF 的透明分层窗口只能软件渲染，一直动就会一直重绘 ——
# 实测大约吃掉 20% 单核（不呼吸时是 0%）。所以它是独立开关，而且默认关。
function Start-Breath {
    try {
        if (-not [bool]$S['breath']) { Stop-Breath; return }
        foreach ($pair in @(@('ScaleX', 1.012), @('ScaleY', 1.020))) {
            $prop = if ($pair[0] -eq 'ScaleX') { [System.Windows.Media.ScaleTransform]::ScaleXProperty }
                    else { [System.Windows.Media.ScaleTransform]::ScaleYProperty }
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation
            $a.From = 1.0; $a.To = [double]$pair[1]
            $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(2500))
            $a.AutoReverse = $true
            $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $e = New-Object System.Windows.Media.Animation.SineEase
            $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
            $a.EasingFunction = $e
            $petBreath.BeginAnimation($prop, $a)
        }
    } catch { }
}
function Stop-Breath {
    try {
        $petBreath.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $petBreath.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $petBreath.ScaleX = 1.0; $petBreath.ScaleY = 1.0
    } catch { }
}

# ---------------------------------------------------------------- 吸附 & 翻转
function Set-Flip([bool]$on) {
    try { $petFlip.ScaleX = $(if ($on) { -1.0 } else { 1.0 }) } catch { }
}

# 平滑滑动：WPF 动画逐帧插值。之前是自己开计时器走 12 步，步长粗、还容易被
# 别的事件挤掉帧。这里先把 Left 直接落到目标（基值），再播一段 From->To 的动画，
# 动画结束（FillBehavior=Stop）后自然停在基值上，不会回跳。
function Move-WindowTo([double]$toLeft, [int]$ms) {
    try {
        $from = $win.Left
        if ([double]::IsNaN($from)) { $win.Left = $toLeft; return }
        $win.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
        $win.Left = $toLeft
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = $from; $a.To = $toLeft
        $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms))
        $e = New-Object System.Windows.Media.Animation.CubicEase
        $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $a.EasingFunction = $e
        $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $win.BeginAnimation([System.Windows.Window]::LeftProperty, $a)
    } catch { }
}

function Start-Snap {
    if (-not [bool]$S['snapEdge']) { return }
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w = $win.Width
        $leftTarget = $wa.Left + 6
        $rightTarget = $wa.Right - $w - 6
        $dLeft = $win.Left - $leftTarget
        $dRight = $rightTarget - $win.Left
        # 只有落点离某一边足够近才吸附；离两边都远就停在你放下的地方，
        # 否则拖到哪儿都会被弹到边上，等于没法自由摆放。
        if ([Math]::Min($dLeft, $dRight) -gt 150) { return }
        $toRight = $dRight -lt $dLeft
        Set-Flip (-not $toRight)   # 贴在左边就翻过去面朝屏幕内
        Move-WindowTo $(if ($toRight) { $rightTarget } else { $leftTarget }) 190
    } catch { }
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
    if ($left -lt $wa.Left) { $left = $wa.Left }
    if ($left -gt ($wa.Right - $win.Width)) { $left = $wa.Right - $win.Width }
    if ($top -lt $wa.Top) { $top = $wa.Top }
    if ($top -gt ($wa.Bottom - $win.Height)) { $top = $wa.Bottom - $win.Height }
    # 朝哪边由位置决定，比存一个翻转标记可靠：靠左就翻过去面向屏幕内
    Set-Flip (($left + ($win.Width / 2)) -lt ($wa.Left + $wa.Width / 2))
    $win.Left = $left
    $win.Top = $top
}

function Save-PetPosition {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PetPosFile) | Out-Null
        $f = if ($petFlip.ScaleX -lt 0) { 1 } else { 0 }
        Set-Content -LiteralPath $PetPosFile -Value ("{0},{1},{2}" -f [int]$win.Left, [int]$win.Top, $f) -Encoding ASCII
    } catch { }
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
    $script:PetState = $state
    $bmp = Get-PetBitmap $state
    if (-not $bmp) { return }
    if (-not $petImg.Source -or -not [bool]$S['bounce']) { $petImg.Source = $bmp; return }
    # 换表情淡入一下，避免硬切
    $petImg.Source = $bmp
    try {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 0.35; $a.To = 1.0
        $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
        $e = New-Object System.Windows.Media.Animation.CubicEase
        $e.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
        $a.EasingFunction = $e
        $a.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $petImg.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    } catch { }
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
    # 冒泡对话框：只报酒馆状态
    $bubDot.Fill = $(if ($busy) { [System.Windows.Media.Brushes]::Orange } elseif ($tp) { [System.Windows.Media.Brushes]::SpringGreen } else { [System.Windows.Media.Brushes]::Crimson })
    $bubText.Text = $(if ($busy) { $(if ($script:BusyLook -eq 'stopping') { '酒馆 停止中' } else { '酒馆 启动中' }) }
                      elseif ($tp) { "酒馆 运行中（:$Port）" } else { '酒馆 未运行' })
    # 功能面板：一行放两个状态
    $dotTavern.Fill = $(if ($tp) { [System.Windows.Media.Brushes]::SpringGreen } else { [System.Windows.Media.Brushes]::Crimson })
    $bLine1.Text = $(if ($tp) { "酒馆 :$Port" } else { "酒馆 未运行" })
    if ($Config['bridge'].enabled) {
        $dotBridge.Fill = $(if ($bp) { [System.Windows.Media.Brushes]::SpringGreen } else { [System.Windows.Media.Brushes]::Crimson })
        $bLine2.Text = $(if ($bp) { "生图桥 :$BridgePort" } else { "生图桥 未运行" })
    } else {
        $dotBridge.Fill = [System.Windows.Media.Brushes]::Gray
        $bLine2.Text = '生图桥 停用'
    }

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
    # 同上：路径自己带引号，项目目录含空格时按钮才不是白按
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1} -NoPause -ConfigPath "{2}"' -f `
        $ConsoleScript, $name, $ConfigPath
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList $argLine | Out-Null
}

# ---------------------------------------------------------------- 设置页事件
function Sync-SettingsUi {
    $sldSize.Value = [double]$S['width']
    $sldOpacity.Value = [double]$S['opacity']
    $sldVolume.Value = [double]$S['volume']
    $chkSfx.IsChecked = [bool]$S['sfx']
    $chkBounce.IsChecked = [bool]$S['bounce']
    $chkBreath.IsChecked = [bool]$S['breath']
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
})
$sldVolume.Add_ValueChanged({
    $S['volume'] = [double]$sldVolume.Value
    $lblVolume.Text = ("{0}%" -f [int]([double]$S['volume'] * 100))
    Save-PetSettings
})
$chkSfx.Add_Click({ $S['sfx'] = [bool]$chkSfx.IsChecked; Save-PetSettings; if ($S['sfx']) { Play-Sfx 'release' } })
$chkBounce.Add_Click({
    $S['bounce'] = [bool]$chkBounce.IsChecked
    Save-PetSettings
    if ($S['bounce']) { Invoke-Squash 'poke' } else { Invoke-Squash 'release' }
})
$chkBreath.Add_Click({
    $S['breath'] = [bool]$chkBreath.IsChecked
    Save-PetSettings
    Start-Breath
})
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
            Set-Panel $true
            Show-Page 'main'
            Refresh-Pet
            Invoke-Squash 'poke'
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
    Start-Breath
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
            @{ H = '收起弹窗';       A = { Set-Bubble $false; Set-Panel $false; Show-Page 'main' } },
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
    Invoke-Squash 'press'                  # 按下先挤扁
    $beforeLeft = $win.Left
    $beforeTop = $win.Top
    $dragged = $true
    try { $win.DragMove() } catch { $dragged = $false }
    if ($dragged) {
        # 阈值放宽到 8：手抖两三像素不该算拖动，否则点击经常被吞掉、气泡打不开
        $dragged = (([Math]::Abs($win.Left - $beforeLeft) + [Math]::Abs($win.Top - $beforeTop)) -ge 8)
    }
    Play-Sfx 'release'
    Invoke-Squash 'release'                # 松手：拉长 -> 过冲回弹
    if ($dragged) {
        Clamp-PetPos
        Start-Snap
        Save-PetPosition
    } else {
        # 点角色：冒泡对话框开/收
        Set-Bubble (-not $bubblePopup.IsOpen)
    }
})

# 点小方块：展开/收起功能面板。
# ① 按下时 Handled=true：不然事件接着冒泡到 petHost，会顺带触发拖动/点角色。
# ② 但开关要放到「松手」才做：弹窗是 StaysOpen=False 的，按下就打开的话，
#    同一次点击的松手会被它当成「点了空白处」，回头把自己关掉。
$script:SquarePressed = $false
$squareHost.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:SquarePressed = $true
})
$squareHost.Add_MouseLeftButtonUp({
    param($s, $e)
    $e.Handled = $true
    if (-not $script:SquarePressed) { return }
    $script:SquarePressed = $false
    Set-Panel (-not $panelPopup.IsOpen)
})
$squareHost.Add_MouseEnter({ try { $squareHost.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E0182448') } catch { } })
$squareHost.Add_MouseLeave({ try { $squareHost.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#C8121630') } catch { } })

$petHost.Add_MouseRightButtonUp({
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($item in @(
            @{ H = '打开酒馆'; A = { Start-Process ("http://127.0.0.1:$Port") } },
            @{ H = '启动';     A = { Invoke-PetAction 'start' } },
            @{ H = '停止';     A = { Invoke-PetAction 'stop' } },
            @{ H = '重启';     A = { Invoke-PetAction 'restart' } },
            @{ H = '设置…';    A = { Set-Panel $true; Show-Page 'settings' } },
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

# 小人一动（拖拽、改大小导致上缘变化），弹窗跟着重新定位
$win.Add_LocationChanged({ Request-PopupPos })
$bubble.Add_SizeChanged({ Request-PopupPos })
$panel.Add_SizeChanged({ Request-PopupPos })
# StaysOpen=False 时 WPF 会自己把弹窗关掉（点空白处），状态要跟着同步
$bubblePopup.Add_Closed({ Update-PetExpanded })
$panelPopup.Add_Closed({ Update-PetExpanded })
$bubblePopup.Add_Opened({ Set-BubblePos; Set-PopupTopmost $bubble -Force })
$panelPopup.Add_Opened({ Set-PanelPos; Set-PopupTopmost $panel -Force })

$win.Add_Closed({
    try { $bubblePopup.IsOpen = $false; $panelPopup.IsOpen = $false } catch { }
    Save-PetPosition
    Save-PetSettings
    Remove-Item -LiteralPath $PetPidFile -Force -ErrorAction SilentlyContinue
})

# ---------------------------------------------------------------- 启动
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PetPidFile) | Out-Null
Set-Content -LiteralPath $PetPidFile -Value $PID -Encoding ASCII

# 小方块的尺寸/位置统一在这里给（26 和 4 只在这两行出现，改起来不容易漏）
$squareHost.Width = $script:SqSize
$squareHost.Height = $script:SqSize
$squareHost.Margin = New-Object System.Windows.Thickness(0, $script:SqPad, $script:SqPad, 0)

$sldSize.Minimum = 140; $sldSize.Maximum = 380
Apply-PetSize
Restore-PetPosition
Sync-SettingsUi
Apply-PetOpacity
$null = Test-PortOpen $Port
Refresh-Pet
Start-Breath
# 预热音效：MediaPlayer.Open 是异步的，先打开好，第一次点才有声音
foreach ($k in $SfxSpec.Keys) { $null = Get-SfxPlayer $k }
$win.Show()

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(4)
$timer.Add_Tick({ Refresh-Pet })
$timer.Start()

[System.Windows.Threading.Dispatcher]::Run()
