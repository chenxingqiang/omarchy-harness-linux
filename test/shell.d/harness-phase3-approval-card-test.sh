#!/bin/bash

# Phase 3 approval cards: DND punch-through via omarchy-action. Click summons the overlay.
# Allow/deny still go through the host. Overlay is not a second approval store.

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
const { createHarness, mutations } = requireFromRoot('harness/lib/omarchy-harness.js')
const view = requireFromRoot('shell/plugins/harness/SessionView.js')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-card-'))
const calls = []
let ids = 0
const harness = createHarness({
  logPath: path.join(dir, 'current.jsonl'),
  now: () => '2026-08-20T00:00:00.000Z',
  newId: () => 'card-' + (++ids),
  exec(argv) {
    calls.push(argv.slice())
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    fail('approval cards must not call hyprctl')
  },
})

assertEqual(
  mutations.APPROVAL_CARD_EXEC,
  'omarchy-shell shell summon omarchy.harness',
  'card click summons the overlay'
)
assert(
  !mutations.APPROVAL_CARD_EXEC.includes('approve'),
  'card click does not auto-allow'
)

const reset = harness.store.write({ type: 'reset' })
assertEqual(reset.pending, true, 'reset is pending')
const card = calls[0]
assertEqual(card[0], 'omarchy', 'card uses omarchy')
assertEqual(card[1], 'notification', 'card is a notification')
assertEqual(card[2], 'send', 'card is notification send')
assert(card.includes('--exec'), 'card carries a click command')
assertEqual(
  card[card.indexOf('--exec') + 1],
  mutations.APPROVAL_CARD_EXEC,
  'click command is overlay summon'
)
assertEqual(card.includes('--app-name'), false, 'card keeps the omarchy-action default app name')
assertEqual(card.includes('omarchy-harness-approve'), false, 'card does not call approve')
assert(card.includes('Reset this Harness session'), 'card describes the reset')
assertEqual(reset.request.mutation.summary, 'Reset this Harness session', 'pending mutation carries a summary')

harness.store.write({ type: 'metadata', patch: { title: 'no card' } })
assertEqual(
  calls.filter((argv) => argv[1] === 'notification').length,
  1,
  'metadata write does not send another card'
)

calls.length = 0
const launch = harness.dispatch.write['launch.terminal']({})
assertEqual(launch.pending, true, 'launch is pending')
assert(
  calls.some((argv) => argv[1] === 'notification' && argv.includes('Launch the default terminal')),
  'launch pending sends a card'
)
assertEqual(
  calls.filter((argv) => argv[1] === 'launch').length,
  0,
  'launch card does not start the terminal'
)

calls.length = 0
const pkg = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
assertEqual(pkg.pending, true, 'pkg.add is pending')
assert(
  calls.some((argv) => argv[1] === 'snapshot' && argv[2] === 'create'),
  'pkg.add still snapshots first'
)
assert(
  calls.some((argv) => argv[1] === 'notification' && argv.includes('Install package: htop')),
  'pkg.add pending sends a card'
)
assertEqual(
  calls.filter((argv) => argv[1] === 'pkg').length,
  0,
  'pkg.add card does not install'
)

const overlay = fs.readFileSync(path.join(root, 'shell/plugins/harness/Overlay.qml'), 'utf8')
assert(/modelData.summary/.test(overlay), 'overlay renders the pending summary')
assert(/omarchy-harness-approve/.test(overlay), 'overlay allow still uses the host')
assert(/omarchy-harness-deny/.test(overlay), 'overlay deny still uses the host')
assert(!/omarchy-notification-send/.test(overlay), 'overlay does not send the card itself')

const parsed = view.parseHostState(JSON.stringify({
  metadata: { title: 'Inspect' },
  pending: {
    'card-1': {
      approvalId: 'card-1',
      mutation: { type: 'l2', op: 'pkg.add', args: { packages: ['htop'] }, summary: 'Install package: htop' },
    },
  },
}))
assertEqual(parsed.pending[0].summary, 'Install package: htop', 'overlay view surfaces the host summary')
assertEqual(parsed.statusText, '1 pending approval(s)', 'overlay still counts pending approvals')
JS

: >"$CALL_LOG"

reset_json=$("$ROOT/bin/omarchy-harness-host" session reset)
echo "$reset_json" | jq -e '.pending == true' >/dev/null || fail "CLI reset is pending" "$reset_json"
grep -qF 'notification send' "$CALL_LOG" || fail "CLI reset sends an approval card" "$(cat "$CALL_LOG")"
grep -qF 'omarchy-shell shell summon omarchy.harness' "$CALL_LOG" || fail "CLI card click summons overlay" "$(cat "$CALL_LOG")"
if grep -E 'harness-approve|pkg add|theme set' "$CALL_LOG"; then
  fail "approval card does not auto-allow or mutate" "$(cat "$CALL_LOG")"
fi
pass "CLI pending reset sends a DND punch-through card that summons the overlay"
