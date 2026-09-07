const ACTIONS = Object.freeze(['passthrough', 'sudo', 'pkexec', 'deny'])

function alreadyElevatesArgv(argv) {
  const head = argv && argv[0]
  return head === 'sudo' || head === 'pkexec'
}

function pathIsUsrShare(value) {
  const text = String(value || '')
  return text === '/usr/share/omarchy' || text.startsWith('/usr/share/omarchy/')
}

function writesUsrShare(argv, flagged) {
  if (flagged === true) {
    return true
  }
  return (argv || []).some((token) => pathIsUsrShare(token))
}

function codedError(code) {
  const error = new Error(code)
  error.code = code
  return error
}

function decide(input = {}) {
  const argv = Array.isArray(input.argv) ? input.argv.slice() : []
  const alreadyElevates = input.alreadyElevates === true || alreadyElevatesArgv(argv)

  if (writesUsrShare(argv, input.writesUsrShare)) {
    return {
      action: 'deny',
      path: 'deny',
      wrapped: false,
      alreadyElevates: false,
      reason: 'USR_SHARE_READONLY',
    }
  }

  if (input.privilege === 'none') {
    return {
      action: 'passthrough',
      path: 'none',
      wrapped: false,
      alreadyElevates: false,
      reason: 'NO_PRIVILEGE',
    }
  }

  if (input.privilege === 'effector' || alreadyElevates) {
    return {
      action: 'passthrough',
      path: 'unwrapped',
      wrapped: false,
      alreadyElevates: true,
      reason: 'ALREADY_ELEVATES',
    }
  }

  if (input.privilege === 'required') {
    if (input.tty === true) {
      return {
        action: 'sudo',
        path: 'sudo',
        wrapped: true,
        alreadyElevates: false,
        reason: 'TTY_SUDO',
      }
    }
    return {
      action: 'pkexec',
      path: 'pkexec',
      wrapped: true,
      alreadyElevates: false,
      reason: 'NO_TTY_PKEXEC',
    }
  }

  return {
    action: 'deny',
    path: 'deny',
    wrapped: false,
    alreadyElevates: false,
    reason: 'UNKNOWN_PRIVILEGE',
  }
}

function wrapArgv(argv, decision) {
  const source = Array.isArray(argv) ? argv.slice() : []
  if (!decision || decision.action === 'passthrough') {
    return source
  }
  if (decision.action === 'deny') {
    throw codedError(decision.reason || 'PRIVILEGE_DENIED')
  }
  if (alreadyElevatesArgv(source)) {
    return source
  }
  if (decision.action === 'sudo') {
    return ['sudo'].concat(source)
  }
  if (decision.action === 'pkexec') {
    return ['pkexec'].concat(source)
  }
  throw codedError('UNKNOWN_PRIVILEGE')
}

function detectTty(options = {}) {
  if (typeof options.tty === 'boolean') {
    return options.tty
  }
  return Boolean(process.stdin && process.stdin.isTTY)
}

function apply(input = {}) {
  const decision = decide(input)
  return {
    decision,
    argv: wrapArgv(input.argv || [], decision),
  }
}

module.exports = {
  ACTIONS,
  apply,
  decide,
  detectTty,
  wrapArgv,
}
