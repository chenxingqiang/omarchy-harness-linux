function pendingApprovals(state) {
  if (!state || !state.pending) {
    return []
  }
  return Object.keys(state.pending).map(function (id) {
    const item = state.pending[id]
    const mutation = item && item.mutation
    return {
      approvalId: item.approvalId || id,
      mutation: mutation,
      summary: (mutation && mutation.summary) || pendingSummary(mutation),
    }
  })
}

function pendingSummary(mutation) {
  if (!mutation) {
    return 'Pending approval'
  }
  if (mutation.summary) {
    return mutation.summary
  }
  if (mutation.type === 'reset') {
    return 'Reset this Harness session'
  }
  if (mutation.type === 'l1' && mutation.op === 'launch.terminal') {
    return 'Launch the default terminal'
  }
  if (mutation.type === 'l1' && mutation.op === 'launch.browser') {
    return 'Launch the default browser'
  }
  if (mutation.type === 'l2' && mutation.op === 'pkg.add') {
    return 'Install packages'
  }
  if (mutation.type === 'l2' && mutation.op === 'system.reboot') {
    return 'Reboot the system'
  }
  return 'Pending approval'
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
    pendingSummary,
    title,
  }
}
