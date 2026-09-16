#!/bin/bash

# Snapshot preflight: restore points are taken after the human allows the
# mutation (not at pending time), through a backend probe — snapper on real
# btrfs Omarchy installs, a package-journal fallback on non-btrfs systems
# (the try-omarchy VM) — and fail-closed when no backend can produce one.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command node
require_command jq

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.local/state/omarchy/harness/sessions"
trap 'rm -rf "$TEST_HOME"' EXIT

run_node_test <<'JS'
const fs = require('fs')
const os = require('os')
const { createHarness } = requireFromRoot('harness/lib/omarchy-harness.js')

function makeHarness(exec) {
  const calls = []
  let ids = 0
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-snap-'))
  const harness = createHarness({
    logPath: path.join(dir, 'current.jsonl'),
    now: () => '2026-09-14T00:00:00.000Z',
    newId: () => 'snap-' + (++ids),
    tty: true,
    exec(argv) {
      calls.push(argv.slice())
      return exec(argv)
    },
    hyprctl() {
      return { status: 0, stdout: '[]', stderr: '' }
    },
  })
  return { harness, calls }
}

function auditEvents(harness, type) {
  return harness.store.events().filter((event) => event.type === type)
}

const ok = (stdout) => ({ status: 0, stdout: stdout || 'ok\n', stderr: '' })

// ---- snapper backend: allow-time restore point with per-config ids ----
{
  const exec = (argv) => {
    if (argv[0] === 'sudo' && argv[1] === 'snapper' && argv.includes('list-configs')) {
      return ok('config\nroot\nhome\n')
    }
    if (argv[0] === 'sudo' && argv[1] === 'snapper' && argv.includes('create')) {
      return ok(argv[3] === 'root' ? '42\n' : '7\n')
    }
    return ok()
  }
  const { harness, calls } = makeHarness(exec)
  const pending = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
  assertEqual(pending.pending, true, 'pkg.add is pending')
  assertEqual(pending.request.mutation.snapshot, true, 'pending mutation carries snapshot intent, not a recorded fact')
  assert(
    !calls.some((argv) => argv.includes('snapper')),
    'pending does not snapshot before the human decides'
  )

  const allow = harness.decide(pending.approvalId, 'allow')
  assertEqual(allow.ok, true, 'allow resolves')
  assertEqual(allow.executed.ok, true, 'pkg.add executes after allow')
  const snapIdx = calls.findIndex((argv) => argv.includes('snapper') && argv.includes('create'))
  const pkgIdx = calls.findIndex((argv) => argv[0] === 'omarchy' && argv[1] === 'pkg' && argv[2] === 'add')
  assert(snapIdx >= 0 && pkgIdx >= 0 && snapIdx < pkgIdx, 'restore point is taken before the mutation executes')

  const preflight = auditEvents(harness, 'omarchy/snapshot')
  assertEqual(preflight.length, 1, 'one preflight snapshot audit event')
  assertEqual(preflight[0].stage, 'preflight', 'audit stage is preflight')
  assertEqual(preflight[0].for, 'pkg.add', 'audit names the guarded mutation')
  assertEqual(preflight[0].backend, 'snapper', 'audit records the snapper backend')
  assertDeepEqual(preflight[0].ids, { root: '42', home: '7' }, 'audit records per-config snapshot ids')
  assert(allow.executed.snapshot, 'executed result carries the restore point')
  assertDeepEqual(
    allow.executed.snapshot.ids,
    preflight[0].ids,
    'the executed result references the audited snapshot ids'
  )

  calls.length = 0
  const denied = harness.dispatch.system['pkg.drop']({ packages: ['htop'] })
  harness.decide(denied.approvalId, 'deny')
  assert(
    !calls.some((argv) => argv.includes('snapper')),
    'a denied mutation never snapshots'
  )
  assertEqual(
    auditEvents(harness, 'omarchy/snapshot').length,
    1,
    'deny adds no snapshot audit event'
  )
}

// ---- snapper create failure: fail-closed with SNAPSHOT_FAILED ----
{
  const exec = (argv) => {
    if (argv[0] === 'sudo' && argv[1] === 'snapper' && argv.includes('list-configs')) {
      return ok('config\nroot\n')
    }
    if (argv[0] === 'sudo' && argv[1] === 'snapper') {
      return { status: 1, stdout: '', stderr: 'IO error: snapshot create failed\n' }
    }
    return ok()
  }
  const { harness, calls } = makeHarness(exec)
  const pending = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
  const allow = harness.decide(pending.approvalId, 'allow')
  assertEqual(allow.ok, true, 'the decision itself resolves')
  assert(
    !allow.executed,
    'fail-closed: an allowed mutation does not execute when the restore point fails'
  )
  assertEqual(allow.snapshot.ok, false, 'the snapshot record reports failure')
  assertEqual(allow.snapshot.code, 'SNAPSHOT_FAILED', 'the failure is surfaced with its code')
  assertEqual(allow.snapshot.backend, 'snapper', 'the failing backend is named')
  assert(
    !calls.some((argv) => argv[0] === 'omarchy' && argv[1] === 'pkg'),
    'the effector never runs without a restore point'
  )
  const preflight = auditEvents(harness, 'omarchy/snapshot')
  assertEqual(preflight.length, 1, 'the failed preflight is audited')
  assertEqual(preflight[0].status, 1, 'failed preflight status is recorded')
  assertEqual(preflight[0].error, 'SNAPSHOT_FAILED', 'the audit carries the error code')
}

// ---- package-journal backend: the non-btrfs (VM) path ----
{
  const exec = (argv) => {
    if (argv[0] === 'sudo' && argv[1] === 'snapper') {
      return { status: 127, stdout: '', stderr: 'sudo: snapper: command not found\n' }
    }
    if (argv[0] === 'pacman' && argv[1] === '--version') {
      return ok('Pacman v7.0.0 - libalpine v15.0.0\n')
    }
    if (argv[0] === 'pacman' && argv[1] === '-Qe') {
      return ok('bash 5.2\nhtop 1.0\n')
    }
    return ok()
  }
  const { harness } = makeHarness(exec)
  const pending = harness.dispatch.system['pkg.add']({ packages: ['strace'] })
  const allow = harness.decide(pending.approvalId, 'allow')
  assertEqual(allow.executed.ok, true, 'journal backend unblocks pkg.add on non-btrfs systems')

  const preflight = auditEvents(harness, 'omarchy/snapshot')
  assertEqual(preflight[0].backend, 'package-journal', 'audit records the journal backend')
  assert(preflight[0].id, 'audit records the restore point id')
  const restorePoint = JSON.parse(
    fs.readFileSync(
      path.join(process.env.HOME, '.local/state/omarchy/harness/restore-points', preflight[0].id + '.json'),
      'utf8'
    )
  )
  assertDeepEqual(restorePoint.packages, ['bash 5.2', 'htop 1.0'], 'restore point records the explicit package list')
  assertEqual(restorePoint.for, 'pkg.add', 'restore point names the guarded mutation')
  assert(allow.executed.snapshot, 'executed result carries the journal restore point')
  assertEqual(
    allow.executed.snapshot.id,
    preflight[0].id,
    'the executed result references the restore point id recorded in the audit'
  )
}

// ---- no backend: fail-closed ----
{
  const exec = (argv) => {
    if (argv[0] === 'sudo' && argv[1] === 'snapper') {
      return { status: 127, stdout: '', stderr: 'not found\n' }
    }
    if (argv[0] === 'pacman') {
      return { status: 127, stdout: '', stderr: 'not found\n' }
    }
    return ok()
  }
  const { harness, calls } = makeHarness(exec)
  const pending = harness.dispatch.system['pkg.add']({ packages: ['htop'] })
  const allow = harness.decide(pending.approvalId, 'allow')
  assert(!allow.executed, 'fail-closed: without a restore point the mutation does not execute')
  assert(
    !calls.some((argv) => argv[0] === 'omarchy' && argv[1] === 'pkg' && argv[2] === 'add'),
    'the effector never runs without a restore point'
  )
  const preflight = auditEvents(harness, 'omarchy/snapshot')
  assertEqual(preflight[0].status, 1, 'failed preflight is audited')
  assertEqual(allow.snapshot.code, 'SNAPSHOT_BACKEND_UNAVAILABLE', 'the failure is surfaced with a code')
}

// ---- probe caching: one list-configs per harness ----
{
  let probes = 0
  const exec = (argv) => {
    if (argv[0] === 'sudo' && argv[1] === 'snapper' && argv.includes('list-configs')) {
      probes += 1
      return ok('config\nroot\n')
    }
    if (argv[0] === 'sudo' && argv[1] === 'snapper' && argv.includes('create')) {
      return ok('42\n')
    }
    return ok()
  }
  const { harness } = makeHarness(exec)
  for (const op of [['pkg.add', { packages: ['a'] }], ['pkg.drop', { packages: ['a'] }]]) {
    const pending = harness.dispatch.system[op[0]](op[1])
    harness.decide(pending.approvalId, 'allow')
  }
  assertEqual(probes, 1, 'the backend is probed once per harness, not per mutation')
}
JS

pass "snapshot preflight: allow-time restore points, snapper + journal backends, fail-closed"
