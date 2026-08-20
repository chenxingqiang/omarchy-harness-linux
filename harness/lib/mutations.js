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

const L2 = Object.freeze([
  'pkg.add',
  'pkg.drop',
  'update',
  'execute',
  'shell',
  'hyprctl',
  'window.move',
  'notify.send.exec',
  'launch.terminal.argv',
  'launch.browser.url',
  'launch.or-focus',
  'toggle.hybrid-gpu',
  'system.reboot',
  'system.shutdown',
  'etc.write',
  'usr.write',
  'service.enable',
  'firmware',
  'snapshot',
])

function normalize(name) {
  return String(name || '')
    .trim()
    .replace(/^dispatch\.write\./, '')
    .replace(/^omarchy[._]/, '')
    .replace(/\s+/g, '.')
}

function l1Names() {
  return Object.keys(L1)
}

function contract(name) {
  return L1[normalize(name)] || null
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

function codedError(code, extra) {
  const error = new Error(code)
  error.code = code
  if (extra) {
    Object.assign(error, extra)
  }
  return error
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

module.exports = {
  CONTRACT_FIELDS,
  L0,
  L1,
  L2,
  argvFor,
  classify,
  closedWriteSurface,
  contract,
  isRepresentableOnWrite,
  l1Names,
  normalize,
  validateArgs,
}
