#!/bin/bash

# Phase 3 privilege seam: the Omarchy skill rule becomes executable policy.
# v0 L2 effectors stay unwrapped. Privilege is not a model-callable wrap-any-argv tool.

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
const privilege = requireFromRoot('harness/lib/privilege.js')

assertEqual(privilege.decide({ privilege: 'none' }).action, 'passthrough', 'none stays passthrough')
assertEqual(privilege.decide({ privilege: 'none' }).path, 'none', 'none records path none')
assertEqual(privilege.decide({ privilege: 'none' }).wrapped, false, 'none is not wrapped')

const effector = privilege.decide({ privilege: 'effector', argv: ['omarchy', 'pkg', 'add', 'htop'] })
assertEqual(effector.action, 'passthrough', 'effector stays passthrough')
assertEqual(effector.path, 'unwrapped', 'effector records unwrapped')
assertEqual(effector.alreadyElevates, true, 'effector is already-elevates')
assertEqual(effector.wrapped, false, 'effector is not wrapped')

const tty = privilege.decide({ privilege: 'required', tty: true, argv: ['omarchy', 'held-op'] })
assertEqual(tty.action, 'sudo', 'visible TTY uses sudo')
assertEqual(tty.path, 'sudo', 'TTY path is sudo')
assertEqual(tty.wrapped, true, 'required TTY wraps')
assertDeepEqual(
  privilege.wrapArgv(['omarchy', 'held-op'], tty),
  ['sudo', 'omarchy', 'held-op'],
  'TTY wrap prefixes sudo'
)

const noTty = privilege.decide({ privilege: 'required', tty: false, argv: ['omarchy', 'held-op'] })
assertEqual(noTty.action, 'pkexec', 'no TTY uses pkexec')
assertEqual(noTty.path, 'pkexec', 'no-TTY path is pkexec')
assertDeepEqual(
  privilege.wrapArgv(['omarchy', 'held-op'], noTty),
  ['pkexec', 'omarchy', 'held-op'],
  'no-TTY wrap prefixes pkexec'
)

const already = privilege.decide({
  privilege: 'required',
  tty: false,
  argv: ['pkexec', 'omarchy', 'held-op'],
})
assertEqual(already.action, 'passthrough', 'already-elevated argv is not wrapped again')
assertDeepEqual(
  privilege.wrapArgv(['pkexec', 'omarchy', 'held-op'], already),
  ['pkexec', 'omarchy', 'held-op'],
  'already-elevated argv stays as-is'
)

const usr = privilege.decide({
  privilege: 'required',
  tty: true,
  argv: ['omarchy', 'edit', '/usr/share/omarchy/bin/omarchy'],
})
assertEqual(usr.action, 'deny', 'writes under /usr/share/omarchy are denied')
assertEqual(usr.reason, 'USR_SHARE_READONLY', 'usr/share deny has a stable code')
let deniedWrap = null
try {
  privilege.wrapArgv(['omarchy', 'edit', '/usr/share/omarchy/bin/omarchy'], usr)
} catch (error) {
  deniedWrap = error
}
assert(deniedWrap && deniedWrap.code === 'USR_SHARE_READONLY', 'deny wrap fail-closes')

const unknown = privilege.decide({ privilege: 'mystery' })
assertEqual(unknown.action, 'deny', 'unknown privilege mode fail-closes')

assertEqual(
  privilege.detectTty({ tty: false }),
  false,
  'detectTty honors an explicit false'
)
assertEqual(privilege.detectTty({ tty: true }), true, 'detectTty honors an explicit true')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-priv-'))
const calls = []
let ids = 0
const harness = createHarness({
  logPath: path.join(dir, 'current.jsonl'),
  now: () => '2026-08-24T00:00:00.000Z',
  newId: () => 'priv-' + (++ids),
  tty: false,
  exec(argv) {
    calls.push(argv.slice())
    if (argv[0] === 'sudo' || argv[0] === 'pkexec') {
      fail('v0 L2 must not wrap effectors that already elevate', argv.join(' '))
    }
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    fail('privilege seam must not call hyprctl')
  },
})

assert(harness.privilege, 'createHarness exposes the privilege seam')
assertEqual(typeof harness.privilege.decide, 'function', 'privilege.decide is callable')
assertEqual(harness.dispatch.privilege, undefined, 'privilege is not a dispatch method table')
assertEqual(harness.tools.omarchy_privilege, undefined, 'privilege is not a model-callable wrap tool')
assertEqual(harness.tools.privilege, undefined, 'privilege is not an untyped tool name')

const pendingPkg = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
const allowedPkg = harness.decide(pendingPkg.approvalId, 'allow')
assertDeepEqual(
  calls.filter((argv) => argv[1] === 'pkg').pop(),
  ['omarchy', 'pkg', 'add', 'htop'],
  'pkg.add stays an unwrapped omarchy effector'
)
assertEqual(allowedPkg.executed.privilege.path, 'unwrapped', 'pkg.add audit path is unwrapped')
assertEqual(allowedPkg.executed.privilege.wrapped, false, 'pkg.add is not wrapped')
assert(
  harness.store.events().some(
    (event) => event.type === 'omarchy/pkg' && event.privilege && event.privilege.path === 'unwrapped'
  ),
  'pkg.add logs the privilege path'
)

calls.length = 0
const pendingReboot = harness.dispatch.system['system.reboot']({})
harness.decide(pendingReboot.approvalId, 'allow')
assertDeepEqual(
  calls[calls.length - 1],
  ['omarchy', 'system', 'reboot'],
  'reboot stays unwrapped when privilege is none'
)

const init = harness.acp.handle({ jsonrpc: '2.0', id: 1, method: 'initialize' })
assertEqual(init.result.privilege, 'skill', 'ACP advertises the skill privilege seam')
assert(!init.result.tools.includes('privilege'), 'ACP tools omit a wrap-any-argv privilege tool')
assert(!init.result.tools.includes('omarchy_privilege'), 'ACP tools omit omarchy_privilege')

const config = harness.dumpConfig()
assertEqual(config.privilege, 'skill', 'dump-config privilege is skill')
assertEqual(config.privilege_wrap_v0, false, 'dump-config says v0 L2 is unwrapped')
assertEqual(config.system, true, 'privilege seam does not disable dispatch.system')
assertEqual(config.preset, 'session', 'permission preset stays session')

const overlay = fs.readFileSync(path.join(root, 'shell/plugins/harness/Overlay.qml'), 'utf8')
assert(!/pkexec/.test(overlay), 'overlay does not call pkexec')
assert(!/sudo/.test(overlay), 'overlay does not call sudo')

const firstRun = fs.readFileSync(path.join(root, 'install/user/first-run/enable-user-units.sh'), 'utf8')
assert(
  !/omarchy-harness\.service/.test(firstRun),
  'privilege seam still does not enable the user unit at first-run'
)
JS

: >"$CALL_LOG"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.privilege == "skill" and .privilege_wrap_v0 == false and .system == true and .preset == "session"' >/dev/null ||
  fail "CLI dump-config reports the privilege seam" "$dump_json"
pass "CLI dump-config reports the skill privilege seam without wrapping v0"

dump=$("$ROOT/bin/omarchy-harness-dump-config")
[[ $dump == *"privilege: skill"* ]] || fail "text dump-config prints privilege" "$dump"
pass "text dump-config prints privilege: skill"

system_json=$("$ROOT/bin/omarchy-harness-host" system pkg.add '{"packages":["htop"]}')
approval_id=$(echo "$system_json" | jq -r '.approvalId')
"$ROOT/bin/omarchy-harness-approve" "$approval_id" >/dev/null
grep -qx 'pkg add htop' "$CALL_LOG" || fail "approved pkg.add still uses omarchy pkg add" "$(cat "$CALL_LOG")"
if grep -E '^(sudo|pkexec) ' "$CALL_LOG"; then
  fail "CLI L2 does not wrap v0 effectors" "$(cat "$CALL_LOG")"
fi
pass "CLI L2 stays unwrapped after the privilege seam"
