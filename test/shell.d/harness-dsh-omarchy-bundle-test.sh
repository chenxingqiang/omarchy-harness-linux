#!/bin/bash

# The dsh-omarchy Cordis bundle (harness/bundle/dsh-omarchy) registers the
# harness's L1/L2 dispatch surface as dsh tools. This exercises it against
# the real pinned @deepseek-ai/cordis and @deepseek-ai/dsh-tools packages --
# no mock of either -- so a real API drift in the vendored dsh runtime fails
# here instead of only at a live `dsh --profile omarchy` boot.
#
# harness/node_modules is a packaging-time artifact (see harness/package.json
# and plans/harness.md), not committed. Where it is absent -- most dev
# checkouts, and any CI job that has not run `npm install` in harness/ -- this
# skips with a clear reason instead of failing, the same pattern
# compositor_reachable uses for Hyprland in base-test.sh.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node

if [[ ! -d "$ROOT/harness/node_modules/@deepseek-ai/cordis" ]]; then
  pass "no installed dsh runtime under harness/node_modules; skipping the real Cordis boot (run npm install in harness/ first)"
  exit 0
fi

run_node_test <<'JS'
const fs = require('fs')
const os = require('os')
const url = require('url')

async function main() {
  // Piped stdin has no real module URL, so a bare specifier cannot resolve
  // against harness/node_modules on its own; resolve each real package's
  // absolute path first, the same way Node's own resolver would from a file
  // that actually lives under harness/.
  const harnessNodeModules = path.join(root, 'harness/node_modules')
  const resolveReal = (specifier) =>
    url.pathToFileURL(require.resolve(specifier, { paths: [harnessNodeModules] })).href

  const { Context } = await import(resolveReal('@deepseek-ai/cordis'))
  const { default: SystemPrompt } = await import(resolveReal('@deepseek-ai/dsh-system-prompt'))
  const { default: ToolRuntime } = await import(resolveReal('@deepseek-ai/dsh-tools'))
  const pluginUrl = url.pathToFileURL(path.join(root, 'harness/bundle/dsh-omarchy/plugin.js')).href
  const { default: applyOmarchyBundle } = await import(pluginUrl)
  const harnessLib = requireFromRoot('harness/lib/omarchy-harness.js')

  const ctx = new Context()
  await ctx.plugin(SystemPrompt, {})
  await ctx.plugin(ToolRuntime, {})

  const calls = []
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-dsh-bundle-'))
  const testHarness = harnessLib.createHarness({
    logPath: path.join(stateDir, 'current.jsonl'),
    now: () => '2026-08-20T00:00:00.000Z',
    newId: () => 'dsh-omarchy-test-1',
    exec(argv) {
      calls.push(argv.slice())
      return { status: 0, stdout: 'ok\n', stderr: '' }
    },
  })

  await ctx.plugin(applyOmarchyBundle, { harness: testHarness })

  const names = ctx.tools.schemas().map((schema) => schema.name)
  assert(names.includes('theme.set'), 'the bundle registers theme.set as a real dsh tool', names.join(', '))
  assert(names.includes('pkg.add'), 'the bundle registers pkg.add as a real dsh tool', names.join(', '))
  assert(names.includes('omarchy_status'), 'the bundle registers the read-only omarchy_status tool', names.join(', '))

  const themeResult = await ctx.tools.execute({
    callId: 'theme-1',
    name: 'theme.set',
    arguments: { theme: 'tokyo-night' },
    signal: new AbortController().signal,
  })
  assert(!themeResult.isError, 'theme.set executes through the real dsh-tools pipeline', JSON.stringify(themeResult))
  assert(
    calls.some((argv) => argv.join(' ') === 'omarchy theme set tokyo-night'),
    'theme.set reaches the real omarchy effector argv unchanged',
    JSON.stringify(calls)
  )

  const badResult = await ctx.tools.execute({
    callId: 'theme-2',
    name: 'theme.set',
    arguments: { theme: '; rm -rf ~' },
    signal: new AbortController().signal,
  })
  assert(badResult.isError, 'theme.set rejects a smuggled argument through the real dsh-tools pipeline', JSON.stringify(badResult))

  const pkgResult = await ctx.tools.execute({
    callId: 'pkg-1',
    name: 'pkg.add',
    arguments: { packages: ['htop'] },
    signal: new AbortController().signal,
  })
  assert(!pkgResult.isError, 'pkg.add executes through the real dsh-tools pipeline', JSON.stringify(pkgResult))
  assert(
    pkgResult.value && pkgResult.value.pending === true && typeof pkgResult.value.approvalId === 'string',
    'pkg.add returns a pending human approval instead of executing unattended',
    JSON.stringify(pkgResult)
  )
  assert(
    !calls.some((argv) => argv.includes('add')),
    'pkg.add does not reach the effector before a human approves it',
    JSON.stringify(calls)
  )

  await ctx.fiber.dispose()
  pass('the dsh-omarchy Cordis bundle registers and executes real dsh tools end to end')
}

main().catch((error) => {
  fail('dsh-omarchy bundle boots against the real dsh-tools/cordis runtime', error.stack || String(error))
})
JS
