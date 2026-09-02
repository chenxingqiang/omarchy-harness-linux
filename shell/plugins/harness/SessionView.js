function pendingKind(mutation) {
  if (!mutation || typeof mutation !== 'object') {
    return 'unknown'
  }
  if (mutation.type === 'reset') {
    return 'session'
  }
  if (mutation.type === 'l1') {
    return 'desktop'
  }
  if (mutation.type === 'l2') {
    return 'system'
  }
  return 'unknown'
}

function pendingBadge(kind) {
  if (kind === 'session') {
    return 'Session'
  }
  if (kind === 'desktop') {
    return 'Desktop'
  }
  if (kind === 'system') {
    return 'System'
  }
  return 'Pending'
}

function pendingTone(kind) {
  if (kind === 'system') {
    return 'urgent'
  }
  if (kind === 'desktop') {
    return 'accent'
  }
  return 'muted'
}

function snapshotFirst(mutation) {
  return Boolean(
    mutation &&
    mutation.type === 'l2' &&
    mutation.snapshot &&
    Number(mutation.snapshot.status) === 0
  )
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

function pendingHint(mutation) {
  const kind = pendingKind(mutation)
  if (kind === 'session') {
    return 'Session only. The desktop and Linux stay unchanged.'
  }
  if (kind === 'desktop') {
    return 'Desktop change. Package, update, and power paths stay closed.'
  }
  if (kind === 'system') {
    if (snapshotFirst(mutation)) {
      return 'Snapshot taken before this request. Allow executes the system change.'
    }
    return 'System change. Allow executes on the machine.'
  }
  return 'Pending approval'
}

function pendingCard(id, item) {
  const mutation = item && item.mutation
  const kind = pendingKind(mutation)
  return {
    approvalId: (item && item.approvalId) || id,
    mutation: mutation,
    kind: kind,
    badge: pendingBadge(kind),
    tone: pendingTone(kind),
    snapshotFirst: snapshotFirst(mutation),
    summary: pendingSummary(mutation),
    hint: pendingHint(mutation),
  }
}

function pendingApprovals(state) {
  if (!state || !state.pending) {
    return []
  }
  return Object.keys(state.pending).map(function (id) {
    return pendingCard(id, state.pending[id])
  })
}

function statusTextFor(pending) {
  if (!pending.length) {
    return 'No pending approvals'
  }
  if (pending.length === 1) {
    return '1 ' + pending[0].kind + ' approval pending'
  }
  const counts = { session: 0, desktop: 0, system: 0, unknown: 0 }
  for (let i = 0; i < pending.length; i++) {
    const kind = pending[i].kind
    counts[kind] = (counts[kind] || 0) + 1
  }
  const parts = []
  if (counts.system) {
    parts.push(counts.system + ' system')
  }
  if (counts.desktop) {
    parts.push(counts.desktop + ' desktop')
  }
  if (counts.session) {
    parts.push(counts.session + ' session')
  }
  if (counts.unknown) {
    parts.push(counts.unknown + ' other')
  }
  return pending.length + ' pending approvals: ' + parts.join(', ')
}

function keyboardHint() {
  return 'Y allow · N deny · Esc close · R refresh'
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
      log: [],
      title: 'Untitled session',
      statusText: hostDownMessage(),
      keyboardHint: keyboardHint(),
    }
  }
  try {
    const state = JSON.parse(raw)
    if (!state || typeof state !== 'object' || Array.isArray(state)) {
      return {
        hostDown: true,
        pending: [],
        log: [],
        title: 'Untitled session',
        statusText: hostDownMessage(),
        keyboardHint: keyboardHint(),
      }
    }
    const pending = pendingApprovals(state)
    return {
      hostDown: false,
      pending: pending,
      log: Array.isArray(state.recent) ? state.recent : [],
      title: title(state),
      statusText: statusTextFor(pending),
      keyboardHint: keyboardHint(),
    }
  } catch (error) {
    return {
      hostDown: true,
      pending: [],
      log: [],
      title: 'Untitled session',
      statusText: hostDownMessage(),
      keyboardHint: keyboardHint(),
    }
  }
}

if (typeof module !== 'undefined') {
  module.exports = {
    hostDownMessage,
    keyboardHint,
    parseHostState,
    pendingApprovals,
    pendingBadge,
    pendingCard,
    pendingHint,
    pendingKind,
    pendingSummary,
    pendingTone,
    snapshotFirst,
    statusTextFor,
    title,
  }
}
