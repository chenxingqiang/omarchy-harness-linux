#!/bin/bash

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
export XDG_RUNTIME_DIR="$TEST_HOME/runtime"
mkdir -p "$STUB_BIN" "$XDG_RUNTIME_DIR" "$TEST_HOME/.local/state/omarchy/harness/sessions"
trap 'rm -rf "$TEST_HOME"' EXIT

cat >"$STUB_BIN/omarchy" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${CALL_LOG:?}"
case "$*" in
  "theme list")
    echo "Tokyo Night"
    echo "Catppuccin"
    ;;
  "theme current")
    echo "Tokyo Night"
    ;;
  "theme set"*)
    printf '%s\n' "$*" >>"${MUTATION_LOG:?}"
    echo "theme changed" >&2
    exit 1
    ;;
  "font list")
    echo "CaskaydiaMono Nerd Font"
    ;;
  "plugin list --json"|"plugin list")
    echo '[{"id":"omarchy.clock","enabled":true}]'
    ;;
  "version")
    echo "dev (test)"
    ;;
  "version channel")
    echo "edge"
    ;;
  "commands --json")
    echo '{"ok":true,"commands":[{"route":"omarchy theme list","group":"theme","name":"list","summary":"List available themes","hidden":false},{"route":"omarchy apply system","group":"apply","name":"system","summary":"hidden","hidden":true}]}'
    ;;
  "pkg add"*)
    printf '%s\n' "$*" >>"${MUTATION_LOG:?}"
    exit 1
    ;;
  *)
    echo "omarchy-stub: unhandled: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN/omarchy"

cat >"$STUB_BIN/hyprctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'hyprctl %s\n' "$*" >>"${CALL_LOG:?}"
case "$*" in
  "-j clients")
    echo '[{"address":"0x1","title":"term","workspace":{"id":1}}]'
    ;;
  "-j workspaces")
    echo '[{"id":1,"name":"1"}]'
    ;;
  "-j activewindow")
    echo '{"address":"0x1","title":"term"}'
    ;;
  *)
    echo "[]"
    ;;
esac
EOF
chmod +x "$STUB_BIN/hyprctl"

export CALL_LOG MUTATION_LOG
export PATH="$STUB_BIN:$ROOT/bin:$PATH"

run_node_test <<'JS'
const harnessLib = requireFromRoot('harness/lib/omarchy-harness.js')
const { classifyRoute, createHarness, createSessionLog } = harnessLib

assertEqual(classifyRoute('theme list'), 'readonly', 'theme list is a readonly route')
assertEqual(classifyRoute('theme set', { hidden: false }), 'write', 'theme set is a write route')
assertEqual(classifyRoute('apply system'), 'hidden', 'apply system is hidden')
assertEqual(classifyRoute('setup security fingerprint'), 'interactive', 'setup is interactive')
assertEqual(classifyRoute('pkg add'), 'write', 'pkg add is a write route')

const calls = []
const harness = createHarness({
  exec(argv) {
    calls.push(argv.slice())
    if (argv[1] === 'theme' && argv[2] === 'list') {
      return { status: 0, stdout: 'Tokyo Night\n', stderr: '' }
    }
    if (argv[1] === 'theme' && argv[2] === 'current') {
      return { status: 0, stdout: 'Tokyo Night\n', stderr: '' }
    }
    if (argv[1] === 'version' && argv[2] === 'channel') {
      return { status: 0, stdout: 'edge\n', stderr: '' }
    }
    if (argv[1] === 'version') {
      return { status: 0, stdout: 'dev\n', stderr: '' }
    }
    if (argv[1] === 'plugin') {
      return { status: 0, stdout: '[]\n', stderr: '' }
    }
    if (argv[1] === 'font') {
      return { status: 0, stdout: 'Mono\n', stderr: '' }
    }
    if (argv[1] === 'commands') {
      return {
        status: 0,
        stdout: JSON.stringify({
          ok: true,
          commands: [
            { route: 'omarchy theme list', group: 'theme', name: 'list', summary: 'List', hidden: false },
            { route: 'omarchy apply system', group: 'apply', name: 'system', summary: 'hidden', hidden: true },
          ],
        }),
        stderr: '',
      }
    }
    fail('unexpected exec', argv.join(' '))
    return { status: 1, stdout: '', stderr: '' }
  },
  hyprctl() {
    return { status: 0, stdout: '[]', stderr: '' }
  },
  now: () => '2026-08-20T00:00:00.000Z',
})

assert(harness.dispatch.write !== undefined, 'Phase 3 L1 has dispatch.write')
assert(harness.dispatch.system === undefined, 'Phase 1 has no dispatch.system')
assert(harness.dispatch.write.execute === undefined, 'dispatch.write has no generic execute')
assert(Object.isFrozen(harness.dispatch), 'dispatch object is frozen')
assert(Object.isFrozen(harness.dispatch.write), 'dispatch.write is frozen')

const listed = harness.dispatch.readonly.execute('theme list')
assertEqual(listed.stdout, 'Tokyo Night\n', 'readonly dispatch runs theme list')
assertEqual(calls.some((argv) => argv.includes('set')), false, 'theme list does not call a write argv')

let writeError = null
try {
  harness.dispatch.readonly.execute('theme set', ['tokyo-night'])
} catch (error) {
  writeError = error
}
assert(writeError && writeError.code === 'WRITE_ROUTE_IMPOSSIBLE', 'write route is impossible on readonly dispatch')

let hiddenError = null
try {
  harness.dispatch.readonly.execute('apply system')
} catch (error) {
  hiddenError = error
}
assert(hiddenError && hiddenError.kind === 'hidden', 'hidden route is rejected')

let interactiveError = null
try {
  harness.dispatch.readonly.execute('setup security fingerprint')
} catch (error) {
  interactiveError = error
}
assert(interactiveError && interactiveError.kind === 'interactive', 'interactive route is rejected')

const before = calls.length
try {
  harness.dispatch.readonly.execute('pkg add', ['htop'])
} catch (error) {
  assertEqual(error.code, 'WRITE_ROUTE_IMPOSSIBLE', 'pkg add is an impossible write')
}
assertEqual(calls.length, before, 'impossible write does not spawn a subprocess')

const log = createSessionLog({ now: () => '2026-08-20T00:00:00.000Z' })
const ephemeralPayload = harness.tools.omarchy_status()
assertEqual(log.events.length, 0, 'ephemeral observation is not logged')

const first = log.recordModelVisibleStatus(ephemeralPayload)
assertEqual(first.type, 'omarchy/status', 'model-visible observation emits omarchy/status')
assert(Boolean(first.snapshot && first.snapshot.identity), 'model-visible observation has snapshot identity')
assertEqual(first.snapshot.version, 1, 'snapshot identity version is 1')

const second = log.recordModelVisibleStatus(ephemeralPayload)
assertEqual(second.snapshot.identity, first.snapshot.identity, 'unchanged identity is reused')
assertEqual(log.events.length, 1, 'duplicate model-visible status is not re-logged')

const config = harness.dumpConfig()
for (const key of ['profile', 'dsh', 'dsh_commit', 'node', 'bundle_sha256', 'preset', 'approval', 'overlay', 'phase', 'dispatch']) {
  assert(Object.prototype.hasOwnProperty.call(config, key), 'dump-config includes ' + key)
}
assertEqual(config.profile, 'omarchy', 'dump-config profile is omarchy')
assertEqual(config.overlay, 'acp', 'dump-config overlay protocol is acp')
assertEqual(config.approval, 'acp', 'dump-config approval protocol is acp')
assertEqual(config.phase, 3, 'dump-config phase is 3')
assertEqual(config.dispatch, 'l1', 'dump-config dispatch is l1')
assertEqual(config.session_write, true, 'dump-config session_write is true')
assertEqual(config.write, true, 'dump-config write is true')
assertEqual(config.system, false, 'dump-config system is false')
assert(String(config.bundle_sha256).length === 64, 'bundle hash is sha256 hex')

const themes = harness.tools.omarchy_theme_list()
assertEqual(themes[0], 'Tokyo Night', 'omarchy_theme_list uses readonly theme list')
const commandHits = harness.tools.omarchy_commands({ query: 'theme' })
assert(commandHits.some((entry) => entry.name === 'list'), 'omarchy_commands filters the catalog')
assert(!commandHits.some((entry) => entry.hidden), 'omarchy_commands omits hidden commands')

const init = harness.acp.handle({ jsonrpc: '2.0', id: 1, method: 'initialize' })
assertEqual(init.result.dispatch, 'l1', 'ACP initialize advertises L1 dispatch')
assertEqual(init.result.write, true, 'ACP initialize advertises L1 write')
assertEqual(init.result.system, false, 'ACP initialize does not advertise system')
assertEqual(init.result.sessionWrite, true, 'ACP initialize advertises session write')
assert(!init.result.tools.includes('omarchy_theme_set'), 'ACP tool list has no untyped write alias')
assert(init.result.tools.includes('omarchy_status'), 'ACP tool list includes omarchy_status')
assert(init.result.tools.includes('theme.set'), 'ACP tool list includes finite L1 ops')

const created = harness.acp.handle({ jsonrpc: '2.0', id: 2, method: 'session/new' })
assertEqual(created.result.sessionId, 'omarchy-session', 'ACP session/new returns a session id')

const writeCall = harness.acp.handle({
  jsonrpc: '2.0',
  id: 3,
  method: 'tools/call',
  params: { name: 'omarchy_theme_set', arguments: { theme: 'tokyo-night' } },
})
assertEqual(writeCall.error.message, 'L2_UNREPRESENTABLE', 'ACP tools/call cannot invoke an untyped write tool')

const statusCall = harness.acp.handle({
  jsonrpc: '2.0',
  id: 4,
  method: 'tools/call',
  params: { name: 'omarchy_theme_list' },
})
assert(Array.isArray(statusCall.result.content), 'ACP tools/call runs a readonly tool')

const profile = requireFromRoot('harness/lib/acp.js').loadProfile()
assertEqual(profile.dispatch, 'l1', 'omarchy profile is the L1 write surface')
assertEqual(profile.write, true, 'omarchy profile advertises L1 write')
assertEqual(profile.system, false, 'omarchy profile does not advertise system write')
assertEqual(profile.clients.overlay, 'acp', 'overlay is an ACP client')
assertEqual(profile.clients.cli, 'acp', 'harness CLI is an ACP client')
assertEqual(profile.clients.menu, 'data-plane', 'menu stays on the data plane')
assertEqual(profile.clients.keybind, 'data-plane', 'keybind stays on the data plane')
assertEqual(profile.clients.bar, 'data-plane', 'status bar stays on the data plane')
JS

: >"$CALL_LOG"
: >"$MUTATION_LOG"

output=$("$ROOT/bin/omarchy" --help)
[[ $output == *"harness"* ]] || fail "main help lists the harness group"
pass "main help lists the harness group"

"$ROOT/bin/omarchy" commands --check >/dev/null
pass "harness commands pass metadata check"

dump=$("$ROOT/bin/omarchy-harness-dump-config")
[[ $dump == *"profile: omarchy"* ]] || fail "dump-config prints profile" "$dump"
[[ $dump == *"overlay: acp"* ]] || fail "dump-config prints overlay=acp" "$dump"
[[ $dump == *"approval: acp"* ]] || fail "dump-config prints approval=acp" "$dump"
[[ $dump == *"dispatch: l1"* ]] || fail "dump-config prints dispatch=l1" "$dump"
pass "dump-config prints runtime provenance"

dump_json=$("$ROOT/bin/omarchy-harness-dump-config" --json)
echo "$dump_json" | jq -e '.profile == "omarchy" and .overlay == "acp" and .dispatch == "l1" and .write == true and .system == false and .clients.menu == "data-plane" and .clients.overlay == "acp"' >/dev/null
pass "dump-config --json is structured provenance"

status=0
"$ROOT/bin/omarchy-harness-status" || status=$?
(( status != 0 )) || fail "harness status is nonzero when the unit is down"
pass "service-down status fails closed"

prompt_out=$("$ROOT/bin/omarchy-harness-prompt" "what theme is active")
echo "$prompt_out" | jq -e '.ok == true and .modelVisible == true and (.snapshot.identity | length == 64)' >/dev/null
pass "prompt records a model-visible snapshot identity"

log_file="$TEST_HOME/.local/state/omarchy/harness/sessions/current.jsonl"
[[ -f $log_file ]] || fail "prompt writes a session log"
grep -q '"type":"omarchy/status"' "$log_file" || fail "session log contains omarchy/status"
grep -q '"modelVisible":true' "$log_file" || fail "omarchy/status is marked model-visible"
pass "model-visible observation is logged"

if [[ -s $MUTATION_LOG ]]; then
  fail "prompt does not mutate the desktop" "$(cat "$MUTATION_LOG")"
fi
if grep -Eq 'theme set|pkg add' "$CALL_LOG"; then
  fail "prompt does not dispatch write routes" "$(cat "$CALL_LOG")"
fi
pass "prompt is observe-only"

unit="$ROOT/default/systemd/user/omarchy-harness.service"
grep -q '^WantedBy=graphical-session.target$' "$unit" || fail "unit is wanted by graphical-session.target"
grep -q '^Restart=always$' "$unit" || fail "unit restarts"
grep -q '^ConditionPathExists=/usr/lib/omarchy-harness/node/bin/node$' "$unit" ||
  fail "unit requires the pinned Node runtime"
grep -q '^User=' "$unit" && fail "user unit does not set User="
pass "harness user unit is fail-closed and session-scoped"

if grep -q 'omarchy-harness.service' "$ROOT/install/user/first-run/enable-user-units.sh"; then
  fail "Phase 1 does not enable the harness unit at first-run"
fi
pass "Phase 1 does not enable the harness unit at first-run"
