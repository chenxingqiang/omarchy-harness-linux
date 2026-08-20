#!/bin/bash

# Overlay daily-driver: pending cards distinguish session / desktop / system.
# Overlay stays an ACP client. Keybind summons it; it does not steal the agent launcher.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node

run_node_test <<'JS'
const fs = require('fs')
const view = requireFromRoot('shell/plugins/harness/SessionView.js')

const resetView = view.parseHostState(JSON.stringify({
  metadata: { title: 'Inspect theme' },
  pending: {
    'id-reset': { approvalId: 'id-reset', mutation: { type: 'reset' } },
  },
}))
assertEqual(resetView.hostDown, false, 'valid JSON is not host-down')
assertEqual(resetView.pending[0].kind, 'session', 'reset is a session card')
assertEqual(resetView.pending[0].badge, 'Session', 'reset badge is Session')
assertEqual(resetView.pending[0].tone, 'muted', 'session cards use muted tone')
assertEqual(resetView.pending[0].snapshotFirst, false, 'reset does not claim a snapshot')
assertEqual(resetView.pending[0].summary, 'Reset this Harness session', 'reset keeps its summary')
assert(
  resetView.pending[0].hint.includes('desktop') && resetView.pending[0].hint.toLowerCase().includes('unchanged'),
  'session hint says the desktop stays unchanged'
)
assertEqual(resetView.statusText, '1 session approval pending', 'single session card has a plane status')

const launchView = view.parseHostState(JSON.stringify({
  metadata: { title: 'Launch' },
  pending: {
    'id-launch': {
      approvalId: 'id-launch',
      mutation: { type: 'l1', op: 'launch.terminal', summary: 'Launch the default terminal' },
    },
  },
}))
assertEqual(launchView.pending[0].kind, 'desktop', 'L1 launch is a desktop card')
assertEqual(launchView.pending[0].badge, 'Desktop', 'L1 badge is Desktop')
assertEqual(launchView.pending[0].tone, 'accent', 'desktop cards use accent tone')
assertEqual(launchView.pending[0].snapshotFirst, false, 'L1 does not snapshot first')
assert(
  launchView.pending[0].hint.toLowerCase().includes('desktop'),
  'desktop hint names the desktop plane'
)
assert(
  !launchView.pending[0].hint.toLowerCase().includes('snapshot'),
  'desktop hint does not claim a snapshot'
)
assertEqual(launchView.statusText, '1 desktop approval pending', 'single desktop card has a plane status')

const pkgView = view.parseHostState(JSON.stringify({
  metadata: { title: 'Install' },
  pending: {
    'id-pkg': {
      approvalId: 'id-pkg',
      mutation: {
        type: 'l2',
        op: 'pkg.add',
        args: { packages: ['htop'] },
        summary: 'Install package: htop',
        snapshot: { status: 0 },
      },
    },
  },
}))
assertEqual(pkgView.pending[0].kind, 'system', 'L2 pkg.add is a system card')
assertEqual(pkgView.pending[0].badge, 'System', 'L2 badge is System')
assertEqual(pkgView.pending[0].tone, 'urgent', 'system cards use urgent tone')
assertEqual(pkgView.pending[0].snapshotFirst, true, 'pkg.add card reports the recorded snapshot')
assert(
  pkgView.pending[0].hint.toLowerCase().includes('snapshot'),
  'system hint names the snapshot when one was recorded'
)
assertEqual(pkgView.statusText, '1 system approval pending', 'single system card has a plane status')

const rebootView = view.parseHostState(JSON.stringify({
  pending: {
    'id-reboot': {
      approvalId: 'id-reboot',
      mutation: { type: 'l2', op: 'system.reboot', summary: 'Reboot the system', snapshot: null },
    },
  },
}))
assertEqual(rebootView.pending[0].kind, 'system', 'reboot is still a system card')
assertEqual(rebootView.pending[0].snapshotFirst, false, 'reboot does not invent a snapshot')
assert(
  !rebootView.pending[0].hint.toLowerCase().includes('snapshot taken'),
  'reboot hint does not claim a snapshot was taken'
)

const mixed = view.parseHostState(JSON.stringify({
  pending: {
    a: { approvalId: 'a', mutation: { type: 'l1', op: 'launch.browser' } },
    b: { approvalId: 'b', mutation: { type: 'l2', op: 'update', snapshot: { status: 0 } } },
    c: { approvalId: 'c', mutation: { type: 'reset' } },
  },
}))
assertEqual(mixed.pending.length, 3, 'mixed pending keeps every card')
assertEqual(
  mixed.statusText,
  '3 pending approvals: 1 system, 1 desktop, 1 session',
  'mixed status counts each plane'
)
assertEqual(view.keyboardHint(), 'Y allow · N deny · Esc close · R refresh', 'overlay keyboard hint is stable')

const overlay = fs.readFileSync(path.join(root, 'shell/plugins/harness/Overlay.qml'), 'utf8')
assert(/modelData.badge/.test(overlay), 'overlay renders the plane badge')
assert(/modelData.hint/.test(overlay), 'overlay renders the plane hint')
assert(/modelData.tone/.test(overlay), 'overlay maps tone to theme color')
assert(/Color\.urgent/.test(overlay), 'system cards use the urgent theme color')
assert(/Qt\.Key_Y/.test(overlay), 'Y allows the first pending card')
assert(/Qt\.Key_N/.test(overlay), 'N denies the first pending card')
assert(/omarchy-harness-approve/.test(overlay), 'keyboard allow still posts to the host')
assert(/omarchy-harness-deny/.test(overlay), 'keyboard deny still posts to the host')
assert(!/pkexec/.test(overlay), 'overlay does not call pkexec')
assert(!/hyprctl/.test(overlay), 'overlay does not call hyprctl')
assert(!/omarchy-harness-approve/.test(overlay.split('function open')[1].split('function close')[0]), 'open does not auto-allow')

const bindings = fs.readFileSync(path.join(root, 'default/hypr/bindings/utilities.lua'), 'utf8')
assert(
  /SUPER \+ SHIFT \+ H/.test(bindings) && /omarchy\.harness/.test(bindings),
  'Harness overlay has a keybind'
)
assert(
  /o\.bind\("SUPER \+ SHIFT \+ CTRL \+ A", "Agent", "omarchy-agent --pick"\)/.test(bindings),
  'Harness keybind does not steal the agent launcher'
)
assert(
  !/omarchy-harness-approve/.test(bindings),
  'Harness keybind does not auto-allow'
)

const firstRun = fs.readFileSync(path.join(root, 'install/user/first-run/enable-user-units.sh'), 'utf8')
assert(
  !/omarchy-harness\.service/.test(firstRun),
  'daily-driver overlay still does not enable the user unit at first-run'
)
JS

pass "overlay daily-driver cards distinguish session, desktop, and system"
