const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const { createAcpSession, loadProfile } = require('./acp')
const { createSessionStore, requiresApproval } = require('./session')
const mutations = require('./mutations')

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
    'lib/mutations.js',
    'lib/omarchy-harness.js',
    'lib/session.js',
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
  const home = env.HOME || '/tmp'
  const logPath =
    options.logPath ||
    path.join(home, '.local/state/omarchy/harness/sessions/current.jsonl')
  const store = options.store || createSessionStore({
    dir: path.dirname(logPath),
    id: options.sessionId,
    fallbackId: path.basename(logPath, '.jsonl'),
    now,
    newId: options.newId,
    approvalTimeoutMs: options.approvalTimeoutMs,
  })

  function notifyApproval(mutation) {
    exec(mutations.approvalCardArgv(mutation))
  }

  const innerWrite = store.write.bind(store)
  store.write = function write(mutation) {
    const payload =
      mutation && requiresApproval(mutation)
        ? { ...mutation, summary: mutations.approvalSummary(mutation) }
        : mutation
    const result = innerWrite(payload)
    if (result && result.pending) {
      notifyApproval(payload)
    }
    return result
  }
  const log = createSessionLog({
    logPath,
    now,
  })

  function runL1(name, args = {}) {
    const argv = mutations.argvFor(name, args)
    const result = exec(argv)
    const spec = mutations.contract(name)
    store.append({
      type: spec.auditEvent,
      op: name,
      args,
      argv,
      status: result.status == null ? 1 : result.status,
    })
    const status = result.status == null ? 1 : result.status
    return {
      ok: status === 0,
      status,
      stdout: result.stdout || '',
      stderr: result.stderr || '',
    }
  }

  function writeOp(name, args = {}) {
    const spec = mutations.contract(name)
    if (!spec) {
      const error = new Error('L2_UNREPRESENTABLE')
      error.code = 'L2_UNREPRESENTABLE'
      error.op = name
      throw error
    }
    const validated = mutations.validateArgs(name, args)
    if (!validated.ok) {
      const error = new Error(validated.code)
      error.code = validated.code
      error.fields = validated.fields
      throw error
    }
    if (spec.approval === 'optional-ask') {
      return store.write({ type: 'l1', op: name, args, ask: true })
    }
    return runL1(name, args)
  }

  function privilegeFor(spec) {
    if (!spec || spec.privilege === 'none') {
      return { path: 'none', wrapped: false }
    }
    return { path: 'unwrapped', wrapped: false, alreadyElevates: true }
  }

  function runL2(name, args = {}) {
    const spec = mutations.systemContract(name)
    const argv = mutations.argvForSystem(name, args)
    const privilege = privilegeFor(spec)
    const result = exec(argv)
    const status = result.status == null ? 1 : result.status
    store.append({
      type: spec.auditEvent,
      op: name,
      args,
      argv,
      privilege,
      status,
    })
    return {
      ok: status === 0,
      status,
      stdout: result.stdout || '',
      stderr: result.stderr || '',
      privilege,
    }
  }

  function systemOp(name, args = {}) {
    const spec = mutations.systemContract(name)
    if (!spec) {
      const error = new Error('L2_UNREPRESENTABLE')
      error.code = 'L2_UNREPRESENTABLE'
      error.op = name
      throw error
    }
    const validated = mutations.validateSystemArgs(name, args)
    if (!validated.ok) {
      const error = new Error(validated.code)
      error.code = validated.code
      error.fields = validated.fields
      throw error
    }
    mutations.argvForSystem(name, args)
    let snapshot = null
    if (spec.snapshot) {
      const snap = exec(['omarchy', 'snapshot', 'create'])
      snapshot = { status: snap.status == null ? 1 : snap.status }
      store.append({
        type: 'omarchy/snapshot',
        op: 'snapshot.create',
        stage: 'preflight',
        for: name,
        status: snapshot.status,
      })
      if (snapshot.status !== 0) {
        const error = new Error('SNAPSHOT_FAILED')
        error.code = 'SNAPSHOT_FAILED'
        throw error
      }
    }
    return store.write({
      type: 'l2',
      op: name,
      args,
      ask: true,
      snapshot,
    })
  }

  const writeMethods = {}
  for (const name of mutations.l1Names()) {
    writeMethods[name] = (args = {}) => writeOp(name, args)
  }

  const systemMethods = {}
  for (const name of mutations.l2Names()) {
    systemMethods[name] = (args = {}) => systemOp(name, args)
  }

  function decide(approvalId, decision) {
    const result = store.decide(approvalId, decision)
    if (
      result &&
      result.ok &&
      !result.idempotent &&
      result.decision &&
      result.decision.decision === 'allow' &&
      result.mutation
    ) {
      if (result.mutation.type === 'l1') {
        result.executed = runL1(result.mutation.op, result.mutation.args || {})
      }
      if (result.mutation.type === 'l2') {
        result.executed = runL2(result.mutation.op, result.mutation.args || {})
      }
    }
    return result
  }

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
    write: Object.freeze(writeMethods),
    system: Object.freeze(systemMethods),
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
      dispatch: profile.dispatch || 'l2',
      session_write: true,
      write: true,
      system: true,
      l1_surface: 'executable',
      l2_surface: 'executable',
      l1: mutations.l1Names(),
      l2: mutations.l2Names(),
      clients: profile.clients,
      tools: profile.tools,
    }
  }

  function prompt(text) {
    store.append({ type: 'turn/start', phase: integrity.phase })
    const payload = session.snapshot()
    const identity = snapshotIdentity(payload)
    const listed = store.events()
    let statusEvent = null
    for (let index = listed.length - 1; index >= 0; index -= 1) {
      const event = listed[index]
      if (event.type === 'omarchy/status' && event.modelVisible) {
        if (event.snapshot && event.snapshot.identity === identity) {
          statusEvent = event
        }
        break
      }
    }
    if (!statusEvent) {
      statusEvent = store.append({
        type: 'omarchy/status',
        modelVisible: true,
        snapshot: { identity, capturedAt: now(), version: 1 },
        payload,
      })
    }
    store.append({ type: 'user/message', text: String(text || '') })
    store.append({ type: 'turn/end', reason: 'observe-only' })
    return {
      ok: true,
      phase: integrity.phase,
      modelVisible: true,
      snapshot: statusEvent.snapshot,
      events: store.events().length,
    }
  }

  const acp = createAcpSession({
    tools,
    prompt,
    store,
    mutations,
    decide,
    write: dispatch.write,
    system: dispatch.system,
    phase: integrity.phase,
  })

  return {
    acp,
    classifyRoute,
    commands,
    decide,
    dispatch,
    dumpConfig,
    log,
    mutations,
    prompt,
    session,
    store,
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
    'session_write',
    'write',
    'system',
    'l1_surface',
    'l2_surface',
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

  if (command === 'session') {
    const action = argv[1]
    try {
      if (action === 'state') {
        return { status: 0, stdout: JSON.stringify(harness.store.state(), null, 2) + '\n' }
      }
      if (action === 'checkpoint') {
        return { status: 0, stdout: JSON.stringify(harness.store.write({ type: 'checkpoint' }), null, 2) + '\n' }
      }
      if (action === 'metadata') {
        const title = argv.slice(2).join(' ').trim()
        return {
          status: 0,
          stdout: JSON.stringify(harness.store.write({ type: 'metadata', patch: { title } }), null, 2) + '\n',
        }
      }
      if (action === 'reset') {
        return { status: 0, stdout: JSON.stringify(harness.store.write({ type: 'reset' }), null, 2) + '\n' }
      }
      if (action === 'resume') {
        const sessionId = argv[2]
        if (!sessionId) {
          return { status: 2, stdout: '', stderr: 'omarchy-harness-host: resume needs a session id\n' }
        }
        return { status: 0, stdout: JSON.stringify(harness.store.resume(sessionId), null, 2) + '\n' }
      }
      if (action === 'fork') {
        return { status: 0, stdout: JSON.stringify(harness.store.fork(), null, 2) + '\n' }
      }
    } catch (error) {
      return { status: 1, stdout: '', stderr: String(error.message) + '\n' }
    }
    return { status: 2, stdout: '', stderr: 'Usage: omarchy-harness-host session state|checkpoint|metadata|reset|resume|fork\n' }
  }

  if (command === 'write') {
    const name = argv[1]
    const raw = argv[2] || '{}'
    if (!name) {
      return { status: 2, stdout: '', stderr: 'omarchy-harness-host: write <op> [json]\n' }
    }
    try {
      const method = harness.dispatch.write && harness.dispatch.write[name]
      if (typeof method !== 'function') {
        const error = new Error('L2_UNREPRESENTABLE')
        error.code = 'L2_UNREPRESENTABLE'
        throw error
      }
      const result = method(JSON.parse(raw))
      return { status: 0, stdout: JSON.stringify(result, null, 2) + '\n' }
    } catch (error) {
      return {
        status: 1,
        stdout: '',
        stderr: String(error.code || error.message) + '\n',
      }
    }
  }

  if (command === 'system') {
    const name = argv[1]
    const raw = argv[2] || '{}'
    if (!name) {
      return { status: 2, stdout: '', stderr: 'omarchy-harness-host: system <op> [json]\n' }
    }
    try {
      const method = harness.dispatch.system && harness.dispatch.system[name]
      if (typeof method !== 'function') {
        const error = new Error('L2_UNREPRESENTABLE')
        error.code = 'L2_UNREPRESENTABLE'
        throw error
      }
      const result = method(JSON.parse(raw))
      return { status: 0, stdout: JSON.stringify(result, null, 2) + '\n' }
    } catch (error) {
      return {
        status: 1,
        stdout: '',
        stderr: String(error.code || error.message) + '\n',
      }
    }
  }

  if (command === 'approval') {
    const action = argv[1]
    try {
      if (action === 'decide') {
        const approvalId = argv[2]
        const decision = argv[3]
        if (!approvalId || !decision) {
          return { status: 2, stdout: '', stderr: 'omarchy-harness-host: approval decide <id> allow|deny\n' }
        }
        const decide = harness.decide || ((id, choice) => harness.store.decide(id, choice))
        return {
          status: 0,
          stdout: JSON.stringify(decide(approvalId, decision), null, 2) + '\n',
        }
      }
    } catch (error) {
      return { status: 1, stdout: '', stderr: String(error.message) + '\n' }
    }
    return { status: 2, stdout: '', stderr: 'Usage: omarchy-harness-host approval decide <id> allow|deny\n' }
  }

  if (command === 'serve') {
    return { status: 0, stdout: '', stderr: '', serve: true }
  }

  return {
    status: 2,
    stdout: '',
    stderr: 'Usage: omarchy-harness-host dump-config|prompt|tool|session|approval|write|system|serve\n',
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
  mutations,
  normalizeRoute,
  overlayFiles,
  printDumpConfig,
  runCli,
  snapshotIdentity,
  sortedJson,
}
