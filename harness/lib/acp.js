const fs = require('fs')
const path = require('path')
const mutations = require('./mutations')

const PROFILE_PATH = path.resolve(__dirname, '../profile/omarchy.json')
const READONLY_TOOLS = [
  'omarchy_status',
  'omarchy_commands',
  'omarchy_windows',
  'omarchy_theme_list',
  'omarchy_font_list',
  'omarchy_plugin_list',
]
const SESSION_TOOLS = [
  'session_metadata',
  'session_checkpoint',
  'session_fork',
  'session_resume',
  'session_reset',
  'approval_decide',
]

function loadProfile() {
  return JSON.parse(fs.readFileSync(PROFILE_PATH, 'utf8'))
}

function callSessionTool(harness, name, args) {
  const store = harness.store
  if (name === 'session_metadata') {
    return store.write({ type: 'metadata', patch: { title: args.title || '' } })
  }
  if (name === 'session_checkpoint') {
    return store.write({ type: 'checkpoint' })
  }
  if (name === 'session_fork') {
    return store.fork()
  }
  if (name === 'session_resume') {
    return store.resume(args.sessionId)
  }
  if (name === 'session_reset') {
    return store.write({ type: 'reset' })
  }
  if (name === 'approval_decide') {
    const decide = harness.decide || ((id, decision) => store.decide(id, decision))
    return decide(args.approvalId, args.decision)
  }
  const error = new Error('unknown session tool')
  error.code = 'UNKNOWN_TOOL'
  throw error
}

function l1ToolNames() {
  return mutations.l1Names()
}

function jsonRpcResult(id, result) {
  return { jsonrpc: '2.0', id, result }
}

function jsonRpcError(id, code, message, data) {
  const error = { code, message }
  if (data !== undefined) {
    error.data = data
  }
  return { jsonrpc: '2.0', id, error }
}

function createAcpSession(harness) {
  const profile = loadProfile()
  let sessionId = null

  function initialize(id) {
    const tools = READONLY_TOOLS.concat(SESSION_TOOLS, l1ToolNames())
    return jsonRpcResult(id, {
      protocolVersion: 1,
      serverInfo: {
        name: 'omarchy-harness',
        phase: harness.phase || 3,
      },
      capabilities: {
        loadSession: true,
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      profile: profile.name,
      dispatch: profile.dispatch || 'l1',
      tools,
      write: true,
      system: false,
      sessionWrite: true,
      l1: mutations.l1Names(),
    })
  }

  function sessionNew(id) {
    sessionId = 'omarchy-session'
    return jsonRpcResult(id, { sessionId })
  }

  function toolsCall(id, params) {
    const name = params && params.name
    const args = params && params.arguments ? params.arguments : {}
    if (READONLY_TOOLS.includes(name)) {
      const tool = harness.tools[name]
      const content = tool(args)
      return jsonRpcResult(id, { content, isError: false })
    }
    if (SESSION_TOOLS.includes(name) && harness.store) {
      try {
        const content = callSessionTool(harness, name, args)
        return jsonRpcResult(id, { content, isError: false })
      } catch (error) {
        return jsonRpcError(id, -32003, error.code || error.message, { tool: name })
      }
    }
    if (l1ToolNames().includes(name) && harness.write && typeof harness.write[name] === 'function') {
      try {
        const content = harness.write[name](args)
        return jsonRpcResult(id, { content, isError: false })
      } catch (error) {
        return jsonRpcError(id, -32001, error.code || error.message, { tool: name })
      }
    }
    return jsonRpcError(id, -32001, 'L2_UNREPRESENTABLE', {
      tool: name,
      dispatch: 'l1',
    })
  }

  function sessionPrompt(id, params) {
    if (!sessionId) {
      return jsonRpcError(id, -32002, 'session not created')
    }
    const text =
      typeof params === 'string'
        ? params
        : (params && params.prompt) || (params && params.text) || ''
    const result = harness.prompt(String(text))
    return jsonRpcResult(id, result)
  }

  function storeCall(id, fn) {
    try {
      return jsonRpcResult(id, fn())
    } catch (error) {
      return jsonRpcError(id, -32003, error.code || error.message)
    }
  }

  function handle(message) {
    if (!message || typeof message !== 'object') {
      return jsonRpcError(null, -32600, 'invalid request')
    }
    const { id, method, params } = message
    if (method === 'initialize') {
      return initialize(id)
    }
    if (method === 'session/new') {
      return sessionNew(id)
    }
    if (method === 'session/prompt') {
      return sessionPrompt(id, params)
    }
    if (method === 'tools/call') {
      return toolsCall(id, params || {})
    }
    if (method === 'session/checkpoint') {
      return storeCall(id, () => harness.store.write({ type: 'checkpoint' }))
    }
    if (method === 'session/fork') {
      return storeCall(id, () => harness.store.fork())
    }
    if (method === 'session/resume') {
      return storeCall(id, () => harness.store.resume(params && params.sessionId))
    }
    if (method === 'session/state') {
      return storeCall(id, () => harness.store.state())
    }
    if (method === 'approval/decide') {
      const decide = harness.decide || ((approvalId, decision) => harness.store.decide(approvalId, decision))
      return storeCall(id, () =>
        decide(params && params.approvalId, params && params.decision)
      )
    }
    if (method === 'ping') {
      return jsonRpcResult(id, { ok: true })
    }
    return jsonRpcError(id, -32601, 'method not found', { method })
  }

  return {
    handle,
    profile,
    tools: READONLY_TOOLS.concat(SESSION_TOOLS, l1ToolNames()),
  }
}

function parseAcpLine(line) {
  const trimmed = String(line || '').trim()
  if (!trimmed || trimmed === 'ping') {
    return { plain: trimmed || 'ping' }
  }
  return { message: JSON.parse(trimmed) }
}

module.exports = {
  PROFILE_PATH,
  READONLY_TOOLS,
  SESSION_TOOLS,
  createAcpSession,
  loadProfile,
  parseAcpLine,
}
