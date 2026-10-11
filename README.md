# SillyTavern 控制台（Windows）

> 一个给 [SillyTavern](https://github.com/SillyTavern/SillyTavern)（酒馆）用的**中文菜单式控制台**：
> 一键启动 / 停止 / 重启 / 看状态 / 看日志，自动显示手机访问地址，并可选地把酒馆的生图请求
> **桥接到任意 OpenAI 兼容的生图 API**。

```
                                       ┌──────────────────────────────┐
  手机 / 平板 ──┐                       │  本机 (Windows)               │
                ├── 局域网 / Tailscale ─┤                              │
  电脑浏览器 ──┘                        │  :8000  SillyTavern (node)   │
                                       │           │                  │
                                       │           └─ 生图请求         │
                                       │                ↓             │
                                       │  :7861  sd-bridge ──> 生图 API │
                                       └──────────────────────────────┘
```

## 特性

- **隐藏后台运行**：以隐藏窗口方式启动 `node server.js`，不占任务栏、不挡视线
- **中文菜单控制台**：启动 / 停止 / 重启 / 状态 / 日志 / 快捷方式 / 计划任务，一个界面全搞定
- **桌面小挂件（桌宠）**：常驻角落的小人，点一下弹出按钮气泡，按状态换表情；能拖、能半透明、右键有菜单
- **自动显示访问地址**：本机回环、局域网 IP、Tailscale IP（装了 Tailscale 时）一次列清
- **桌面快捷方式**：一键生成「Console / Start / Stop」三个 `.lnk`（图标取酒馆自己的 favicon）
- **登录自启**：可选注册计划任务，登录 Windows 后自动把酒馆（和生图桥）拉起来
- **生图桥**（可选）：把酒馆的「Stable Diffusion Web UI (AUTOMATIC1111)」生图源
  转接到你自己的云端生图 API（默认示例为 Agnes），**免费额度也能用**
- **零依赖**：纯 PowerShell + Node 内置模块，不需要 `npm install` 任何东西
- **配置与代码分离**：路径/端口都在 `config.json`，密钥在 `.secrets/`，仓库里没有你的隐私

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Windows 10 / 11（用到 `Get-NetTCPConnection`） |
| PowerShell | Windows PowerShell 5.1（系统自带）或 PowerShell 7+ |
| Node.js | 18+（酒馆本身也需要） |
| SillyTavern | 任意较新版本（需要含 `server.js`） |
| Tailscale | 可选。想让手机在外网也能连时安装 |

## 快速开始

```powershell
git clone <本仓库地址> st-console
cd st-console
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装脚本会：探测酒馆目录与 `node.exe` → 生成 `config.json` → 准备生图桥配置 →
创建桌面快捷方式 → 注册登录自启任务。

之后直接**双击桌面上的 `Tavern Console`**（或运行下面命令）打开菜单：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\st-console.ps1 -Action menu
```

菜单长这样：

```
=========================================
        SillyTavern 控制台
=========================================
  酒馆状态 : 运行中  (pid 12345, 启动于 10-10 00:57)
  生图桥   : 运行中  (pid 12346, 端口 7861)
  酒馆目录 : D:\SillyTavern
  node     : D:\nodejs\node.exe
  本机访问 : http://192.168.1.20:8000
  手机访问 : http://100.x.y.z:8000   (Tailscale)
  日志目录 : D:\SillyTavern\logs

  [1] 启动酒馆      [2] 停止酒馆
  [3] 重启酒馆      [4] 查看状态/访问地址
  [5] 查看日志      [6] 安装桌面快捷方式
  [7] 注册开机自启（计划任务）
  [8] 显示配置信息
  [0] 退出
```

### 桌面小挂件（桌宠）：点一下就能控制

命令行要「输入数字后回车」，网页版要开浏览器——都嫌麻烦的话，把小人放到桌面上：

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File scripts\st-pet.ps1
```

装过快捷方式之后，直接双击桌面上的 **`Tavern Pet`** 就行。

怎么用：

- 一个常驻角落的小人（默认用酒馆自带的角色 Seraphina），不占任务栏、不抢焦点
- **点她一下** → 头顶弹出气泡：启动 / 停止 / 重启 / 生图桥 / 打开 / 更多 / **设置**
- **按压有 Q 弹反馈**：按下挤扁、松手带一点回弹（参考小鲸鱼挂件的做法），不喜欢可以关
- **有音效**：按压、松开、启动、停止各一声，音量可调、可整体关闭
- **拖她到屏幕边上会自动吸附**，吸在左边时她会左右翻转面朝屏幕内
- **右键她** → 快捷菜单：打开酒馆 / 启动 / 停止 / 重启 / 设置 / 查看日志 / 回到墙边 / 退出
- 平时半透明不碍事，鼠标移上去恢复清晰
- 脚边挂一个状态点：绿=运行中，红=未运行

#### 气泡里的「设置」页

不用去改配置文件，点气泡里的 **设置** 就能调，改完立刻生效、自动记住：

| 项 | 作用 |
|---|---|
| 大小 | 她在桌面上多大（140–380） |
| 不透明度 | 不碰她时有多淡 |
| 音量 | 音效音量，旁边有「试听音效」 |
| 音效 / Q弹 / 吸附边缘 | 三个开关，想关哪个关哪个 |
| 换形象… | 直接选一张 PNG（建议竖构图、透明底），立刻换 |
| 恢复默认 | 一键回到出厂设置 |

设置存在 `<项目目录>\pet-settings.json`（已在 `.gitignore` 里，不会进仓库）。

#### 音效想换成自己的

第一次运行会在 `<项目目录>\assets\sounds\` 下自动生成 4 个很小的 WAV
（`press` / `release` / `start` / `stop`）。用你自己的音频**覆盖同名文件**即可，
格式要 WAV。

**她会跟着酒馆的状态换表情**：

| 状态 | 表情 |
|---|---|
| 未运行 | 失落 |
| 启动中 / 重启中 | 紧张 |
| 运行中 | 开心 |
| 停止中 | 沮丧 |

#### 换成你自己的形象

最省事的做法：气泡 → **设置** → **换形象…**，选一张 PNG 就行。

默认形象直接读酒馆自己的角色图（`<酒馆目录>\default\content\Seraphina\*.png`），
所以**仓库里不含任何图片**，也不涉及转发别人的美术资源。

想用一套图**按状态换表情**，就在 `config.json` 里指一个目录：

```json
"pet": { "imageDir": "D:\\我的图\\q版", "width": 240 }
```

目录里放 PNG 就行，文件名随便取，但：

- 至少有一个文件名里带 `neutral` 的，当兜底
- 想按状态换表情，让文件名包含这些词：`joy`（开心）、`sadness`（失落）、
  `nervousness`（紧张）、`disappointment`（沮丧）、`fear`（害怕）
- 缺哪个就用 `neutral` 顶上；`width` 控制她在桌面上多宽（120–420）

> 效果最好的是竖构图、透明底的全身图；只有上半身的也能用。

关闭桌宠：右键 → 退出，或者

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\st-pet.ps1 -Stop
```

> 顺带说一句：`st-console.ps1` 多了个 `-NoPause` 参数（执行完不停下来等回车），
> 桌宠就是靠它来调用动作的。命令行原有用法完全不受影响。

### 命令行用法（不打开菜单）

```powershell
$s = "scripts\st-console.ps1"
powershell -ExecutionPolicy Bypass -File $s -Action start
powershell -ExecutionPolicy Bypass -File $s -Action stop
powershell -ExecutionPolicy Bypass -File $s -Action restart
powershell -ExecutionPolicy Bypass -File $s -Action status
powershell -ExecutionPolicy Bypass -File $s -Action logs
powershell -ExecutionPolicy Bypass -File $s -Action install-shortcuts
powershell -ExecutionPolicy Bypass -File $s -Action install-tasks
```

## 目录结构

```
st-console/
├── install.ps1                       一键安装
├── uninstall.ps1                     卸载（默认无痕，-Purge 清数据）
├── config.example.json               配置模板（安装后生成 config.json）
├── scripts/
│   ├── st-console.ps1                主控制台
│   ├── st-pet.ps1                    桌面小挂件（桌宠，默认用酒馆自带角色图）
│   ├── agnes-sd-bridge.mjs           生图桥（A1111 兼容 → 你的生图 API）
│   └── agnes-bridge.example.json     生图桥配置模板
├── .secrets/                         私有配置（.gitignore 忽略，不会进仓库）
└── logs/                             运行日志（.gitignore 忽略）
```

## 配置说明（`config.json`）

| 字段 | 默认 | 说明 |
|---|---|---|
| `tavernDir` | 自动探测 | SillyTavern 目录（必须包含 `server.js`） |
| `nodeExe` | 自动探测 | `node.exe` 完整路径 |
| `port` | `8000` | 酒馆监听端口 |
| `logsDir` | `logs` | 相对 `tavernDir` 的日志目录 |
| `outLog` / `errLog` | `st.out.log` / `st.err.log` | 日志文件名 |
| `bridge.enabled` | `true` | 是否启用生图桥管理 |
| `bridge.port` | `7861` | 生图桥监听端口 |
| `bridge.script` | `scripts/agnes-sd-bridge.mjs` | 相对项目根目录 |
| `bridge.configFile` | `.secrets/agnes-bridge.json` | 相对项目根目录 |
| `tasks.tavern` / `tasks.bridge` | `SillyTavern-AutoStart` / `Agnes-SDBridge-AutoStart` | 计划任务名 |
| `shortcuts.enabled` | `true` | 是否创建桌面快捷方式 |
| `shortcuts.prefix` | `Tavern` | 快捷方式名前缀（中文也可以，例如 `酒馆`） |

> `tavernDir` 没填或填错时，控制台会明确提示，并在几个常见位置自动探测。

## 手机 / 远程访问

### 方案 A：局域网（最快）

手机和电脑在同一个 Wi-Fi / 热点时，直接用状态里显示的局域网地址：

```
http://<局域网IP>:8000
```

若手机连不上，检查 Windows 防火墙是否放行了该端口（专用网络）：

```powershell
New-NetFirewallRule -DisplayName "SillyTavern $port" -Direction Inbound -Protocol TCP `
  -LocalPort $port -Action Allow -Profile Private
```

### 方案 B：Tailscale（出门也能用）

1. 电脑和手机都安装 Tailscale，登录**同一个账号**
2. 电脑上确认已登录：`tailscale up`
3. 手机上保持 Tailscale 为「已连接」（安卓建议把它的电池策略设为**不受限制**）
4. 手机浏览器打开控制台状态里显示的 `http://100.x.y.z:8000`

> 提示：Windows 上如果 Tailscale 重启后卡在 `NoState`，是因为托盘进程没起来，
> 执行 `tailscale set --unattended=true` 开启无人值守模式，并确认托盘 `tailscale-ipn.exe`
> 已加入登录自启即可。

### 关于登录密码

酒馆的账号密码在它自己的 `config.yaml` 里（`basicAuthUser`）：

```yaml
basicAuthMode: true
basicAuthUser:
  username: yourname
  password: yourpassword
```

本工具**不管理**密码，只负责起停与看日志。改完密码记得在控制台里重启酒馆。

## 生图桥：让酒馆生图走你自己的 API

### 原理

酒馆的「图像生成」扩展里，**Stable Diffusion Web UI (AUTOMATIC1111)** 这个源会：

1. `GET  {url}/sdapi/v1/options`
2. `POST {url}/sdapi/v1/txt2img` → 期望返回 `{ "images": ["<base64 png>", ...] }`

`scripts/agnes-sd-bridge.mjs` 实现了酒馆会调用的那一小撮 A1111 接口
（`txt2img` / `options` / `progress` / `sd-models` / `samplers` / `schedulers` / `upscalers` /
`latent-upscale-modes` / `sd-vae` / `sd-modules` / `interrupt`），内部转手去调你的生图 API。
**酒馆以为自己在跟 SD WebUI 说话。**

### 配置

编辑 `.secrets/agnes-bridge.json`（安装时从 `scripts/agnes-bridge.example.json` 复制）：

| 字段 | 说明 |
|---|---|
| `apiKey` | 你的生图 API Key（**只放本地，不要提交**） |
| `endpoint` | 生图接口地址，需为 OpenAI 风格的 `POST .../images/generations` |
| `models` | 暴露给酒馆的模型列表（酒馆模型下拉框里会看到） |
| `defaultModel` | 默认模型 |
| `appendNegativePrompt` | 生图 API 不支持负向提示词时保持 `false`；设为 `true` 则把负向词软约束附加到提示词 |
| `timeoutMs` | 单张超时（毫秒） |
| `maxBatch` | 单次请求最多生成几张 |
| `tiers` | 像素尺寸 → 档位映射（默认 1024→1K / 2048→2K / 3072→3K / 更大→4K） |
| `sharpPath` | 可选。若结果不是 PNG 且你想强制转码，填入 `sharp` 模块路径（不装也能用） |

### 酒馆侧设置（三步）

1. 打开酒馆 → 「扩展」→ **图像生成（Image Generation）**
2. **Source** 选 `Stable Diffusion Web UI (AUTOMATIC1111)`，**URL** 填 `http://127.0.0.1:7861`
3. 点一下 Validate（会列出模型），把 **Model** 选成你的生图模型

然后在剧情里用任意一种方式触发：

- **魔法棒按钮**：按当前对话内容生图
- **`/sd` 命令**：`/sd 一只银发精灵站在阳光森林里`
- **交互模式**：说「给我看看你现在的样子」这类要图的话，自动生图
- **角色发图模板**：`[{{char}} sends a picture that contains: {{prompt}}]`

### 自测

```powershell
# 桥是否活着
curl.exe http://127.0.0.1:7861/health
# 酒馆看到的模型列表
curl.exe http://127.0.0.1:7861/sdapi/v1/sd-models
# 直接让桥生成一张（会消耗你的 API 额度）
curl.exe -X POST http://127.0.0.1:7861/sdapi/v1/txt2img -H "Content-Type: application/json" `
  --data-binary '{\"prompt\":\"a cute cat on a keyboard\",\"width\":1024,\"height\":1024}'
```

## 日常使用建议

- **不要用「注销」**：酒馆是本工具以隐藏进程启动的，注销会杀掉它；用「锁定」(Win+L) 即可，
  锁屏/黑屏都不影响后台运行与手机访问
- **不要让电脑睡眠**：睡眠会断掉手机访问。可在电源计划里把「睡眠」设为「从不」：
  ```powershell
  powercfg /change standby-timeout-ac 0
  powercfg /change standby-timeout-dc 0
  ```
- **想更省事**：把「启动酒馆」注册成登录自启（`-Action install-tasks`），
  这样开机登录后手机直接就能玩

## 常见问题

**Q：启动报「端口被占用」/ 状态显示运行中但页面打不开？**
A：先 `-Action status` 看 pid，再 `-Action restart`；本工具的停止动作会顺带结束占用该端口的进程。

**Q：find 不到酒馆目录？**
A：在 `config.json` 里把 `tavernDir` 写成含 `server.js` 的那个目录（注意 JSON 里反斜杠要写两个：
`"D:\\SillyTavern"`）。

**Q：中文显示成乱码？**
A：`.ps1` 文件已保存为 **UTF-8 with BOM**。如果你用编辑器改过并保存成无 BOM，请改回带 BOM。

**Q：手机打不开酒馆？按顺序排查**
1. 控制台状态里酒馆是否「运行中」
2. 电脑是否睡眠了（本喵建议设为从不）
3. 用的是局域网还是 Tailscale 地址？两者要分别验证
4. Tailscale 是否连接（`tailscale status`；手机端 App 是否被系统杀后台）
5. 防火墙是否放行了端口

**Q：生图报 `SD WebUI returned an error`？**
A：看 `logs/agnes-bridge.log` 最后几行，常见原因是生图 API 限流（429）或额度用尽。

**Q：生图很慢？**
A：云端生图通常 10–30 秒/张。把酒馆里的图片尺寸调大（如 1024×1024 → 2K 档）会更慢。

## 卸载

```powershell
# 只移除快捷方式、计划任务，并停止进程（推荐）
powershell -ExecutionPolicy Bypass -File uninstall.ps1

# 连 config.json / .secrets / logs 一起删除
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -Purge
```

卸载**不会**碰 SillyTavern 自身的目录与聊天数据。

## 安全提示

- `.secrets/`、`config.json`、`logs/` 已在 `.gitignore` 中，**不要**强制提交它们
- 仓库里只有脚本，没有任何密钥；API Key 与酒馆密码请留在本地
- 酒馆的 `basicAuthMode` 建议保持开启；只在内网/Tailscale 内暴露时，简单密码也可接受，
  一旦要暴露到公网请务必换强密码

## License

[MIT](LICENSE)
