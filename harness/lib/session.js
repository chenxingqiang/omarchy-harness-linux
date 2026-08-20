const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

function defaultNow() {
  return new Date().toISOString()
}

function addMs(iso, ms) {
  return new Date(Date.parse(iso) + ms).toISOString()
}

function cmpIso(left, right) {
  return Date.parse(left) - Date.parse(right)
}

function emptyState() {
  return {
    metadata: { title: '' },
    pending: {},
    decisions: {},
    checkpoint: null,
    parent: null,
    resetAt: null,
  }
}

function requiresApproval(mutation) {
  if (!mutation) {
    return false
  }
  if (mutation.type === 'reset') {
    return true
  }
  return mutation.type === 'l1' && mutation.ask === true
}

function applyEvent(state, event) {
  if (event.type === 'session/metadata') {
    state.metadata = { ...state.metadata, ...(event.patch || {}) }
    return
  }
  if (event.type === 'session/checkpoint') {
    state.checkpoint = event.snapshot || { at: event.at }
    return
  }
  if (event.type === 'session/reset') {
    state.metadata = { title: '' }
    state.checkpoint = null
    state.resetAt = event.at
    return
  }
  if (event.type === 'session/fork') {
    state.parent = event.parent || state.parent
    return
  }
  if (event.type === 'approval/request') {
    if (!state.decisions[event.approvalId]) {
      state.pending[event.approvalId] = {
        approvalId: event.approvalId,
        mutation: event.mutation,
        timeoutAt: event.timeoutAt,
        at: event.at,
      }
    }
    return
  }
  if (event.type === 'approval/decision') {
    delete state.pending[event.approvalId]
    state.decisions[event.approvalId] = {
      approvalId: event.approvalId,
      decision: event.decision,
      reason: event.reason,
      at: event.at,
    }
  }
}

function reduce(events, at) {
  const state = emptyState()
  for (const event of events) {
    applyEvent(state, event)
  }
  if (at) {
    for (const approvalId of Object.keys(state.pending)) {
      const pending = state.pending[approvalId]
      if (pending.timeoutAt && cmpIso(at, pending.timeoutAt) >= 0) {
        delete state.pending[approvalId]
        state.decisions[approvalId] = {
          approvalId,
          decision: 'deny',
          reason: 'timeout',
          at,
          flushed: false,
        }
      }
    }
  }
  return state
}

function createSessionStore(options = {}) {
  const dir = options.dir
  const now = options.now || defaultNow
  const newId = options.newId || (() => crypto.randomUUID())
  const approvalTimeoutMs = options.approvalTimeoutMs == null ? 60000 : options.approvalTimeoutMs
  const fallbackId = options.fallbackId || 'current'
  const activeFile = path.join(dir, 'active')

  function readActiveId() {
    try {
      const text = fs.readFileSync(activeFile, 'utf8').trim()
      return text || null
    } catch {
      return null
    }
  }

  function persistActive(sessionId) {
    currentId = sessionId
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(activeFile, sessionId + '\n')
  }

  let currentId = options.id || readActiveId() || fallbackId
  if (!options.id) {
    persistActive(currentId)
  }

  function fileFor(sessionId) {
    return path.join(dir, sessionId + '.jsonl')
  }

  function readEvents(sessionId) {
    const file = fileFor(sessionId || currentId)
    if (!fs.existsSync(file)) {
      return []
    }
    return fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map((line) => JSON.parse(line))
  }

  function append(event, sessionId) {
    const id = sessionId || currentId
    fs.mkdirSync(dir, { recursive: true })
    const record = { ...event, at: event.at || now() }
    fs.appendFileSync(fileFor(id), JSON.stringify(record) + '\n')
    return record
  }

  function events() {
    return readEvents(currentId)
  }

  function tick() {
    const at = now()
    const live = reduce(events(), null)
    const flushed = []
    for (const approvalId of Object.keys(live.pending)) {
      const pending = live.pending[approvalId]
      if (pending.timeoutAt && cmpIso(at, pending.timeoutAt) >= 0) {
        flushed.push(
          append({
            type: 'approval/decision',
            approvalId,
            decision: 'deny',
            reason: 'timeout',
          })
        )
      }
    }
    return flushed
  }

  function state() {
    tick()
    return reduce(events(), now())
  }

  function applyMutation(mutation) {
    if (mutation.type === 'metadata') {
      return append({ type: 'session/metadata', patch: mutation.patch || {} })
    }
    if (mutation.type === 'checkpoint') {
      const snapshot = reduce(events(), now())
      return append({
        type: 'session/checkpoint',
        snapshot: {
          metadata: snapshot.metadata,
          pending: Object.keys(snapshot.pending),
          decisions: Object.keys(snapshot.decisions),
        },
      })
    }
    if (mutation.type === 'reset') {
      return append({ type: 'session/reset' })
    }
    const error = new Error('unknown session mutation: ' + mutation.type)
    error.code = 'UNKNOWN_MUTATION'
    throw error
  }

  function write(mutation) {
    if (requiresApproval(mutation)) {
      const approvalId = newId()
      const request = append({
        type: 'approval/request',
        approvalId,
        mutation,
        timeoutAt: addMs(now(), approvalTimeoutMs),
      })
      return { ok: true, pending: true, approvalId, request }
    }
    const event = applyMutation(mutation)
    return { ok: true, pending: false, event }
  }

  function decide(approvalId, decision, reason) {
    if (decision !== 'allow' && decision !== 'deny') {
      const error = new Error('decision must be allow or deny')
      error.code = 'INVALID_DECISION'
      throw error
    }
    tick()
    const current = reduce(events(), now())
    if (current.decisions[approvalId]) {
      return {
        ok: true,
        idempotent: true,
        decision: current.decisions[approvalId],
      }
    }
    const pending = current.pending[approvalId]
    if (!pending) {
      const error = new Error('no pending approval: ' + approvalId)
      error.code = 'FAIL_CLOSED'
      throw error
    }
    const recorded = append({
      type: 'approval/decision',
      approvalId,
      decision,
      reason: reason || 'user',
    })
    if (decision === 'allow' && pending.mutation.type !== 'l1') {
      applyMutation(pending.mutation)
    }
    return {
      ok: true,
      idempotent: false,
      decision: recorded,
      mutation: pending.mutation,
    }
  }

  function resume(sessionId) {
    if (!fs.existsSync(fileFor(sessionId))) {
      const error = new Error('unknown session: ' + sessionId)
      error.code = 'UNKNOWN_SESSION'
      throw error
    }
    persistActive(sessionId)
    tick()
    append({ type: 'session/resume', sessionId })
    return { ok: true, sessionId: currentId, state: state() }
  }

  function fork() {
    const childId = newId()
    const parentEvents = events()
    fs.mkdirSync(dir, { recursive: true })
    for (const event of parentEvents) {
      fs.appendFileSync(fileFor(childId), JSON.stringify(event) + '\n')
    }
    const parentId = currentId
    append({ type: 'session/forked', childId }, parentId)
    persistActive(childId)
    append({ type: 'session/fork', parent: parentId }, childId)
    return { ok: true, sessionId: childId, parent: parentId }
  }

  return {
    get id() {
      return currentId
    },
    append,
    applyMutation,
    decide,
    events,
    fork,
    reduce,
    resume,
    state,
    tick,
    write,
  }
}

module.exports = {
  addMs,
  createSessionStore,
  reduce,
  requiresApproval,
}
