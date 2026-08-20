#!/bin/bash

# Frozen Session Control Plane MVP: session mutation is allowed; OS mutation is unreachable.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node
require_command jq
require_command chmod

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
  "theme set"*|"pkg add"*)
    printf '%s\n' "$*" >>"${MUTATION_LOG:?}"
    exit 1
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
const { createSessionStore } = requireFromRoot('harness/lib/session.js')
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')
const view = requireFromRoot('shell/plugins/harness/SessionView.js')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-session-'))
let clock = Date.parse('2026-08-20T00:00:00.000Z')
const now = () => new Date(clock).toISOString()
let ids = 0
const store = createSessionStore({
  dir,
  now,
  newId: () => 'id-' + (++ids),
  approvalTimeoutMs: 1000,
})

store.write({ type: 'metadata', patch: { title: 'Inspect theme' } })
assertEqual(store.state().metadata.title, 'Inspect theme', 'metadata write updates session state')

store.write({ type: 'checkpoint' })
assert(store.state().checkpoint !== null, 'checkpoint is recorded')

const proposed = store.write({ type: 'reset' })
assertEqual(proposed.pending, true, 'reset requires approval')
assertEqual(store.state().metadata.title, 'Inspect theme', 'pending reset does not mutate yet')

const denied = store.decide(proposed.approvalId, 'deny')
assertEqual(denied.decision.decision, 'deny', 'deny records a decision')
assertEqual(store.state().metadata.title, 'Inspect theme', 'denied approval does not mutate')

const again = store.decide(proposed.approvalId, 'allow')
assertEqual(again.idempotent, true, 'duplicate decide is idempotent')
assertEqual(again.decision.decision, 'deny', 'first decision wins')
assertEqual(store.state().metadata.title, 'Inspect theme', 'idempotent allow cannot override deny')

let closed = null
try {
  store.decide('missing', 'allow')
} catch (error) {
  closed = error
}
assert(closed && closed.code === 'FAIL_CLOSED', 'missing approval fail-closes')

const pendingReset = store.write({ type: 'reset' })
store.decide(pendingReset.approvalId, 'allow')
assertEqual(store.state().metadata.title, '', 'allowed reset mutates session metadata')

clock += 5000
const timed = store.write({ type: 'reset' })
store.write({ type: 'metadata', patch: { title: 'keep' } })
clock += 5000
store.tick()
assertEqual(store.state().decisions[timed.approvalId].decision, 'deny', 'timeout denies')
assertEqual(store.state().metadata.title, 'keep', 'timeout deny leaves session unmutated by the reset')

const parentId = store.id
store.write({ type: 'metadata', patch: { title: 'parent' } })
const forked = store.fork()
assert(forked.sessionId !== parentId, 'fork creates a child session')
store.write({ type: 'metadata', patch: { title: 'child' } })
assertEqual(store.state().metadata.title, 'child', 'child session has its own metadata')
store.resume(parentId)
assertEqual(store.state().metadata.title, 'parent', 'resume restores parent session state')

const replayed = createSessionStore({ dir, id: parentId, now })
assertEqual(replayed.state().metadata.title, 'parent', 'replay reproduces session state from the log')
assert(Object.keys(replayed.state().decisions).length > 0, 'replay preserves approval decisions')

store.write({ type: 'metadata', patch: { title: 'live' } })
const forkedAgain = store.fork()
store.write({ type: 'metadata', patch: { title: 'forked-live' } })
const restarted = createSessionStore({ dir, now })
assertEqual(restarted.id, forkedAgain.sessionId, 'new process follows the active forked session')
assertEqual(restarted.state().metadata.title, 'forked-live', 'restart preserves forked session state')
restarted.resume(forkedAgain.parent)
const restartedParent = createSessionStore({ dir, now })
assertEqual(restartedParent.state().metadata.title, 'live', 'new process follows the resumed session')

const overlay = fs.readFileSync(path.join(root, 'shell/plugins/harness/Overlay.qml'), 'utf8')
assert(/function open\(payloadJson\)/.test(overlay), 'overlay exposes open')
assert(/function close\(\)/.test(overlay), 'overlay exposes close')
assert(/omarchy-harness-approve/.test(overlay), 'overlay allow path uses host approval')
assert(/omarchy-harness-deny/.test(overlay), 'overlay deny path uses host approval')
assert(/omarchy-harness-host/.test(overlay), 'overlay is an ACP/host client')
assert(!/pkexec/.test(overlay), 'overlay does not call pkexec')
assert(!/hyprctl/.test(overlay), 'overlay does not call hyprctl')
assert(!/theme set/.test(overlay), 'overlay does not set a theme')
assertEqual(view.hostDownMessage().includes('desktop is unchanged'), true, 'host-down overlay does not mutate the desktop')

const down = view.parseHostState('')
assertEqual(down.hostDown, true, 'empty host output is fail-closed')
assertEqual(down.pending.length, 0, 'host-down overlay has no pending approvals')
assertEqual(down.statusText, view.hostDownMessage(), 'host-down overlay shows the unchanged-desktop message')

const parsed = view.parseHostState(JSON.stringify({
  metadata: { title: 'Inspect theme' },
  pending: { 'id-1': { approvalId: 'id-1', mutation: { type: 'reset' } } },
}))
assertEqual(parsed.hostDown, false, 'valid session JSON is not host-down')
assertEqual(parsed.title, 'Inspect theme', 'overlay title comes from session metadata')
assertEqual(parsed.pending.length, 1, 'overlay lists pending approvals')

const calls = []
const harness = createHarness({
  logPath: path.join(dir, 'host-session', 'host.jsonl'),
  now,
  newId: () => 'host-' + (++ids),
  exec(argv) {
    calls.push(argv.slice())
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    calls.push(['hyprctl'])
    return { status: 0, stdout: '[]', stderr: '' }
  },
})
assert(harness.dispatch.write === undefined, 'Phase 2 still has no dispatch.write')
assert(harness.dispatch.system === undefined, 'Phase 2 still has no dispatch.system')
harness.store.write({ type: 'metadata', patch: { title: 'only session' } })
assertEqual(calls.length, 0, 'session write does not call omarchy or hyprctl')

const config = harness.dumpConfig()
assertEqual(config.dispatch, 'readonly', 'dump-config dispatch stays readonly')
assertEqual(config.session_write, true, 'dump-config reports session_write')
assertEqual(config.phase, 2, 'dump-config phase is 2')

const beforeAcp = calls.length
const acpReset = harness.acp.handle({
  jsonrpc: '2.0',
  id: 10,
  method: 'tools/call',
  params: { name: 'session_reset', arguments: {} },
})
assertEqual(acpReset.result.content.pending, true, 'ACP session_reset is pending approval')
assertEqual(calls.length, beforeAcp, 'ACP session write does not call omarchy or hyprctl')

const acpDenied = harness.acp.handle({
  jsonrpc: '2.0',
  id: 11,
  method: 'approval/decide',
  params: { approvalId: acpReset.result.content.approvalId, decision: 'deny' },
})
assertEqual(acpDenied.result.decision.decision, 'deny', 'ACP approval/decide records deny')

const acpDup = harness.acp.handle({
  jsonrpc: '2.0',
  id: 12,
  method: 'approval/decide',
  params: { approvalId: acpReset.result.content.approvalId, decision: 'allow' },
})
assertEqual(acpDup.result.idempotent, true, 'ACP duplicate decide is idempotent')
assertEqual(acpDup.result.decision.decision, 'deny', 'ACP first decision wins')

const acpMissing = harness.acp.handle({
  jsonrpc: '2.0',
  id: 13,
  method: 'approval/decide',
  params: { approvalId: 'missing', decision: 'allow' },
})
assertEqual(acpMissing.error.message, 'FAIL_CLOSED', 'ACP missing approval fail-closes')
JS

: >"$CALL_LOG"
: >"$MUTATION_LOG"

"$ROOT/bin/omarchy" commands --check >/dev/null
pass "phase 2 harness commands pass metadata check"

"$ROOT/bin/omarchy-harness-checkpoint" >/dev/null
pass "checkpoint CLI writes session state"

"$ROOT/bin/omarchy-harness-host" session metadata "Inspect theme" >/dev/null
reset_json=$("$ROOT/bin/omarchy-harness-host" session reset)
approval_id=$(echo "$reset_json" | jq -r '.approvalId')
[[ -n $approval_id && $approval_id != null ]] || fail "session reset returns an approval id" "$reset_json"
"$ROOT/bin/omarchy-harness-deny" "$approval_id" >/dev/null
"$ROOT/bin/omarchy-harness-approve" "$approval_id" >/dev/null
state_json=$("$ROOT/bin/omarchy-harness-host" session state)
echo "$state_json" | jq -e '.metadata.title == "Inspect theme"' >/dev/null ||
  fail "denied reset does not clear metadata" "$state_json"
pass "denied approval does not mutate session metadata"

reset_json=$("$ROOT/bin/omarchy-harness-host" session reset)
allow_id=$(echo "$reset_json" | jq -r '.approvalId')
"$ROOT/bin/omarchy-harness-approve" "$allow_id" >/dev/null
"$ROOT/bin/omarchy-harness-approve" "$allow_id" >/dev/null
state_json=$("$ROOT/bin/omarchy-harness-host" session state)
echo "$state_json" | jq -e '.metadata.title == ""' >/dev/null ||
  fail "allowed reset clears metadata" "$state_json"
pass "allowed reset mutates session metadata idempotently"

"$ROOT/bin/omarchy-harness-host" session metadata "parent-cli" >/dev/null
fork_json=$("$ROOT/bin/omarchy-harness-fork")
parent_id=$(echo "$fork_json" | jq -r '.parent')
"$ROOT/bin/omarchy-harness-host" session metadata "child-cli" >/dev/null
"$ROOT/bin/omarchy-harness-resume" "$parent_id" >/dev/null
state_json=$("$ROOT/bin/omarchy-harness-host" session state)
echo "$state_json" | jq -e '.metadata.title == "parent-cli"' >/dev/null ||
  fail "resume restores parent session" "$state_json"
pass "fork and resume restore session state from the log"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.phase == 2 and .session_write == true and .dispatch == "readonly"' >/dev/null
pass "dump-config reports phase 2 session write without dispatch.write"

if [[ -s $MUTATION_LOG ]]; then
  fail "phase 2 commands do not mutate Omarchy" "$(cat "$MUTATION_LOG")"
fi
pass "phase 2 does not touch the data plane"

grep -q 'omarchy.harness' "$ROOT/default/omarchy/omarchy-menu.jsonc" ||
  fail "menu offers the harness overlay"
pass "menu offers the harness overlay"
