#!/bin/bash

# Phase 3 L2: finite dispatch.system. Pipeline is snapshot → approval → execute → audit.
# dispatch.write still cannot represent L2. Generic execute/shell stay unrepresentable.

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
  "snapshot create")
    echo "snapshot ok"
    ;;
  "pkg add htop"|"pkg drop htop"|"update -y"|"snapshot restore"|"system reboot"|"system shutdown")
    echo "ok"
    ;;
  "pkg add"*|"update"|"bash "*|"pacman "*|"hyprctl "*)
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
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')
const mutations = requireFromRoot('harness/lib/mutations.js')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-harness-l2-'))
const calls = []
let ids = 0
const harness = createHarness({
  logPath: path.join(dir, 'current.jsonl'),
  now: () => '2026-08-20T00:00:00.000Z',
  newId: () => 'l2-' + (++ids),
  exec(argv) {
    calls.push(argv.slice())
    if (argv[0] === 'sudo' || argv[0] === 'pkexec') {
      fail('dispatch.system must not wrap effectors that already elevate', argv.join(' '))
    }
    return { status: 0, stdout: 'ok\n', stderr: '' }
  },
  hyprctl() {
    fail('L2 system must not call hyprctl directly')
  },
})

assert(harness.dispatch.system !== undefined, 'Phase 3 L2 has dispatch.system')
assert(Object.isFrozen(harness.dispatch.system), 'dispatch.system is frozen')
assert(harness.dispatch.system.execute === undefined, 'dispatch.system has no generic execute')
assert(harness.dispatch.system.shell === undefined, 'dispatch.system has no shell')
assert(harness.dispatch.system.hyprctl === undefined, 'dispatch.system has no hyprctl')
assert(harness.dispatch.system['etc.write'] === undefined, 'dispatch.system has no etc.write')
assert(harness.dispatch.system['usr.write'] === undefined, 'dispatch.system has no usr.write')
assert(harness.dispatch.system.firmware === undefined, 'dispatch.system has no firmware')
assert(harness.dispatch.write['pkg.add'] === undefined, 'dispatch.write still cannot represent pkg.add')
assert(typeof harness.dispatch.system['pkg.add'] === 'function', 'pkg.add is a typed system method')

let writePkg = null
try {
  mutations.argvFor('pkg.add', { packages: ['htop'] })
} catch (error) {
  writePkg = error
}
assert(writePkg && writePkg.code === 'L2_UNREPRESENTABLE', 'L1 argvFor still cannot build L2 operations')

assertDeepEqual(
  mutations.argvForSystem('pkg.add', { packages: ['htop'] }),
  ['omarchy', 'pkg', 'add', 'htop'],
  'pkg.add maps to the Omarchy effector'
)
assertDeepEqual(
  mutations.argvForSystem('update', {}),
  ['omarchy', 'update', '-y'],
  'update is unattended -y'
)
assertDeepEqual(
  mutations.argvForSystem('system.reboot', {}),
  ['omarchy', 'system', 'reboot'],
  'reboot maps to omarchy system reboot'
)

let held = null
try {
  mutations.argvForSystem('execute', { argv: ['pacman', '-S', 'htop'] })
} catch (error) {
  held = error
}
assert(held && held.code === 'L2_UNREPRESENTABLE', 'generic execute is not on dispatch.system')

const beforePkg = calls.length
const pending = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
assertEqual(pending.pending, true, 'pkg.add asks for approval')
assertDeepEqual(calls[beforePkg], ['omarchy', 'snapshot', 'create'], 'pkg.add snapshots before asking')
assertEqual(
  calls.filter((argv) => argv[1] === 'pkg').length,
  0,
  'pending pkg.add does not install yet'
)

const denied = harness.decide(pending.approvalId, 'deny')
assertEqual(denied.decision.decision, 'deny', 'pkg.add deny is recorded')
assertEqual(
  calls.filter((argv) => argv[1] === 'pkg').length,
  0,
  'denied pkg.add does not install'
)

const pendingAgain = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
const allowed = harness.decide(pendingAgain.approvalId, 'allow')
assertEqual(allowed.ok, true, 'allowed pkg.add proceeds')
assertDeepEqual(
  calls[calls.length - 1],
  ['omarchy', 'pkg', 'add', 'htop'],
  'allowed pkg.add calls the Omarchy effector'
)
assert(
  calls.every((argv) => argv[0] === 'omarchy'),
  'system argv is unwrapped omarchy; no sudo/pkexec wrapper'
)
assert(
  harness.store.events().some((event) => event.type === 'omarchy/pkg'),
  'pkg.add emits an audit event'
)

const dup = harness.decide(pendingAgain.approvalId, 'allow')
assertEqual(dup.idempotent, true, 'duplicate pkg.add allow is idempotent')
assertEqual(
  calls.filter((argv) => argv[1] === 'pkg' && argv[2] === 'add').length,
  1,
  'idempotent allow does not install again'
)

let extra = null
try {
  harness.dispatch.system['pkg.add']({ packages: ['htop'], exec: 'bash' })
} catch (error) {
  extra = error
}
assert(extra && extra.code === 'FORBIDDEN_ARG', 'pkg.add rejects extra exec-shaped args')

let flagPkg = null
try {
  harness.dispatch.system['pkg.add']({ packages: ['--noconfirm'] })
} catch (error) {
  flagPkg = error
}
assert(flagPkg && flagPkg.code === 'FORBIDDEN_ARG', 'pkg.add rejects flag-like package names')

const snapshotFailed = createHarness({
  logPath: path.join(dir, 'snap-fail.jsonl'),
  now: () => '2026-08-20T00:00:00.000Z',
  newId: () => 'fail-1',
  exec(argv) {
    if (argv[1] === 'snapshot') {
      return { status: 1, stdout: '', stderr: 'no snapper' }
    }
    fail('pkg.add must not execute when snapshot fails', argv.join(' '))
    return { status: 1, stdout: '', stderr: '' }
  },
})
let snapErr = null
try {
  snapshotFailed.dispatch.system['pkg.add']({ packages: ['htop'] })
} catch (error) {
  snapErr = error
}
assert(snapErr && snapErr.code === 'SNAPSHOT_FAILED', 'required snapshot failure fail-closes')

const rebootPending = harness.dispatch.system['system.reboot']({})
assertEqual(rebootPending.pending, true, 'reboot always asks')
assertEqual(
  calls.filter((argv) => argv[1] === 'system' && argv[2] === 'reboot').length,
  0,
  'pending reboot does not exec'
)
assertEqual(
  calls.filter((argv) => argv[1] === 'snapshot').length,
  2,
  'reboot does not take an extra preflight snapshot'
)
const rebooted = harness.decide(rebootPending.approvalId, 'allow')
assertEqual(rebooted.ok, true, 'allowed reboot proceeds')
assertDeepEqual(
  calls[calls.length - 1],
  ['omarchy', 'system', 'reboot'],
  'allowed reboot calls the Omarchy effector'
)

const updatePending = harness.dispatch.system.update({})
assertEqual(updatePending.pending, true, 'update asks after snapshot')
assert(
  calls.some((argv) => argv[1] === 'snapshot' && argv[2] === 'create'),
  'update snapshots before asking'
)
assertEqual(
  calls.filter((argv) => argv[1] === 'update').length,
  0,
  'pending update does not run yet'
)
harness.decide(updatePending.approvalId, 'allow')
assertDeepEqual(
  calls[calls.length - 1],
  ['omarchy', 'update', '-y'],
  'allowed update is unattended'
)

const snapCreate = harness.dispatch.system['snapshot.create']({})
assertEqual(snapCreate.pending, true, 'snapshot.create asks before creating')
harness.decide(snapCreate.approvalId, 'allow')
assertDeepEqual(
  calls[calls.length - 1],
  ['omarchy', 'snapshot', 'create'],
  'snapshot.create executes the effector after allow'
)

const init = harness.acp.handle({ jsonrpc: '2.0', id: 1, method: 'initialize' })
assertEqual(init.result.write, true, 'ACP still advertises L1 write')
assertEqual(init.result.system, true, 'ACP advertises L2 system write')
assertEqual(init.result.dispatch, 'l2', 'ACP dispatch is the L2 surface')
assert(init.result.tools.includes('pkg.add'), 'ACP tools include pkg.add')
assert(!init.result.tools.includes('execute'), 'ACP tools omit generic execute')
assert(!init.result.tools.includes('omarchy_cli'), 'ACP tools omit omarchy_cli')

const acpPkg = harness.acp.handle({
  jsonrpc: '2.0',
  id: 2,
  method: 'tools/call',
  params: { name: 'pkg.add', arguments: { packages: ['ripgrep'] } },
})
assertEqual(acpPkg.result.content.pending, true, 'ACP pkg.add is pending approval')

const acpExec = harness.acp.handle({
  jsonrpc: '2.0',
  id: 3,
  method: 'tools/call',
  params: { name: 'execute', arguments: { argv: ['pacman', '-S', 'htop'] } },
})
assertEqual(acpExec.error.message, 'L2_UNREPRESENTABLE', 'ACP cannot call generic execute')

const config = harness.dumpConfig()
assertEqual(config.phase, 3, 'dump-config phase is 3')
assertEqual(config.dispatch, 'l2', 'dump-config dispatch is l2')
assertEqual(config.write, true, 'dump-config write is true')
assertEqual(config.system, true, 'dump-config system is true')
assertEqual(config.l1_surface, 'executable', 'L1 surface stays executable')
assertEqual(config.l2_surface, 'executable', 'L2 surface is executable')
assertEqual(config.preset, 'session', 'permission preset stays session; system acts still ask')
JS

: >"$CALL_LOG"
: >"$MUTATION_LOG"

system_json=$("$ROOT/bin/omarchy-harness-host" system pkg.add '{"packages":["htop"]}')
echo "$system_json" | jq -e '.pending == true' >/dev/null || fail "system CLI pkg.add is pending" "$system_json"
grep -qx 'snapshot create' "$CALL_LOG" || fail "system CLI snapshots first" "$(cat "$CALL_LOG")"
if grep -qx 'pkg add htop' "$CALL_LOG"; then
  fail "system CLI does not install before approval" "$(cat "$CALL_LOG")"
fi
approval_id=$(echo "$system_json" | jq -r '.approvalId')
"$ROOT/bin/omarchy-harness-approve" "$approval_id" >/dev/null
grep -qx 'pkg add htop' "$CALL_LOG" || fail "approved system CLI installs via omarchy pkg add" "$(cat "$CALL_LOG")"
pass "system CLI pkg.add is snapshot then approval then exec"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.phase == 3 and .dispatch == "l2" and .write == true and .system == true and .l2_surface == "executable" and .preset == "session"' >/dev/null
pass "dump-config reports executable L2 without auto-approve"

if grep -Eq 'bash |pacman |hyprctl ' "$CALL_LOG"; then
  fail "L2 system does not dispatch untyped mutation paths" "$(cat "$CALL_LOG")"
fi
if grep -- '--exec' "$CALL_LOG" | grep -vq 'omarchy-shell shell summon omarchy.harness'; then
  fail "L2 approval card exec is only overlay summon" "$(cat "$CALL_LOG")"
fi
if [[ -s $MUTATION_LOG ]]; then
  fail "L2 system does not take untyped mutation paths" "$(cat "$MUTATION_LOG")"
fi
pass "L2 system cannot represent generic execute or shell"
