const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const { createAcpSession, loadProfile } = require('./acp')

const HARNESS_ROOT = path.resolve(__dirname, '..')
const INTEGRITY_PATH = path.join(HARNESS_ROOT, 'integrity.json')

const READONLY_ROUTES = new Set([
  'theme list',
  'theme current',
  'font list',
  'plugin list',
  'version',
  'version channel',
  'version branch',
  'commands',
])

const INTERACTIVE_PREFIXES = ['setup', 'install', 'menu']
const HIDDEN_PREFIXES = ['apply', 'provision']

function loadIntegrity() {
  return JSON.parse(fs.readFileSync(INTEGRITY_PATH, 'utf8'))
}

function normalizeRoute(route) {
  return String(route || '')
    .trim()
    .replace(/^omarchy\s+/, '')
    .replace(/\s+/g, ' ')
}

function isInteractiveRoute(route) {
  const normalized = normalizeRoute(route)
  return INTERACTIVE_PREFIXES.some(
    (prefix) => normalized === prefix || normalized.startsWith(prefix + ' ')
  )
}

function isHiddenRoute(route, catalogEntry) {
  if (catalogEntry && catalogEntry.hidden) {
    return true
  }
  const normalized = normalizeRoute(route)
  return HIDDEN_PREFIXES.some(
    (prefix) => normalized === prefix || normalized.startsWith(prefix + ' ')
  )
}

function classifyRoute(route, catalogEntry) {
  const normalized = normalizeRoute(route)
  if (READONLY_ROUTES.has(normalized)) {
    return 'readonly'
  }
  if (isHiddenRoute(normalized, catalogEntry)) {
    return 'hidden'
  }
  if (isInteractiveRoute(normalized)) {
    return 'interactive'
  }
  return 'write'
}

function sortedJson(value) {
  if (Array.isArray(value)) {
    return '[' + value.map(sortedJson).join(',') + ']'
  }
  if (value && typeof value === 'object') {
    const keys = Object.keys(value).sort()
    return (
      '{' +
      keys
        .map((key) => JSON.stringify(key) + ':' + sortedJson(value[key]))
        .join(',') +
      '}'
    )
  }
  return JSON.stringify(value)
}

function snapshotIdentity(payload) {
  return crypto.createHash('sha256').update(sortedJson(payload)).digest('hex')
}

function hashPaths(root, relativePaths) {
  const hash = crypto.createHash('sha256')
  for (const relative of relativePaths.slice().sort()) {
    const filePath = path.join(root, relative)
    hash.update(relative)
    hash.update('\0')
    hash.update(fs.readFileSync(filePath))
    hash.update('\0')
  }
  return hash.digest('hex')
}

function overlayFiles() {
  return [
    'host.js',
    'integrity.json',
    'lib/acp.js',
    'lib/omarchy-harness.js',
    'profile/omarchy.json',
  ]
}

function bundleSha256() {
  return hashPaths(HARNESS_ROOT, overlayFiles())
}

function defaultNow() {
  return new Date().toISOString()
}

function defaultExec(argv, env) {
  const result = spawnSync(argv[0], argv.slice(1), {
    encoding: 'utf8',
    env: env || process.env,
  })

  return {
    status: result.status == null ? 1 : result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  }
}

function defaultHyprctl(args, env) {
  return defaultExec(['hyprctl', ...args], env)
}

function createSessionLog(options) {
  const now = options.now || defaultNow
  const events = []
  const logPath = options.logPath

  if (logPath) {
    fs.mkdirSync(path.dirname(logPath), { recursive: true })
  }

  function append(event) {
    const record = { ...event, at: event.at || now() }
    events.push(record)
    if (logPath) {
      fs.appendFileSync(logPath, JSON.stringify(record) + '\n')
    }
    return record
  }

  function lastModelVisibleStatus() {
    for (let index = events.length - 1; index >= 0; index -= 1) {
      const event = events[index]
      if (event.type === 'omarchy/status' && event.modelVisible) {
        return event
      }
    }
    return null
  }

  function recordModelVisibleStatus(payload) {
    const identity = snapshotIdentity(payload)
    const last = lastModelVisibleStatus()
    if (last && last.snapshot && last.snapshot.identity === identity) {
      return last
    }

    return append({
      type: 'omarchy/status',
      modelVisible: true,
      snapshot: {
        identity,
        capturedAt: now(),
        version: 1,
      },
      payload,
    })
  }

  return {
    append,
    events,
    lastModelVisibleStatus,
    recordModelVisibleStatus,
  }
}

function createHarness(options = {}) {
  const env = options.env || process.env
  const exec = options.exec || ((argv) => defaultExec(argv, env))
  const hyprctl = options.hyprctl || ((args) => defaultHyprctl(args, env))
  const now = options.now || defaultNow
  const integrity = options.integrity || loadIntegrity()
  const log = createSessionLog({
    logPath: options.logPath,
    now,
  })

  const dispatch = Object.freeze({
    readonly: Object.freeze({
      execute(route, args = []) {
        const kind = classifyRoute(route)
        if (kind !== 'readonly') {
          const error = new Error(
            `dispatch.readonly cannot run ${kind} route: ${normalizeRoute(route)}`
          )
          error.code =
            kind === 'write' ? 'WRITE_ROUTE_IMPOSSIBLE' : `${kind.toUpperCase()}_ROUTE`
          error.kind = kind
          error.route = normalizeRoute(route)
          throw error
        }

        return exec(['omarchy', ...normalizeRoute(route).split(' '), ...args])
      },
    }),
  })

  function readStdout(route, args) {
    const result = dispatch.readonly.execute(route, args)
    if (result.status !== 0) {
      return null
    }
    return result.stdout.replace(/\s+$/, '')
  }

  function parseJson(text, fallback) {
    if (!text) {
      return fallback
    }
    try {
      return JSON.parse(text)
    } catch {
      return fallback
    }
  }

  const commands = {
    list({ all = false } = {}) {
      const args = []
      if (all) {
        args.push('--all')
      }
      args.push('--json')
      const result = dispatch.readonly.execute('commands', args)
      return parseJson(result.stdout, { ok: false, commands: [] })
    },
  }

  const windows = {
    list() {
      const clients = parseJson(hyprctl(['-j', 'clients']).stdout, [])
      const workspaces = parseJson(hyprctl(['-j', 'workspaces']).stdout, [])
      const active = parseJson(hyprctl(['-j', 'activewindow']).stdout, null)
      const available = Array.isArray(clients)
      return {
        available,
        clients: available ? clients : [],
        workspaces: Array.isArray(workspaces) ? workspaces : [],
        focused: active && active.address ? active : null,
      }
    },
  }

  const session = {
    snapshot() {
      const commandCatalog = commands.list()
      const pluginText = readStdout('plugin list', ['--json'])
      return {
        theme: readStdout('theme current'),
        version: readStdout('version'),
        channel: readStdout('version channel'),
        plugins: parseJson(pluginText, []),
        windows: windows.list(),
        commandCount: Array.isArray(commandCatalog.commands)
          ? commandCatalog.commands.length
          : 0,
      }
    },
  }

  const tools = {
    omarchy_status() {
      return session.snapshot()
    },
    omarchy_commands(query = {}) {
      const catalog = commands.list({ all: false })
      const needle = String(query.query || '').toLowerCase()
      const listed = Array.isArray(catalog.commands) ? catalog.commands : []
      return listed.filter((entry) => {
        if (entry.hidden) {
          return false
        }
        if (!needle) {
          return true
        }
        const haystack = [entry.route, entry.group, entry.name, entry.summary]
          .filter(Boolean)
          .join(' ')
          .toLowerCase()
        return haystack.includes(needle)
      })
    },
    omarchy_windows() {
      return windows.list()
    },
    omarchy_theme_list() {
      const text = readStdout('theme list') || ''
      return text.split('\n').filter(Boolean)
    },
    omarchy_font_list() {
      const text = readStdout('font list') || ''
      return text.split('\n').filter(Boolean)
    },
    omarchy_plugin_list() {
      return parseJson(readStdout('plugin list', ['--json']), [])
    },
  }

  function dumpConfig() {
    const profile = loadProfile()
    return {
      profile: integrity.profile,
      dsh: integrity.dsh.version,
      dsh_commit: integrity.dsh.commit,
      node: String(process.version || '').replace(/^v/, ''),
      bundle_sha256: bundleSha256(),
      preset: integrity.preset,
      approval: integrity.approval,
      overlay: integrity.overlay,
      phase: integrity.phase,
      dispatch: 'readonly',
      clients: profile.clients,
      tools: profile.tools,
    }
  }

  function prompt(text) {
    log.append({ type: 'turn/start', phase: 1 })
    const payload = session.snapshot()
    const statusEvent = log.recordModelVisibleStatus(payload)
    log.append({ type: 'user/message', text: String(text || '') })
    log.append({ type: 'turn/end', reason: 'phase1-observe-only' })
    return {
      ok: true,
      phase: 1,
      modelVisible: true,
      snapshot: statusEvent.snapshot,
      events: log.events.length,
    }
  }

  const acp = createAcpSession({ tools, prompt })

  return {
    acp,
    classifyRoute,
    commands,
    dispatch,
    dumpConfig,
    log,
    prompt,
    session,
    tools,
    windows,
  }
}

function printDumpConfig(config) {
  const lines = ['Harness:']
  for (const key of [
    'profile',
    'dsh',
    'dsh_commit',
    'node',
    'bundle_sha256',
    'preset',
    'approval',
    'overlay',
    'phase',
    'dispatch',
  ]) {
    const value = config[key] == null ? '' : config[key]
    lines.push(`  ${key}: ${value}`)
  }
  return lines.join('\n')
}

function runCli(argv, options = {}) {
  const command = argv[0]
  const harness = options.harness || createHarness(options)

  if (command === 'dump-config') {
    const config = harness.dumpConfig()
    if (argv.includes('--json')) {
      return { status: 0, stdout: JSON.stringify(config, null, 2) + '\n' }
    }
    return { status: 0, stdout: printDumpConfig(config) + '\n' }
  }

  if (command === 'prompt') {
    const text = argv.slice(1).join(' ').trim()
    if (!text) {
      return { status: 2, stdout: '', stderr: 'omarchy-harness-host: prompt needs text\n' }
    }
    const result = harness.prompt(text)
    return { status: 0, stdout: JSON.stringify(result, null, 2) + '\n' }
  }

  if (command === 'tool') {
    const name = argv[1]
    if (!name || typeof harness.tools[name] !== 'function') {
      return { status: 2, stdout: '', stderr: 'omarchy-harness-host: unknown tool\n' }
    }
    const payload = harness.tools[name]()
    return { status: 0, stdout: JSON.stringify(payload, null, 2) + '\n' }
  }

  if (command === 'serve') {
    return { status: 0, stdout: '', stderr: '', serve: true }
  }

  return {
    status: 2,
    stdout: '',
    stderr: 'Usage: omarchy-harness-host dump-config|prompt|tool|serve\n',
  }
}

module.exports = {
  HARNESS_ROOT,
  HIDDEN_PREFIXES,
  INTERACTIVE_PREFIXES,
  READONLY_ROUTES,
  bundleSha256,
  classifyRoute,
  createHarness,
  createSessionLog,
  loadIntegrity,
  loadProfile,
  normalizeRoute,
  overlayFiles,
  printDumpConfig,
  runCli,
  snapshotIdentity,
  sortedJson,
}
