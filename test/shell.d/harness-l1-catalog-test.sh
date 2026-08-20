#!/bin/bash

# Rev 7 catalog is the closed L1 set. Phase 3 makes those eight ops executable; L2 stays unrepresentable.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node
require_command jq

TEST_HOME=$(mktemp -d)
MUTATION_LOG="$TEST_HOME/mutations.log"
STUB_BIN="$TEST_HOME/bin"
export HOME="$TEST_HOME"
export OMARCHY_PATH="$ROOT"
mkdir -p "$STUB_BIN" "$TEST_HOME/.local/state/omarchy/harness/sessions"
trap 'rm -rf "$TEST_HOME"' EXIT

cat >"$STUB_BIN/omarchy" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$*" in
  "theme set"*|"pkg add"*|"update")
    printf '%s\n' "$*" >>"${MUTATION_LOG:?}"
    exit 1
    ;;
  *)
    echo "ok"
    ;;
esac
EOF
chmod +x "$STUB_BIN/omarchy"
export MUTATION_LOG
export PATH="$STUB_BIN:$ROOT/bin:$PATH"

run_node_test <<'JS'
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')
const mutations = requireFromRoot('harness/lib/mutations.js')

const expectedL1 = [
  'theme.set',
  'notify.send',
  'toggle.nightlight',
  'toggle.bar',
  'toggle.idle',
  'window.focus',
  'launch.terminal',
  'launch.browser',
].sort()

assertDeepEqual(mutations.l1Names().sort(), expectedL1, 'L1 v0 is a closed eight-operation set')

for (const name of expectedL1) {
  const contract = mutations.contract(name)
  for (const field of mutations.CONTRACT_FIELDS) {
    assert(contract[field] != null && contract[field] !== '', name + ' has ' + field)
  }
  assertEqual(contract.privilege, 'none', name + ' requires no privilege')
  assertEqual(contract.snapshot, false, name + ' does not require a system snapshot')
  assertEqual(contract.scope, 'desktop', name + ' is desktop-scoped')
}

assertEqual(mutations.classify('theme.list'), 'L0', 'observe stays L0')
assertEqual(mutations.classify('theme.set'), 'L1', 'theme.set is L1')
assertEqual(mutations.classify('pkg.add'), 'L2', 'pkg.add is L2')
assertEqual(mutations.classify('execute'), 'L2', 'generic execute is L2')
assertEqual(mutations.classify('hyprctl'), 'L2', 'hyprctl string is L2')
assertEqual(mutations.classify('shell'), 'L2', 'shell is L2')
assertEqual(mutations.classify('unknown.op'), 'L2', 'unknown operations fail closed to L2')
assertEqual(mutations.classify('window.move'), 'L2', 'window.move is not on the v0 L1 table')
assertEqual(mutations.classify('notify.send.exec'), 'L2', 'notify exec is L2')
assertEqual(mutations.classify('launch.terminal.argv'), 'L2', 'launch argv is L2')
assertEqual(mutations.classify('launch.browser.url'), 'L2', 'launch URL is L2')
assertEqual(mutations.classify('toggle.hybrid-gpu'), 'L2', 'hybrid-gpu is L2')

assertEqual(mutations.isRepresentableOnWrite('theme.set'), true, 'L1 names are representable on write')
assertEqual(mutations.isRepresentableOnWrite('pkg.add'), false, 'pkg.add is not representable on write')
assertEqual(mutations.isRepresentableOnWrite('execute'), false, 'execute is not representable on write')
assertEqual(mutations.isRepresentableOnWrite('hyprctl'), false, 'hyprctl is not representable on write')
assertEqual(mutations.isRepresentableOnWrite('window.move'), false, 'window.move is not representable on write')

const surface = mutations.closedWriteSurface()
assertDeepEqual(Object.keys(surface).sort(), expectedL1, 'closed write surface has only L1 names')
assertEqual(surface.execute, undefined, 'closed write surface has no execute')
assertEqual(surface.shell, undefined, 'closed write surface has no shell')
assertEqual(surface['pkg.add'], undefined, 'closed write surface has no pkg.add')
assertEqual(surface['theme.set'].executable, true, 'L1 catalog is executable in Phase 3')
assert(Object.isFrozen(surface), 'closed write surface is frozen')

assertEqual(mutations.validateArgs('notify.send', { headline: 'hi', exec: 'rm -rf /' }).ok, false, 'notify.send rejects exec')
assertEqual(mutations.validateArgs('launch.terminal', { argv: ['bash'] }).ok, false, 'launch.terminal rejects argv')
assertEqual(mutations.validateArgs('launch.browser', { url: 'https://example.com' }).ok, false, 'launch.browser rejects url')
assertEqual(mutations.validateArgs('theme.set', { theme: 'Tokyo Night' }).ok, true, 'theme.set accepts a theme name')
assertEqual(mutations.validateArgs('window.focus', { app: 'Slack' }).ok, true, 'window.focus accepts an app name')

const source = require('fs').readFileSync(require('path').join(root, 'harness/lib/mutations.js'), 'utf8')
assert(!/spawnSync|child_process/.test(source), 'mutations catalog does not spawn effectors')

const harness = createHarness({
  exec() {
    fail('catalog review must not exec omarchy')
  },
  hyprctl() {
    fail('catalog review must not call hyprctl')
  },
})
assert(harness.dispatch.write !== undefined, 'Phase 3 L1 has dispatch.write')
assert(harness.dispatch.write.execute === undefined, 'dispatch.write has no generic execute')
assert(harness.dispatch.system === undefined, 'Phase 3 still has no dispatch.system')
assertDeepEqual(harness.mutations.l1Names().sort(), expectedL1, 'harness exposes the L1 catalog')

const config = harness.dumpConfig()
assertEqual(config.dispatch, 'l1', 'dump-config dispatch is l1')
assertEqual(config.write, true, 'dump-config write is true')
assertEqual(config.system, false, 'dump-config system is false')
assertEqual(config.l1_surface, 'executable', 'dump-config reports the executable L1 surface')
assertDeepEqual(config.l1.sort(), expectedL1, 'dump-config lists the L1 names')

const init = harness.acp.handle({ jsonrpc: '2.0', id: 1, method: 'initialize' })
assertEqual(init.result.write, true, 'ACP advertises L1 write')
assertEqual(init.result.system, false, 'ACP does not advertise system write')
assertDeepEqual(init.result.l1.sort(), expectedL1, 'ACP initialize advertises the L1 catalog')
assert(init.result.tools.includes('theme.set'), 'ACP tools include finite L1 ops')
assert(!init.result.tools.includes('omarchy_theme_set'), 'ACP tools still have no untyped write alias')

const writeCall = harness.acp.handle({
  jsonrpc: '2.0',
  id: 2,
  method: 'tools/call',
  params: { name: 'omarchy_theme_set', arguments: { theme: 'Tokyo Night' } },
})
assertEqual(writeCall.error.message, 'L2_UNREPRESENTABLE', 'untyped theme.set alias remains unrepresentable')
JS

: >"$MUTATION_LOG"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.dispatch == "l1" and .write == true and .system == false and .l1_surface == "executable" and (.l1 | length == 8)' >/dev/null
pass "dump-config reports an executable L1 surface without system write"

if [[ -s $MUTATION_LOG ]]; then
  fail "L1 catalog review does not mutate Omarchy" "$(cat "$MUTATION_LOG")"
fi
pass "L1 catalog review does not touch the data plane"
