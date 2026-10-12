#!/usr/bin/env node
/**
 * agnes-sd-bridge — 把「任意 OpenAI 兼容的生图 API」伪装成 Stable Diffusion WebUI (AUTOMATIC1111)
 * ---------------------------------------------------------------------------------------------
 * 用途：SillyTavern（酒馆）的图像生成扩展支持 "Stable Diffusion Web UI (AUTOMATIC1111)" 这一源，
 * 它会向 {url}/sdapi/v1/txt2img 发请求，并期望 A1111 形状的响应 { images: [base64...] }。
 * 本桥实现酒馆会调用的那一小撮 A1111 接口，内部转手去调你的生图 API（默认演示 Agnes）。
 * 于是酒馆以为自己在跟 SD WebUI 说话，实际使用的是你自己的云端生图服务。
 *
 * 启动：
 *   node scripts/agnes-sd-bridge.mjs --config .secrets/agnes-bridge.json
 *   （也可用环境变量 AGNES_BRIDGE_CONFIG 指定配置路径）
 *
 * 配置文件见 scripts/agnes-bridge.example.json。日志默认写到 <项目根>/logs/agnes-bridge.log。
 */
import http from 'node:http'
import { readFile, appendFile, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const PROJECT_DIR = path.dirname(SCRIPT_DIR)

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]
    if (a === '--config' || a === '-c') { out.config = argv[i + 1]; i += 1 }
    else if (a.startsWith('--config=')) { out.config = a.slice('--config='.length) }
    else if (a === '--help' || a === '-h') { out.help = true }
  }
  return out
}

const args = parseArgs(process.argv.slice(2))
if (args.help) {
  console.log('用法: node agnes-sd-bridge.mjs [--config <配置文件>]')
  process.exit(0)
}

function resolveConfigPath() {
  const candidates = [
    args.config,
    process.env.AGNES_BRIDGE_CONFIG,
    path.join(PROJECT_DIR, '.secrets', 'agnes-bridge.json'),
    path.join(SCRIPT_DIR, 'agnes-bridge.json'),
    path.join(process.cwd(), 'agnes-bridge.json'),
  ].filter(Boolean)
  for (const c of candidates) {
    if (existsSync(c)) return path.resolve(c)
  }
  throw new Error(`找不到配置文件，试过：\n  ${candidates.join('\n  ')}\n请参考 scripts/agnes-bridge.example.json 创建。`)
}

let config = null
let logPath = ''
let sharpModule = null
let inFlight = 0
let interrupted = false

async function log(...parts) {
  const line = `[${new Date().toISOString()}] ${parts.join(' ')}`
  process.stdout.write(line + '\n')
  if (!logPath) return
  try {
    await mkdir(path.dirname(logPath), { recursive: true })
    await appendFile(logPath, line + '\n')
  } catch { /* 日志失败不影响生图 */ }
}

const RATIOS = ['1:1', '3:4', '4:3', '16:9', '9:16', '2:3', '3:2', '21:9']
const RATIO_VALUE = {
  '1:1': 1, '3:4': 3 / 4, '4:3': 4 / 3, '16:9': 16 / 9,
  '9:16': 9 / 16, '2:3': 2 / 3, '3:2': 3 / 2, '21:9': 21 / 9,
}

/** 按最长边选尺寸档位（1K / 2K / 3K / 4K），可用 config.tiers 覆盖 */
function pickTier(width, height) {
  const tiers = config.tiers ?? [
    { max: 1024, name: '1K' }, { max: 2048, name: '2K' },
    { max: 3072, name: '3K' }, { max: Number.MAX_SAFE_INTEGER, name: '4K' },
  ]
  const longest = Math.max(width || 1024, height || 1024)
  for (const t of tiers) if (longest <= t.max) return t.name
  return tiers[tiers.length - 1].name
}

/** 取最接近的受支持宽高比（对数距离） */
function pickRatio(width, height) {
  const target = (width || 1) / (height || 1)
  let best = '1:1'
  let bestDiff = Infinity
  for (const r of RATIOS) {
    const d = Math.abs(Math.log(RATIO_VALUE[r] / target))
    if (d < bestDiff) { bestDiff = d; best = r }
  }
  return best
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', (c) => {
      chunks.push(c)
      if (Buffer.concat(chunks).length > 32 * 1024 * 1024) reject(new Error('请求体过大'))
    })
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8')
      if (raw.trim() === '') return resolve({})
      try { resolve(JSON.parse(raw)) } catch { resolve({}) }
    })
    req.on('error', reject)
  })
}

const json = (res, value, status = 200) => {
  const body = JSON.stringify(value)
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) })
  res.end(body)
}

/** 惰性加载 sharp（仅用于把非 PNG 结果转成 PNG；缺失时原样返回，不阻断生图） */
async function getSharp() {
  if (sharpModule !== null) return sharpModule
  const require = createRequire(import.meta.url)
  const candidates = [config.sharpPath, 'sharp'].filter(Boolean)
  for (const c of candidates) {
    try {
      sharpModule = require(c)
      await log(`sharp 已加载: ${c}`)
      return sharpModule
    } catch { /* 试下一个 */ }
  }
  sharpModule = false
  await log('sharp 不可用（非 PNG 结果将原样返回，浏览器通常也能识别）')
  return false
}

function sniffImage(bytes) {
  if (bytes.length > 7 && bytes[0] === 0x89 && bytes.toString('ascii', 1, 4) === 'PNG') return 'png'
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8) return 'jpg'
  if (bytes.length > 11 && bytes.toString('ascii', 8, 12) === 'WEBP') return 'webp'
  return 'unknown'
}

/** 酒馆前端把结果当 PNG 处理，这里尽量保证是 PNG */
async function ensurePng(bytes, label) {
  const kind = sniffImage(bytes)
  if (kind === 'png') return bytes
  const sharp = await getSharp()
  if (sharp) {
    try {
      const out = await sharp(bytes).png().toBuffer()
      await log(`${label}: ${kind} → PNG (${bytes.length} → ${out.length} 字节)`)
      return out
    } catch (error) {
      await log(`${label}: sharp 转码失败 ${error?.message ?? error}，原样返回 ${kind}`)
      return bytes
    }
  }
  await log(`${label}: 结果是 ${kind}，原样返回`)
  return bytes
}

async function generateOne({ prompt, negative, width, height, seed, model, index }) {
  const body = {
    model,
    prompt,
    size: pickTier(width, height),
    ratio: pickRatio(width, height),
    ...(config.extraBody ?? {}),
  }
  if (config.responseFormat === 'b64_json') {
    body.extra_body = { ...(body.extra_body ?? {}), response_format: 'b64_json' }
  }
  if (config.appendNegativePrompt && negative) {
    body.prompt = `${prompt}\n(不要出现以下内容: ${negative})`
  }
  if (Number.isInteger(seed) && seed >= 0) body.seed = seed

  await log(`#${index} → ${config.endpoint} model=${model} size=${body.size} ratio=${body.ratio} prompt=${JSON.stringify(prompt).slice(0, 140)}`)

  const response = await fetch(config.endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(config.timeoutMs),
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`生图 API ${response.status}: ${text.slice(0, 300)}`)

  const payload = JSON.parse(text)
  const item = payload?.data?.[0]
  if (!item) throw new Error(`生图 API 未返回图片: ${text.slice(0, 200)}`)

  let bytes
  if (typeof item.b64_json === 'string' && item.b64_json !== '') {
    bytes = Buffer.from(item.b64_json, 'base64')
  } else if (typeof item.url === 'string' && item.url !== '') {
    const dl = await fetch(item.url, { signal: AbortSignal.timeout(config.timeoutMs) })
    if (!dl.ok) throw new Error(`下载生成结果失败 ${dl.status}`)
    bytes = Buffer.from(await dl.arrayBuffer())
  } else {
    throw new Error('生图 API 返回既无 b64_json 也无 url')
  }

  const png = await ensurePng(bytes, `#${index}`)
  return png.toString('base64')
}

async function handleTxt2Img(body) {
  const prompt = String(body.prompt ?? '').trim()
  if (prompt === '') throw new Error('prompt 为空')
  const width = Number(body.width) || 1024
  const height = Number(body.height) || 1024
  const negative = typeof body.negative_prompt === 'string' ? body.negative_prompt.trim() : ''
  const batch = Math.max(1, Math.min(config.maxBatch, Number(body.batch_size) || 1))
  const iterations = Math.max(1, Math.min(config.maxBatch, Number(body.n_iter) || 1))

  const checkpoint = body?.override_settings?.sd_model_checkpoint
  let model = config.defaultModel
  if (typeof checkpoint === 'string') {
    const name = checkpoint.split(' ')[0]
    if (config.models.includes(name)) model = name
  }

  const images = []
  const started = Date.now()
  interrupted = false
  for (let i = 0; i < batch * iterations; i += 1) {
    if (interrupted) { await log('收到 interrupt，提前结束'); break }
    inFlight += 1
    try {
      images.push(await generateOne({ prompt, negative, width, height, seed: body.seed, model, index: i + 1 }))
    } finally {
      inFlight -= 1
    }
  }
  await log(`完成 ${images.length} 张，用时 ${((Date.now() - started) / 1000).toFixed(1)}s`)
  return {
    images,
    parameters: {
      prompt, negative_prompt: negative, width, height,
      batch_size: batch, n_iter: iterations, steps: body.steps,
      cfg_scale: body.cfg_scale, seed: body.seed, sampler_name: body.sampler_name, model,
    },
    info: JSON.stringify({ model, size: pickTier(width, height), ratio: pickRatio(width, height), infra: 'sd-bridge' }),
  }
}

const routes = {
  'GET /': (_b, res) => json(res, { ok: true, bridge: 'sd-bridge', model: config.defaultModel }),
  'GET /health': (_b, res) => json(res, { ok: true, inFlight }),
  'GET /sdapi/v1/sd-models': (_b, res) => json(res, config.models.map((id) => ({
    title: `${id} [bridge]`, model_name: id, hash: null, sha256: null,
    filename: `/models/bridge/${id}.safetensors`, config: null,
  }))),
  'GET /sdapi/v1/options': (_b, res) => json(res, { sd_model_checkpoint: config.defaultModel, sd_vae: 'Automatic', CLIP_stop_at_last_layers: 1 }),
  'POST /sdapi/v1/options': (_b, res) => json(res, {}),
  'GET /sdapi/v1/progress': (_b, res) => json(res, {
    progress: 0, eta_relative: 0,
    state: { skipped: false, interrupted: false, job: '', job_count: inFlight, job_no: inFlight, sampling_step: 0, sampling_steps: 0 },
    current_image: null, textinfo: null,
  }),
  'POST /sdapi/v1/interrupt': (_b, res) => { interrupted = true; json(res, {}) },
  'GET /sdapi/v1/samplers': (_b, res) => json(res, [{ name: 'Euler', aliases: ['euler'], options: {} }, { name: 'DPM++ 2M', aliases: ['dpmpp_2m'], options: {} }]),
  'GET /sdapi/v1/schedulers': (_b, res) => json(res, [{ name: 'Automatic', label: 'Automatic', aliases: [] }, { name: 'Karras', label: 'Karras', aliases: ['karras'] }]),
  'GET /sdapi/v1/upscalers': (_b, res) => json(res, [{ name: 'None', model_name: null, model_path: null, model_url: null, scale: 1 }]),
  'GET /sdapi/v1/latent-upscale-modes': (_b, res) => json(res, [{ name: 'Latent' }]),
  'GET /sdapi/v1/sd-vae': (_b, res) => json(res, [{ model_name: 'Automatic', filename: '', config: null }]),
  'GET /sdapi/v1/sd-modules': (_b, res) => json(res, [{ model_name: 'None' }]),
}

const server = http.createServer(async (req, res) => {
  let key = `${req.method} ${req.url}`
  try {
    // 解析 URL 也放进 try：畸形请求行会让它抛错，落在外面就是未捕获的 rejection
    const url = new URL(req.url, `http://${req.headers.host ?? '127.0.0.1'}`)
    key = `${req.method} ${url.pathname}`
    if (key === 'POST /sdapi/v1/txt2img') {
      const body = await readJsonBody(req)
      return json(res, await handleTxt2Img(body))
    }
    const handler = routes[key]
    if (handler) {
      const body = req.method === 'POST' ? await readJsonBody(req) : {}
      return handler(body, res)
    }
    await log(`未实现的请求: ${key}`)
    return json(res, { detail: `sd-bridge 未实现 ${key}` }, 404)
  } catch (error) {
    await log(`处理 ${key} 失败: ${error?.message ?? error}`)
    return json(res, { detail: String(error?.message ?? error) }, 500)
  }
})

async function main() {
  const configPath = resolveConfigPath()
  // 记事本存过的 JSON 会带 BOM，JSON.parse 不认，直接抛 "Unexpected token"，
  // 桥就再也起不来了 —— 这里先剥掉
  const rawConfig = await readFile(configPath, 'utf8')
  config = JSON.parse(rawConfig.replace(/^﻿/, ''))
  if (!config.apiKey) throw new Error(`配置缺少 apiKey: ${configPath}`)
  config.host = config.host ?? '127.0.0.1'
  config.port = Number(config.port) || 7861
  config.endpoint = config.endpoint ?? 'https://apihub.agnes-ai.com/v1/images/generations'
  config.models = Array.isArray(config.models) && config.models.length > 0 ? config.models : ['agnes-image-2.5-flash']
  config.defaultModel = config.defaultModel ?? config.models[0]
  config.timeoutMs = Number(config.timeoutMs) || 300000
  config.maxBatch = Number(config.maxBatch) || 4
  config.appendNegativePrompt = config.appendNegativePrompt === true
  config.responseFormat = config.responseFormat ?? 'b64_json'
  logPath = config.logFile ?? path.join(PROJECT_DIR, 'logs', 'agnes-bridge.log')

  await log(`sd-bridge 启动 | 配置=${configPath}`)
  await log(`监听 http://${config.host}:${config.port} | 模型=${config.models.join(', ')}`)
  // 端口被占（EADDRINUSE）时 listen 抛的是 'error' 事件；不接住就是未捕获异常，
  // 进程直接崩，日志里连一句「启动失败」都不会有
  server.on('error', async (error) => {
    await log(`监听失败: ${error?.message ?? error}`)
    process.exit(1)
  })
  server.listen(config.port, config.host, () => log(`已就绪：把酒馆生图源设为 A1111，URL 填 http://${config.host}:${config.port}`))
}

main().catch(async (error) => {
  await log(`启动失败: ${error?.stack ?? error}`)
  process.exit(1)
})
