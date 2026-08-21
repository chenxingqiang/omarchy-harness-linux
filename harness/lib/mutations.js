const CONTRACT_FIELDS = Object.freeze([
  'target',
  'mutationSemantics',
  'reversibility',
  'privilege',
  'scope',
  'snapshot',
  'approval',
  'auditEvent',
  'replay',
])

const L0 = Object.freeze([
  'theme.list',
  'theme.current',
  'font.list',
  'plugin.list',
  'omarchy_status',
  'omarchy_commands',
  'omarchy_windows',
  'omarchy_theme_list',
  'omarchy_font_list',
  'omarchy_plugin_list',
])

const L1 = Object.freeze({
  'theme.set': Object.freeze({
    target: 'omarchy-theme-set <theme-name>',
    mutationSemantics: 'switch the user theme symlink under ~/.local/state/omarchy/current',
    reversibility: 'yes',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-allow',
    auditEvent: 'omarchy/theme',
    replay: 're-apply the recorded theme name',
    allowedArgs: Object.freeze(['theme']),
  }),
  'notify.send': Object.freeze({
    target: 'omarchy-notification-send <headline> [description] [-g] [-u]',
    mutationSemantics: 'show a toast; schema has no --exec',
    reversibility: 'n/a',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'none',
    auditEvent: 'omarchy/notify',
    replay: 'do not re-send',
    allowedArgs: Object.freeze(['headline', 'description', 'glyph', 'urgency']),
  }),
  'toggle.nightlight': Object.freeze({
    target: 'omarchy-toggle-nightlight',
    mutationSemantics: 'flip hyprsunset temperature',
    reversibility: 'yes',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-allow',
    auditEvent: 'omarchy/toggle',
    replay: 'restore recorded on|off',
    allowedArgs: Object.freeze(['state']),
  }),
  'toggle.bar': Object.freeze({
    target: 'omarchy-toggle-bar [on|off|toggle]',
    mutationSemantics: 'hide or show the bar',
    reversibility: 'yes',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-allow',
    auditEvent: 'omarchy/toggle',
    replay: 'restore recorded on|off',
    allowedArgs: Object.freeze(['state']),
  }),
  'toggle.idle': Object.freeze({
    target: 'omarchy-toggle-idle stay-awake|allow-idle',
    mutationSemantics: 'user-state file under ~/.local/state/omarchy/indicators',
    reversibility: 'yes',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-allow',
    auditEvent: 'omarchy/toggle',
    replay: 'restore recorded stay-awake|allow-idle',
    allowedArgs: Object.freeze(['state']),
  }),
  'window.focus': Object.freeze({
    target: 'omarchy-hyprland-focus-app <app-name>',
    mutationSemantics: 'focus an existing client by class/title',
    reversibility: 'n/a',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'none',
    auditEvent: 'omarchy/window',
    replay: 're-focus if the window still exists',
    allowedArgs: Object.freeze(['app']),
  }),
  'launch.terminal': Object.freeze({
    target: 'omarchy-launch-terminal',
    mutationSemantics: 'open the default terminal with zero extra argv',
    reversibility: 'no',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-ask',
    auditEvent: 'omarchy/launch',
    replay: 'do not launch again',
    allowedArgs: Object.freeze([]),
  }),
  'launch.browser': Object.freeze({
    target: 'omarchy-launch-browser',
    mutationSemantics: 'open the default browser with no URL argument',
    reversibility: 'no',
    privilege: 'none',
    scope: 'desktop',
    snapshot: false,
    approval: 'optional-ask',
    auditEvent: 'omarchy/launch',
    replay: 'do not launch again',
    allowedArgs: Object.freeze([]),
  }),
})

const L2 = Object.freeze({
  'pkg.add': Object.freeze({
    target: 'omarchy-pkg-add <packages...>',
    mutationSemantics: 'install Arch packages via the Omarchy effector',
    reversibility: 'pkg.drop the recorded names',
    privilege: 'effector',
    scope: 'system',
    snapshot: true,
    approval: 'required',
    auditEvent: 'omarchy/pkg',
    replay: 'do not re-install from reduce',
    allowedArgs: Object.freeze(['packages']),
  }),
  'pkg.drop': Object.freeze({
    target: 'omarchy-pkg-drop <packages...>',
    mutationSemantics: 'remove Arch packages via the Omarchy effector',
    reversibility: 'pkg.add the recorded names',
    privilege: 'effector',
    scope: 'system',
    snapshot: true,
    approval: 'required',
    auditEvent: 'omarchy/pkg',
    replay: 'do not re-drop from reduce',
    allowedArgs: Object.freeze(['packages']),
  }),
  update: Object.freeze({
    target: 'omarchy-update -y',
    mutationSemantics: 'unattended Omarchy and system package update',
    reversibility: 'restore the preflight snapshot',
    privilege: 'effector',
    scope: 'system',
    snapshot: true,
    approval: 'required',
    auditEvent: 'omarchy/update',
    replay: 'do not re-run from reduce',
    allowedArgs: Object.freeze([]),
  }),
  'snapshot.create': Object.freeze({
    target: 'omarchy-snapshot create',
    mutationSemantics: 'create snapper snapshots',
    reversibility: 'n/a',
    privilege: 'effector',
    scope: 'system',
    snapshot: false,
    approval: 'required',
    auditEvent: 'omarchy/snapshot',
    replay: 'do not snapshot again from reduce',
    allowedArgs: Object.freeze([]),
  }),
  'snapshot.restore': Object.freeze({
    target: 'omarchy-snapshot restore',
    mutationSemantics: 'restore a snapper snapshot',
    reversibility: 'no',
    privilege: 'effector',
    scope: 'system',
    snapshot: true,
    approval: 'required',
    auditEvent: 'omarchy/snapshot',
    replay: 'do not restore again from reduce',
    allowedArgs: Object.freeze([]),
  }),
  'system.reboot': Object.freeze({
    target: 'omarchy-system-reboot',
    mutationSemantics: 'reboot after closing windows',
    reversibility: 'no',
    privilege: 'none',
    scope: 'system',
    snapshot: false,
    approval: 'required',
    auditEvent: 'omarchy/system',
    replay: 'do not reboot from reduce',
    allowedArgs: Object.freeze([]),
  }),
  'system.shutdown': Object.freeze({
    target: 'omarchy-system-shutdown',
    mutationSemantics: 'power off after closing windows',
    reversibility: 'no',
    privilege: 'none',
    scope: 'system',
    snapshot: false,
    approval: 'required',
    auditEvent: 'omarchy/system',
    replay: 'do not shut down from reduce',
    allowedArgs: Object.freeze([]),
  }),
})

const L2_HELD = Object.freeze([
  'execute',
  'shell',
  'hyprctl',
  'window.move',
  'notify.send.exec',
  'launch.terminal.argv',
  'launch.browser.url',
  'launch.or-focus',
  'toggle.hybrid-gpu',
  'etc.write',
  'usr.write',
  'service.enable',
  'firmware',
  'omarchy_cli',
])

function normalize(name) {
  return String(name || '')
    .trim()
    .replace(/^dispatch\.(write|system)\./, '')
    .replace(/^omarchy[._]/, '')
    .replace(/\s+/g, '.')
}

function l1Names() {
  return Object.keys(L1)
}

function l2Names() {
  return Object.keys(L2)
}

function contract(name) {
  return L1[normalize(name)] || null
}

function systemContract(name) {
  return L2[normalize(name)] || null
}

function classify(name) {
  const raw = String(name || '').trim()
  const key = normalize(name)
  if (L0.includes(raw) || L0.includes(key)) {
    return 'L0'
  }
  if (L1[key]) {
    return 'L1'
  }
  return 'L2'
}

function isRepresentableOnWrite(name) {
  return Boolean(L1[normalize(name)])
}

function isRepresentableOnSystem(name) {
  return Boolean(L2[normalize(name)])
}

const APPROVAL_CARD_EXEC = 'omarchy-shell shell summon omarchy.harness'
const APPROVAL_CARD_HEADLINE = 'Harness needs approval'

function approvalSummary(mutation) {
  if (!mutation || typeof mutation !== 'object') {
    return 'Pending approval'
  }
  if (mutation.type === 'reset') {
    return 'Reset this Harness session'
  }
  if (mutation.type === 'l1') {
    if (mutation.op === 'launch.terminal') {
      return 'Launch the default terminal'
    }
    if (mutation.op === 'launch.browser') {
      return 'Launch the default browser'
    }
    return 'Desktop change: ' + String(mutation.op || 'unknown')
  }
  if (mutation.type === 'l2') {
    if (mutation.op === 'pkg.add') {
      const packages = (mutation.args && mutation.args.packages) || []
      if (packages.length === 1) {
        return 'Install package: ' + packages[0]
      }
      return 'Install packages'
    }
    if (mutation.op === 'pkg.drop') {
      const packages = (mutation.args && mutation.args.packages) || []
      if (packages.length === 1) {
        return 'Remove package: ' + packages[0]
      }
      return 'Remove packages'
    }
    if (mutation.op === 'update') {
      return 'Update Omarchy and system packages'
    }
    if (mutation.op === 'snapshot.create') {
      return 'Create a system snapshot'
    }
    if (mutation.op === 'snapshot.restore') {
      return 'Restore a system snapshot'
    }
    if (mutation.op === 'system.reboot') {
      return 'Reboot the system'
    }
    if (mutation.op === 'system.shutdown') {
      return 'Shut down the system'
    }
    return 'System change: ' + String(mutation.op || 'unknown')
  }
  return 'Pending approval'
}

function approvalCardArgv(mutation) {
  return [
    'omarchy',
    'notification',
    'send',
    '-u',
    'normal',
    '--exec',
    APPROVAL_CARD_EXEC,
    APPROVAL_CARD_HEADLINE,
    approvalSummary(mutation),
  ]
}

function codedError(code, extra) {
  const error = new Error(code)
  error.code = code
  if (extra) {
    Object.assign(error, extra)
  }
  return error
}

function validateSystemArgs(name, args) {
  const key = normalize(name)
  const spec = L2[key]
  if (!spec) {
    return { ok: false, code: 'NOT_L2' }
  }
  const provided = Object.keys(args || {})
  const forbidden = provided.filter((field) => !spec.allowedArgs.includes(field))
  if (forbidden.length) {
    return { ok: false, code: 'FORBIDDEN_ARG', fields: forbidden }
  }
  return { ok: true }
}

function packagesArg(args) {
  const packages = args && args.packages
  if (!Array.isArray(packages) || packages.length === 0) {
    throw codedError('FORBIDDEN_ARG', { fields: ['packages'] })
  }
  for (const pkg of packages) {
    rejectSmuggled(pkg, 'packages')
  }
  return packages
}

function argvForSystem(name, args = {}) {
  const key = normalize(name)
  const spec = L2[key]
  if (!spec) {
    throw codedError('L2_UNREPRESENTABLE', { op: name })
  }
  const validated = validateSystemArgs(key, args)
  if (!validated.ok) {
    throw codedError(validated.code, { fields: validated.fields })
  }

  switch (key) {
    case 'pkg.add':
      return ['omarchy', 'pkg', 'add', ...packagesArg(args)]
    case 'pkg.drop':
      return ['omarchy', 'pkg', 'drop', ...packagesArg(args)]
    case 'update':
      return ['omarchy', 'update', '-y']
    case 'snapshot.create':
      return ['omarchy', 'snapshot', 'create']
    case 'snapshot.restore':
      return ['omarchy', 'snapshot', 'restore']
    case 'system.reboot':
      return ['omarchy', 'system', 'reboot']
    case 'system.shutdown':
      return ['omarchy', 'system', 'shutdown']
    default:
      throw codedError('L2_UNREPRESENTABLE', { op: name })
  }
}

function validateArgs(name, args) {
  const key = normalize(name)
  const spec = L1[key]
  if (!spec) {
    return { ok: false, code: 'NOT_L1' }
  }
  const provided = Object.keys(args || {})
  const forbidden = provided.filter((field) => !spec.allowedArgs.includes(field))
  if (forbidden.length) {
    return { ok: false, code: 'FORBIDDEN_ARG', fields: forbidden }
  }
  return { ok: true }
}

function rejectSmuggled(value, field) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw codedError('FORBIDDEN_ARG', { fields: [field] })
  }
  if (/^-|[\n\r;|&`$()]/.test(value)) {
    throw codedError('FORBIDDEN_ARG', { fields: [field] })
  }
}

function argvFor(name, args = {}) {
  const key = normalize(name)
  const spec = L1[key]
  if (!spec) {
    throw codedError('L2_UNREPRESENTABLE', { op: name })
  }
  const validated = validateArgs(key, args)
  if (!validated.ok) {
    throw codedError(validated.code, { fields: validated.fields })
  }

  switch (key) {
    case 'theme.set':
      rejectSmuggled(args.theme, 'theme')
      return ['omarchy', 'theme', 'set', args.theme]
    case 'notify.send': {
      rejectSmuggled(args.headline, 'headline')
      const argv = ['omarchy', 'notification', 'send']
      if (args.glyph != null && args.glyph !== '') {
        rejectSmuggled(String(args.glyph), 'glyph')
        argv.push('-g', String(args.glyph))
      }
      if (args.urgency != null && args.urgency !== '') {
        if (!['low', 'normal', 'critical'].includes(args.urgency)) {
          throw codedError('FORBIDDEN_ARG', { fields: ['urgency'] })
        }
        argv.push('-u', args.urgency)
      }
      argv.push(args.headline)
      if (args.description != null && args.description !== '') {
        rejectSmuggled(args.description, 'description')
        argv.push(args.description)
      }
      return argv
    }
    case 'toggle.nightlight':
      return ['omarchy', 'toggle', 'nightlight']
    case 'toggle.bar': {
      const argv = ['omarchy', 'toggle', 'bar']
      if (args.state != null && args.state !== '') {
        if (!['on', 'off', 'toggle'].includes(args.state)) {
          throw codedError('FORBIDDEN_ARG', { fields: ['state'] })
        }
        argv.push(args.state)
      }
      return argv
    }
    case 'toggle.idle': {
      const argv = ['omarchy', 'toggle', 'idle']
      if (args.state != null && args.state !== '') {
        if (!['stay-awake', 'allow-idle'].includes(args.state)) {
          throw codedError('FORBIDDEN_ARG', { fields: ['state'] })
        }
        argv.push(args.state)
      }
      return argv
    }
    case 'window.focus':
      rejectSmuggled(args.app, 'app')
      return ['omarchy', 'hyprland', 'focus', 'app', args.app]
    case 'launch.terminal':
      return ['omarchy', 'launch', 'terminal']
    case 'launch.browser':
      return ['omarchy', 'launch', 'browser']
    default:
      throw codedError('L2_UNREPRESENTABLE', { op: name })
  }
}

function closedWriteSurface() {
  const surface = {}
  for (const name of l1Names()) {
    surface[name] = Object.freeze({
      name,
      layer: 'L1',
      executable: true,
      contract: L1[name],
    })
  }
  return Object.freeze(surface)
}

function closedSystemSurface() {
  const surface = {}
  for (const name of l2Names()) {
    surface[name] = Object.freeze({
      name,
      layer: 'L2',
      executable: true,
      contract: L2[name],
    })
  }
  return Object.freeze(surface)
}

module.exports = {
  CONTRACT_FIELDS,
  L0,
  L1,
  L2,
  L2_HELD,
  APPROVAL_CARD_EXEC,
  APPROVAL_CARD_HEADLINE,
  approvalCardArgv,
  approvalSummary,
  argvFor,
  argvForSystem,
  classify,
  closedSystemSurface,
  closedWriteSurface,
  contract,
  isRepresentableOnSystem,
  isRepresentableOnWrite,
  l1Names,
  l2Names,
  normalize,
  systemContract,
  validateArgs,
  validateSystemArgs,
}
