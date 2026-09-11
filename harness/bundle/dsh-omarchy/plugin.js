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

// Tool parameters are generated from the mutations contract's argSpec
// (harness/lib/mutations.js): names, types, requiredness, and enums are
// declared once beside the CLI contract they mirror, so a new mutation
// gains its agent-facing schema by declaring argSpec there — never by
// re-declaring it here.
//
// Diagnostics: every generated schema logs one debug line (tool name plus
// its arg names), and an argSpec entry that cannot produce a valid schema
// logs a warn naming the tool, the arg, and the reason, then drops that
// one arg — the dispatch layer's allowedArgs/rejectSmuggled enforcement
// still rejects model calls that try to use it.
const VALID_TYPES = Object.freeze(['string', 'number', 'boolean', 'array'])

function parametersFromContract(spec, toolName, logger) {
  const entries = Object.entries((spec && spec.argSpec) || {})
  const params = {}
  for (const [arg, meta] of entries) {
    const problems = []
    if (!meta || !VALID_TYPES.includes(meta.type)) {
      problems.push(`missing/invalid "type" (expected one of ${VALID_TYPES.join('|')})`)
    }
    if (meta && meta.enum && (!Array.isArray(meta.enum) || meta.enum.length === 0)) {
      problems.push('"enum" must be a non-empty array')
    }
    if (meta && meta.items && meta.items !== 'string') {
      problems.push(`unsupported "items" type "${meta.items}"`)
    }
    if (problems.length > 0) {
      logger.warn(`dsh-omarchy: tool "${toolName}" argSpec for "${arg}" is invalid (${problems.join('; ')}); the arg is dropped from the model-facing schema`)
      continue
    }
    const p = { type: meta.type, description: meta.description }
    if (meta.enum) p.enum = meta.enum
    if (meta.items) p.items = { type: meta.items }
    if (meta.required) p.required = true
    params[arg] = p
  }
  logger.debug(`dsh-omarchy: tool "${toolName}" schema generated (${entries.length} arg(s): ${entries.map(([a]) => a).join(', ') || 'none'})`)
  return params
}

function registerDispatchTools(ctx, names, methods, contractOf) {
  for (const name of names) {
    const spec = contractOf(name)
    ctx.tools.register(defineTool({
      name,
      description: (spec && spec.mutationSemantics) || name,
      parameters: parametersFromContract(spec, name, ctx.logger),
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

  registerDispatchTools(ctx, mutations.l1Names(), harness.dispatch.write, mutations.contract)
  registerDispatchTools(ctx, mutations.l2Names(), harness.dispatch.system, mutations.systemContract)
  registerReadOnlyTools(ctx, harness)
}

apply.inject = ['tools']
Object.defineProperty(apply, 'name', { value: 'dsh-omarchy', configurable: true })
