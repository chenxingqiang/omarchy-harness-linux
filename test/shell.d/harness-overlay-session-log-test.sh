#!/bin/bash

# Overlay session log: host projects Session Log facts; overlay only renders them.
# Overlay stays an ACP client and is not a second fact store.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node
require_command jq

TEST_HOME=$(mktemp -d)
CALL_LOG="$TEST_HOME/calls.log"
STUB_BIN="$TEST_HOME/bin"
export HOME="$TEST_HOME"
export OMARCHY_PATH="$ROOT"
mkdir -p "$STUB_BIN" "$TEST_HOME/.local/state/omarchy/harness/sessions"
trap 'rm -rf "$TEST_HOME"' EXIT

cat >"$STUB_BIN/omarchy" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${CALL_LOG:?}"
echo "ok"
EOF
chmod +x "$STUB_BIN/omarchy"
export CALL_LOG
export PATH="$STUB_BIN:$ROOT/bin:$PATH"

run_node_test <<'JS'
const fs = require('fs')
const os = require('os')
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')
const facts = requireFromRoot('harness/lib/facts.js')
const view = requireFromRoot('shell/plugins/harness/SessionView.js')

const projected = facts.recent([
  { type: 'turn/start', at: '2026-09-02T00:00:00.000Z' },
  { type: 'omarchy/status', modelVisible: true, payload: { theme: 'secret' }, at: '2026-09-02T00:00:01.000Z' },
  { type: 'user/message', text: 'what theme is active', at: '2026-09-02T00:00:02.000Z' },
  { type: 'turn/end', reason: 'observe-only', at: '2026-09-02T00:00:03.000Z' },
  {
    type: 'approval/request',
    approvalId: 'id-1',
    mutation: { type: 'l2', op: 'pkg.add', args: { packages: ['htop'] }, summary: 'Install package: htop' },
    at: '2026-09-02T00:00:04.000Z',
  },
  { type: 'approval/decision', approvalId: 'id-1', decision: 'allow', reason: 'user', at: '2026-09-02T00:00:05.000Z' },
  {
    type: 'omarchy/pkg',
    op: 'pkg.add',
    argv: ['omarchy', 'pkg', 'add', 'htop'],
    status: 0,
    at: '2026-09-02T00:00:06.000Z',
  },
  { type: 'session/checkpoint', at: '2026-09-02T00:00:07.000Z' },
])

assertEqual(projected.some((card) => card.type === 'turn/start'), false, 'turn start is not a log card')
assertEqual(projected.some((card) => card.type === 'omarchy/status'), false, 'status snapshots are not overlay facts')
assertEqual(projected.some((card) => card.type === 'approval/request'), false, 'pending requests stay on the pending list')
assertEqual(projected.some((card) => card.type === 'session/checkpoint'), false, 'checkpoints are not overlay facts')
assert(
  projected.some((card) => card.type === 'user/message' && card.summary === 'what theme is active'),
  'user messages appear in the log'
)
assert(
  projected.some((card) => card.type === 'approval/decision' && card.summary === 'Allowed: Install package: htop'),
  'allow decisions keep the mutation summary'
)
assert(
  projected.some((card) => card.type === 'omarchy/pkg' && card.kind === 'system'),
  'pkg audit is a system fact'
)
assertEqual(
  projected.some((card) => JSON.stringify(card).includes('omarchy pkg add')),
  false,
  'projected facts omit effector argv'
)
assertEqual(
  projected.some((card) => JSON.stringify(card).includes('secret')),
  false,
  'projected facts omit status payloads'
)

const denied = facts.recent([
  {
    type: 'approval/request',
    approvalId: 'id-2',
    mutation: { type: 'reset', summary: 'Reset this Harness session' },
  },
  { type: 'approval/decision', approvalId: 'id-2', decision: 'deny', reason: 'timeout' },
])
assertEqual(denied[0].summary, 'Denied: Reset this Harness session', 'deny decisions keep the mutation summary')
assertEqual(denied[0].kind, 'session', 'reset decisions are session facts')

const many = []
for (let i = 0; i < 30; i++) {
  many.push({ type: 'user/message', text: 'msg-' + i, at: '2026-09-02T00:00:00.000Z' })
}
assertEqual(facts.recent(many).length, 20, 'log keeps a bounded recent window')
assertEqual(facts.recent(many)[0].summary, 'msg-10', 'log window is the newest facts')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-log-'))
let ids = 0
let hyprctlCalls = 0
const harness = createHarness({
  logPath: path.join(dir, 'current.jsonl'),
  now: () => '2026-09-02T00:00:00.000Z',
  newId: () => 'log-' + (++ids),
  exec() {
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    hyprctlCalls += 1
    return { status: 0, stdout: '[]\n', stderr: '' }
  },
})

harness.prompt('inspect the session')
hyprctlCalls = 0
const pending = harness.store.write({ type: 'reset' })
harness.decide(pending.approvalId, 'deny')
const state = harness.store.state()
assertEqual(hyprctlCalls, 0, 'projecting recent does not query hyprctl')
assert(Array.isArray(state.recent), 'host session state projects a recent log')
assert(
  state.recent.some((card) => card.type === 'user/message' && card.summary === 'inspect the session'),
  'prompt is visible in the projected log'
)
assert(
  state.recent.some((card) => card.type === 'approval/decision' && String(card.summary).startsWith('Denied:')),
  'deny is visible in the projected log'
)
assertEqual(
  state.recent.some((card) => card.approvalId === pending.approvalId && card.type === 'approval/request'),
  false,
  'host does not duplicate pending requests into the log'
)

const acp = harness.acp.handle({ jsonrpc: '2.0', id: 4, method: 'session/state' })
assert(Array.isArray(acp.result.recent), 'ACP session/state projects the same log')

const parsed = view.parseHostState(JSON.stringify(state))
assertEqual(parsed.log.length, state.recent.length, 'overlay view copies host recent facts')
assertEqual(parsed.log[0].summary, state.recent[0].summary, 'overlay log summaries come from the host')
assertEqual(parsed.hostDown, false, 'a state payload with a log is not host-down')

const down = view.parseHostState('')
assertEqual(down.log.length, 0, 'host-down overlay has no private log')

const overlay = fs.readFileSync(path.join(root, 'shell/plugins/harness/Overlay.qml'), 'utf8')
assert(/root\.log/.test(overlay), 'overlay renders the session log')
assert(/omarchy-harness-host/.test(overlay), 'overlay still reads host session state')
assert(/omarchy-harness-approve/.test(overlay), 'overlay allow still posts to the host')
assert(!/pkexec/.test(overlay), 'overlay does not call pkexec')
assert(!/hyprctl/.test(overlay), 'overlay does not call hyprctl')
assert(!/JSON\.parse/.test(overlay) || /parseHostState/.test(overlay), 'overlay does not keep a private session store')

const firstRun = fs.readFileSync(path.join(root, 'install/user/first-run/enable-user-units.sh'), 'utf8')
assert(
  !/omarchy-harness\.service/.test(firstRun),
  'session log still does not enable the user unit at first-run'
)
JS

: >"$CALL_LOG"

"$ROOT/bin/omarchy-harness-prompt" "inspect the session" >/dev/null
state_json=$("$ROOT/bin/omarchy-harness-host" session state)
echo "$state_json" | jq -e '.recent | type == "array"' >/dev/null || fail "CLI session state projects recent" "$state_json"
echo "$state_json" | jq -e '.recent[] | select(.type == "user/message") | .summary == "inspect the session"' >/dev/null ||
  fail "CLI log includes the prompt" "$state_json"
if echo "$state_json" | jq -e '.recent[] | .argv' >/dev/null 2>&1; then
  fail "CLI recent facts omit argv" "$state_json"
fi
pass "CLI session state projects a redacted session log"
