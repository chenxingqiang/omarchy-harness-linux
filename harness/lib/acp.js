const fs = require('fs')
const path = require('path')

const PROFILE_PATH = path.resolve(__dirname, '../profile/omarchy.json')
const READONLY_TOOLS = [
  'omarchy_status',
  'omarchy_commands',
  'omarchy_windows',
  'omarchy_theme_list',
  'omarchy_font_list',
  'omarchy_plugin_list',
]

function loadProfile() {
  return JSON.parse(fs.readFileSync(PROFILE_PATH, 'utf8'))
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
    return jsonRpcResult(id, {
      protocolVersion: 1,
      serverInfo: {
        name: 'omarchy-harness',
        phase: 1,
      },
      capabilities: {
        loadSession: false,
        promptCapabilities: { image: false, audio: false, embeddedContext: false },
      },
      profile: profile.name,
      dispatch: 'readonly',
      tools: READONLY_TOOLS.slice(),
      write: false,
      system: false,
    })
  }

  function sessionNew(id) {
    sessionId = 'omarchy-session'
    return jsonRpcResult(id, { sessionId })
  }

  function toolsCall(id, params) {
    const name = params && params.name
    if (!READONLY_TOOLS.includes(name)) {
      return jsonRpcError(id, -32001, 'WRITE_ROUTE_IMPOSSIBLE', {
        tool: name,
        dispatch: 'readonly',
      })
    }
    const tool = harness.tools[name]
    const content = tool(params && params.arguments ? params.arguments : {})
    return jsonRpcResult(id, { content, isError: false })
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
    if (method === 'ping') {
      return jsonRpcResult(id, { ok: true })
    }
    return jsonRpcError(id, -32601, 'method not found', { method })
  }

  return {
    handle,
    profile,
    tools: READONLY_TOOLS,
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
  createAcpSession,
  loadProfile,
  parseAcpLine,
}
