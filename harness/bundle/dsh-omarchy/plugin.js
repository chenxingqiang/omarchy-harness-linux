import { createRequire } from 'node:module'
import { defineTool } from '@deepseek-ai/dsh-tools'

const require = createRequire(import.meta.url)
// harness/lib/omarchy-harness.js is CommonJS (module.exports); import it
// through createRequire rather than duplicating its effector, privilege, and
// audit logic here. See plans/harness.md: "compose them, not collapse them."
const harnessLib = require('../../lib/omarchy-harness.js')

/**
 * Canonical output shared by every registered tool. The dispatch layer
 * returns one of two real shapes (see harness/lib/session.js and
 * harness/lib/omarchy-harness.js):
 *   - an executed L1 result: { ok, status, stdout, stderr }
 *   - a pending approval (every L2 op, plus the ask-gated L1 launch ops):
 *     { ok, pending: true, approvalId, request }
 * A human resolves a pending approval out of band through
 * omarchy-harness-approve/omarchy-harness-deny, exactly as over the ACP
 * socket -- this bundle does not add a second approval channel.
 */
function dispatchOutput() {
  return {
    schema: {
      type: 'object',
      description:
        'Either an executed L1 result ({ ok, status, stdout, stderr }) or a ' +
        'pending human approval ({ ok, pending: true, approvalId, request }).',
      properties: {
        ok: { type: 'boolean' },
        status: { type: 'number' },
        stdout: { type: 'string' },
        stderr: { type: 'string' },
        pending: { type: 'boolean' },
        approvalId: { type: 'string' },
      },
      additionalProperties: true,
    },
    render(_args, value) {
      if (value && value.pending) {
        return [{
          type: 'text',
          text: `Pending human approval (id: ${value.approvalId}). Resolve with omarchy-harness-approve/omarchy-harness-deny.`,
        }]
      }
      const text = value && (value.stdout || value.stderr)
        ? String(value.stdout || value.stderr)
        : JSON.stringify(value)
      return [{ type: 'text', text }]
    },
  }
}

function readOutput() {
  return {
    schema: { type: 'object', additionalProperties: true },
    render(_args, value) {
      return [{ type: 'text', text: JSON.stringify(value, null, 2) }]
    },
  }
}

// L1 (desktop, no system privilege) tool parameters, hand-declared from the
// runtime-required fields harness/lib/mutations.js already enforces
// (rejectSmuggled / allowedArgs). Kept explicit rather than derived, so a
// model-facing schema drifting from the enforced contract fails review
// instead of drifting silently.
const L1_PARAMETERS = {
  'theme.set': {
    theme: { type: 'string', required: true, description: 'Theme directory name under ~/.config/omarchy/themes' },
  },
  'notify.send': {
    headline: { type: 'string', required: true, description: 'Notification headline' },
    description: { type: 'string', description: 'Notification body' },
    glyph: { type: 'string', description: 'Icon name or path passed to -g' },
    urgency: { type: 'string', enum: ['low', 'normal', 'critical'], description: 'Notification urgency' },
  },
  'toggle.nightlight': {},
  'toggle.bar': {
    state: { type: 'string', enum: ['on', 'off', 'toggle'], description: 'Desired bar state' },
  },
  'toggle.idle': {
    state: { type: 'string', enum: ['stay-awake', 'allow-idle'], description: 'Desired idle-inhibition state' },
  },
  'window.focus': {
    app: { type: 'string', required: true, description: 'Client class or title to focus' },
  },
  'launch.terminal': {},
  'launch.browser': {},
}

// L2 (system, approval-gated) tool parameters.
const L2_PARAMETERS = {
  'pkg.add': {
    packages: { type: 'array', items: { type: 'string' }, required: true, description: 'Package names to install' },
  },
  'pkg.drop': {
    packages: { type: 'array', items: { type: 'string' }, required: true, description: 'Package names to remove' },
  },
  update: {},
  'snapshot.create': {},
  'snapshot.restore': {},
  'system.reboot': {},
  'system.shutdown': {},
}

function registerDispatchTools(ctx, names, parametersByName, methods, contractOf) {
  for (const name of names) {
    const spec = contractOf(name)
    ctx.tools.register(defineTool({
      name,
      description: (spec && spec.mutationSemantics) || name,
      parameters: parametersByName[name] || {},
      output: dispatchOutput(),
      async execute(args) {
        return methods[name](args)
      },
    }))
  }
}

function registerReadOnlyTools(ctx, harness) {
  const readTools = {
    omarchy_status: 'Read-only snapshot of the current theme, version, plugins and windows',
    omarchy_commands: 'List the discoverable omarchy CLI command catalog',
    omarchy_windows: 'List Hyprland clients, workspaces, and the focused window',
    omarchy_theme_list: 'List installed theme names',
    omarchy_font_list: 'List installed font names',
    omarchy_plugin_list: 'List installed Quickshell plugin names',
  }
  for (const [name, description] of Object.entries(readTools)) {
    ctx.tools.register(defineTool({
      name,
      description,
      parameters: {},
      output: readOutput(),
      async execute() {
        return harness.tools[name]()
      },
    }))
  }
}

/**
 * Cordis plugin: registers the Omarchy harness's L1/L2 dispatch surface and
 * L0 read tools as `ctx.tools` entries. Tool registrations are disposed with
 * this fiber automatically (see @deepseek-ai/dsh-tools's ctx.tools.register
 * contract); this plugin does not manage that lifecycle itself.
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {{ harness?: ReturnType<typeof harnessLib.createHarness> }} [config]
 */
export default function apply(ctx, config = {}) {
  const harness = config.harness || harnessLib.createHarness()
  const { mutations } = harnessLib

  registerDispatchTools(ctx, mutations.l1Names(), L1_PARAMETERS, harness.dispatch.write, mutations.contract)
  registerDispatchTools(ctx, mutations.l2Names(), L2_PARAMETERS, harness.dispatch.system, mutations.systemContract)
  registerReadOnlyTools(ctx, harness)
}

apply.inject = ['tools']
Object.defineProperty(apply, 'name', { value: 'dsh-omarchy', configurable: true })
