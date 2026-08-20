function pendingApprovals(state) {
  if (!state || !state.pending) {
    return []
  }
  return Object.keys(state.pending).map(function (id) {
    return state.pending[id]
  })
}

function title(state) {
  if (state && state.metadata && state.metadata.title) {
    return state.metadata.title
  }
  return 'Untitled session'
}

function hostDownMessage() {
  return 'Harness host is down. Session overlay stays closed; the desktop is unchanged.'
}

function parseHostState(text) {
  const raw = String(text || '').trim()
  if (!raw) {
    return {
      hostDown: true,
      pending: [],
      title: 'Untitled session',
      statusText: hostDownMessage(),
    }
  }
  try {
    const state = JSON.parse(raw)
    if (!state || typeof state !== 'object' || Array.isArray(state)) {
      return {
        hostDown: true,
        pending: [],
        title: 'Untitled session',
        statusText: hostDownMessage(),
      }
    }
    const pending = pendingApprovals(state)
    return {
      hostDown: false,
      pending: pending,
      title: title(state),
      statusText: pending.length
        ? pending.length + ' pending approval(s)'
        : 'No pending approvals',
    }
  } catch (error) {
    return {
      hostDown: true,
      pending: [],
      title: 'Untitled session',
      statusText: hostDownMessage(),
    }
  }
}

if (typeof module !== 'undefined') {
  module.exports = {
    hostDownMessage,
    parseHostState,
    pendingApprovals,
    title,
  }
}
