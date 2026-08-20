#!/bin/bash

# Phase 3 L1: finite typed desktop mutations. L2 stays unrepresentable.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node
require_command jq

TEST_HOME=$(mktemp -d)
CALL_LOG="$TEST_HOME/calls.log"
MUTATION_LOG="$TEST_HOME/mutations.log"
STUB_BIN="$TEST_HOME/bin"
export HOME="$TEST_HOME"
export OMARCHY_PATH="$ROOT"
mkdir -p "$STUB_BIN" "$TEST_HOME/.local/state/omarchy/harness/sessions"
trap 'rm -rf "$TEST_HOME"' EXIT

cat >"$STUB_BIN/omarchy" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${CALL_LOG:?}"
case "$*" in
  "pkg add"*|"update"|"theme set --exec"*|"launch terminal bash"*)
    printf '%s\n' "$*" >>"${MUTATION_LOG:?}"
    exit 1
    ;;
  "theme set "*|"notification send "*|"toggle "*|"hyprland focus app "*|"launch terminal"|"launch browser")
    echo "ok"
    ;;
  *)
    echo "ok"
    ;;
esac
EOF
chmod +x "$STUB_BIN/omarchy"
export CALL_LOG MUTATION_LOG
export PATH="$STUB_BIN:$ROOT/bin:$PATH"

run_node_test <<'JS'
const fs = require('fs')
const os = require('os')
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')
const mutations = requireFromRoot('harness/lib/mutations.js')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-l1-'))
const calls = []
let ids = 0
const harness = createHarness({
  logPath: path.join(dir, 'current.jsonl'),
  now: () => '2026-08-20T00:00:00.000Z',
  newId: () => 'l1-' + (++ids),
  exec(argv) {
    calls.push(argv.slice())
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    fail('L1 write must not call hyprctl directly')
  },
})

assert(harness.dispatch.write !== undefined, 'Phase 3 L1 has dispatch.write')
assert(harness.dispatch.system !== undefined, 'Phase 3 L2 has dispatch.system')
assert(harness.dispatch.system.execute === undefined, 'dispatch.system has no generic execute')
assert(harness.dispatch.write.execute === undefined, 'dispatch.write has no generic execute')
assert(harness.dispatch.write.shell === undefined, 'dispatch.write has no shell')
assert(harness.dispatch.write['pkg.add'] === undefined, 'dispatch.write has no pkg.add')
assert(typeof harness.dispatch.write['theme.set'] === 'function', 'theme.set is a typed method')
assert(Object.isFrozen(harness.dispatch.write), 'dispatch.write is frozen')

const themed = harness.dispatch.write['theme.set']({ theme: 'Tokyo Night' })
assertEqual(themed.ok, true, 'theme.set runs')
assertDeepEqual(calls[0], ['omarchy', 'theme', 'set', 'Tokyo Night'], 'theme.set calls the Omarchy effector')
assert(harness.store.events().some((event) => event.type === 'omarchy/theme'), 'theme.set emits an audit event')

let l2 = null
try {
  harness.dispatch.write['theme.set']({ theme: 'Tokyo Night', exec: 'pkg add htop' })
} catch (error) {
  l2 = error
}
assert(l2 && l2.code === 'FORBIDDEN_ARG', 'theme.set rejects extra exec-shaped args')

let missing = null
try {
  mutations.argvFor('pkg.add', {})
} catch (error) {
  missing = error
}
assert(missing && missing.code === 'L2_UNREPRESENTABLE', 'argvFor cannot build L2 operations')

const notified = harness.dispatch.write['notify.send']({ headline: 'Hello', description: 'World', glyph: '!', urgency: 'low' })
assertEqual(notified.ok, true, 'notify.send runs')
assertEqual(calls[1][0], 'omarchy', 'notify.send uses omarchy')
assertEqual(calls[1][1], 'notification', 'notify.send uses notification send')
assertEqual(calls[1].includes('--exec'), false, 'notify.send argv has no --exec')

let execArg = null
try {
  harness.dispatch.write['notify.send']({ headline: 'x', exec: 'rm' })
} catch (error) {
  execArg = error
}
assert(execArg && execArg.code === 'FORBIDDEN_ARG', 'notify.send rejects exec')

harness.dispatch.write['toggle.nightlight']({})
assertDeepEqual(calls[2], ['omarchy', 'toggle', 'nightlight'], 'toggle.nightlight calls the effector')
harness.dispatch.write['toggle.bar']({ state: 'off' })
assertDeepEqual(calls[3], ['omarchy', 'toggle', 'bar', 'off'], 'toggle.bar passes on|off')
harness.dispatch.write['toggle.idle']({ state: 'stay-awake' })
assertDeepEqual(calls[4], ['omarchy', 'toggle', 'idle', 'stay-awake'], 'toggle.idle passes stay-awake')
harness.dispatch.write['window.focus']({ app: 'Slack' })
assertDeepEqual(calls[5], ['omarchy', 'hyprland', 'focus', 'app', 'Slack'], 'window.focus uses the typed Omarchy command')

const beforeLaunch = calls.length
const pending = harness.dispatch.write['launch.terminal']({})
assertEqual(pending.pending, true, 'launch.terminal asks for approval')
assertEqual(
  calls.filter((argv) => argv[1] === 'launch').length,
  0,
  'pending launch does not exec'
)
assert(
  calls.slice(beforeLaunch).some((argv) => argv[1] === 'notification'),
  'pending launch sends an approval card'
)

const denied = harness.decide('l1-1', 'deny')
assertEqual(denied.decision.decision, 'deny', 'launch deny is recorded')
assertEqual(
  calls.filter((argv) => argv[1] === 'launch').length,
  0,
  'denied launch does not exec'
)

const pendingAgain = harness.dispatch.write['launch.browser']({})
assertEqual(pendingAgain.pending, true, 'launch.browser asks for approval')
const allowed = harness.decide(pendingAgain.approvalId, 'allow')
assertEqual(allowed.ok, true, 'allowed launch proceeds')
assertDeepEqual(calls[calls.length - 1], ['omarchy', 'launch', 'browser'], 'allowed launch.browser has no URL')

const dup = harness.decide(pendingAgain.approvalId, 'allow')
assertEqual(dup.idempotent, true, 'duplicate launch allow is idempotent')
assertEqual(calls.filter((argv) => argv[1] === 'launch' && argv[2] === 'browser').length, 1, 'idempotent allow does not launch again')

let argvLaunch = null
try {
  harness.dispatch.write['launch.terminal']({ argv: ['bash'] })
} catch (error) {
  argvLaunch = error
}
assert(argvLaunch && argvLaunch.code === 'FORBIDDEN_ARG', 'launch.terminal rejects argv')

let urlLaunch = null
try {
  harness.dispatch.write['launch.browser']({ url: 'https://example.com' })
} catch (error) {
  urlLaunch = error
}
assert(urlLaunch && urlLaunch.code === 'FORBIDDEN_ARG', 'launch.browser rejects url')

const init = harness.acp.handle({ jsonrpc: '2.0', id: 1, method: 'initialize' })
assertEqual(init.result.write, true, 'ACP advertises L1 write')
assertEqual(init.result.system, true, 'ACP advertises L2 system write')
assertEqual(init.result.dispatch, 'l2', 'ACP dispatch is the L2 surface')
assert(init.result.tools.includes('theme.set'), 'ACP tools include theme.set')
assert(!init.result.tools.includes('omarchy_theme_set'), 'ACP tools still omit untyped omarchy_theme_set')

const acpTheme = harness.acp.handle({
  jsonrpc: '2.0',
  id: 2,
  method: 'tools/call',
  params: { name: 'theme.set', arguments: { theme: 'Catppuccin' } },
})
assertEqual(acpTheme.result.content.ok, true, 'ACP tools/call runs theme.set')
assert(calls.some((argv) => argv[2] === 'set' && argv[3] === 'Catppuccin'), 'ACP theme.set reached the effector')

const acpPkg = harness.acp.handle({
  jsonrpc: '2.0',
  id: 3,
  method: 'tools/call',
  params: { name: 'execute', arguments: { argv: ['pacman', '-S', 'htop'] } },
})
assertEqual(acpPkg.error.message, 'L2_UNREPRESENTABLE', 'ACP cannot call generic execute')

const config = harness.dumpConfig()
assertEqual(config.phase, 3, 'dump-config phase is 3')
assertEqual(config.dispatch, 'l2', 'dump-config dispatch is l2')
assertEqual(config.write, true, 'dump-config write is true')
assertEqual(config.l1_surface, 'executable', 'dump-config L1 surface is executable')
assertEqual(config.system, true, 'dump-config system is true')
JS

: >"$CALL_LOG"
: >"$MUTATION_LOG"

write_json=$("$ROOT/bin/omarchy-harness-host" write theme.set '{"theme":"Tokyo Night"}')
echo "$write_json" | jq -e '.ok == true' >/dev/null || fail "write CLI runs theme.set" "$write_json"
grep -qx 'theme set Tokyo Night' "$CALL_LOG" || fail "write CLI invoked omarchy theme set" "$(cat "$CALL_LOG")"
pass "write CLI runs theme.set"

launch_json=$("$ROOT/bin/omarchy-harness-host" write launch.terminal '{}')
echo "$launch_json" | jq -e '.pending == true' >/dev/null || fail "write CLI launch is pending" "$launch_json"
pass "write CLI launch.terminal is pending approval"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.phase == 3 and .dispatch == "l2" and .write == true and .system == true and .l1_surface == "executable"' >/dev/null
pass "dump-config reports executable L1 and L2"

if grep -Eq 'pkg add|update -y' "$CALL_LOG"; then
  fail "L1 write does not dispatch L2 routes" "$(cat "$CALL_LOG")"
fi
if grep -- '--exec' "$CALL_LOG" | grep -vq 'omarchy-shell shell summon omarchy.harness'; then
  fail "L1 approval card exec is only overlay summon" "$(cat "$CALL_LOG")"
fi
if [[ -s $MUTATION_LOG ]]; then
  fail "L1 write does not take L2 mutation paths" "$(cat "$MUTATION_LOG")"
fi
pass "L1 write cannot cross into L2"
