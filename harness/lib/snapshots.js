'use strict'

// Snapshot preflight backends: restore points taken after a human allows an
// L2 mutation (see plans/harness.md, Rev 9). The backend is probed once per
// harness:
//   - snapper on real btrfs Omarchy installs (per-config numbered snapshots,
//     ids captured for rollback addressing);
//   - package-journal on non-btrfs systems like the try-omarchy VM: the
//     explicit package list is journaled so the contract's inverse
//     mutations (pkg.add <-> pkg.drop the recorded names) can restore state;
//   - none: fail-closed — an allowed mutation without a restore point must
//     not execute (SNAPSHOT_BACKEND_UNAVAILABLE).

const fs = require('fs')
const path = require('path')

function parseSnapperConfigs(stdout) {
  return String(stdout || '')
    .split('\n')
    .slice(1)
    .map((line) => line.split(',')[0].trim())
    .filter(Boolean)
}

function probe({ exec }) {
  const listing = exec(['sudo', 'snapper', '--csvout', 'list-configs'])
  if (listing.status === 0) {
    const configs = parseSnapperConfigs(listing.stdout)
    if (configs.length > 0) {
      return { backend: 'snapper', configs }
    }
    // snapper installed but unconfigured snapshots nothing (mirrors
    // omarchy-snapshot's own semantics) — fall through.
  }
  if (exec(['pacman', '--version']).status === 0) {
    return { backend: 'package-journal' }
  }
  return { backend: 'none' }
}

function createSnapper(op, probed, ctx) {
  const ids = {}
  for (const config of probed.configs) {
    const argv = [
      'sudo',
      'snapper',
      '-c',
      config,
      'create',
      '-c',
      'number',
      '-d',
      `omarchy-harness:${op}`,
      '--print-number',
    ]
    const result = ctx.exec(argv)
    if (result.status !== 0) {
      return {
        ok: false,
        backend: 'snapper',
        code: 'SNAPSHOT_FAILED',
        stderr: result.stderr,
      }
    }
    ids[config] = result.stdout.replace(/\s+$/, '')
  }
  return { ok: true, backend: 'snapper', ids }
}

function createJournal(op, ctx) {
  const listed = ctx.exec(['pacman', '-Qe'])
  if (listed.status !== 0) {
    return {
      ok: false,
      backend: 'package-journal',
      code: 'SNAPSHOT_FAILED',
      stderr: listed.stderr,
    }
  }
  const packages = String(listed.stdout || '')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
  const id = `${String(ctx.now()).replace(/[^0-9a-zA-Z]+/g, '')}-${op}`
  const file = path.join(ctx.restoreDir, `${id}.json`)
  fs.mkdirSync(ctx.restoreDir, { recursive: true })
  fs.writeFileSync(
    file,
    JSON.stringify({ id, for: op, at: ctx.now(), packages }, null, 2) + '\n'
  )
  return { ok: true, backend: 'package-journal', id }
}

// Takes the preflight restore point for an allowed mutation and audits it.
// Returns { ok, backend, ids?|id?, code? } and appends one
// omarchy/snapshot event to the session store either way.
function createPreflight(op, ctx) {
  const probed = ctx.backend
  let record = null
  if (probed.backend === 'snapper') {
    record = createSnapper(op, probed, ctx)
  } else if (probed.backend === 'package-journal') {
    record = createJournal(op, ctx)
  } else {
    record = { ok: false, backend: 'none', code: 'SNAPSHOT_BACKEND_UNAVAILABLE' }
  }
  ctx.store.append({
    type: 'omarchy/snapshot',
    op: 'snapshot.create',
    stage: 'preflight',
    for: op,
    backend: record.backend,
    ...(record.ids ? { ids: record.ids } : {}),
    ...(record.id ? { id: record.id } : {}),
    status: record.ok ? 0 : 1,
    ...(!record.ok && record.code ? { error: record.code } : {}),
  })
  return record
}

module.exports = { probe, createPreflight }
