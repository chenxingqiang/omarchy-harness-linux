const mutations = require('./mutations')

const LIMIT = 20

const SKIP = Object.freeze({
  'turn/start': true,
  'turn/end': true,
  'omarchy/status': true,
  'session/checkpoint': true,
  'session/metadata': true,
  'session/forked': true,
  'approval/request': true,
})

function kindForEvent(event, mutation) {
  if (event && event.type === 'approval/decision') {
    if (mutation && mutation.type === 'l2') {
      return 'system'
    }
    if (mutation && mutation.type === 'l1') {
      return 'desktop'
    }
    return 'session'
  }
  const type = event && event.type
  if (
    type === 'omarchy/pkg' ||
    type === 'omarchy/update' ||
    type === 'omarchy/snapshot' ||
    type === 'omarchy/system'
  ) {
    return 'system'
  }
  if (String(type || '').indexOf('omarchy/') === 0) {
    return 'desktop'
  }
  return 'session'
}

function badgeFor(kind) {
  if (kind === 'system') {
    return 'System'
  }
  if (kind === 'desktop') {
    return 'Desktop'
  }
  return 'Session'
}

function truncate(text, max) {
  const value = String(text || '').replace(/\s+/g, ' ').trim()
  const limit = max || 120
  if (value.length <= limit) {
    return value
  }
  return value.slice(0, limit - 1) + '…'
}

function auditSummary(event) {
  if (event.type === 'omarchy/pkg') {
    if (event.op === 'pkg.add') {
      return 'Installed packages'
    }
    if (event.op === 'pkg.drop') {
      return 'Removed packages'
    }
    return 'Package change'
  }
  if (event.type === 'omarchy/theme') {
    return 'Theme changed'
  }
  if (event.type === 'omarchy/launch') {
    return 'Launch executed'
  }
  if (event.type === 'omarchy/notify') {
    return 'Notification sent'
  }
  if (event.type === 'omarchy/toggle') {
    return 'Desktop toggle'
  }
  if (event.type === 'omarchy/window') {
    return 'Window focused'
  }
  if (event.type === 'omarchy/update') {
    return 'System updated'
  }
  if (event.type === 'omarchy/snapshot') {
    if (event.stage === 'preflight') {
      return 'Preflight snapshot'
    }
    return 'Snapshot action'
  }
  if (event.type === 'omarchy/system') {
    if (event.op === 'system.reboot') {
      return 'Reboot executed'
    }
    if (event.op === 'system.shutdown') {
      return 'Shutdown executed'
    }
    return 'System action'
  }
  return event.type
}

function factCard(event, mutation) {
  if (!event || SKIP[event.type]) {
    return null
  }
  const kind = kindForEvent(event, mutation)
  let summary = ''
  if (event.type === 'user/message') {
    summary = truncate(event.text)
    if (!summary) {
      return null
    }
  } else if (event.type === 'approval/decision') {
    const verb = event.decision === 'allow' ? 'Allowed' : 'Denied'
    summary = verb + ': ' + mutations.approvalSummary(mutation)
  } else if (event.type === 'session/reset') {
    summary = 'Session reset'
  } else if (event.type === 'session/fork') {
    summary = 'Forked this session'
  } else if (event.type === 'session/resume') {
    summary = 'Resumed session'
  } else if (String(event.type || '').indexOf('omarchy/') === 0) {
    summary = auditSummary(event)
  } else {
    return null
  }
  const card = {
    at: event.at || null,
    type: event.type,
    kind: kind,
    badge: badgeFor(kind),
    summary: summary,
  }
  if (event.type === 'approval/decision' && event.approvalId) {
    card.approvalId = event.approvalId
  }
  return card
}

function recent(events, limit) {
  const listed = Array.isArray(events) ? events : []
  const requests = {}
  for (let i = 0; i < listed.length; i++) {
    const event = listed[i]
    if (event && event.type === 'approval/request') {
      requests[event.approvalId] = event.mutation
    }
  }
  const cards = []
  for (let i = 0; i < listed.length; i++) {
    const event = listed[i]
    const mutation = event && event.type === 'approval/decision' ? requests[event.approvalId] : null
    const card = factCard(event, mutation)
    if (card) {
      cards.push(card)
    }
  }
  const window = Number(limit) > 0 ? Number(limit) : LIMIT
  return cards.slice(-window)
}

module.exports = {
  LIMIT,
  recent,
}
