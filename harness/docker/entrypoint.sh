#!/bin/bash
# agentENV service entrypoint: materialize the dsh profile under $DSH_HOME,
# then hand the process over to `dsh web` (loopback bind, no browser open).
# Runs as PID 1's child under tini (see Containerfile).
set -euo pipefail

dsh_home=${DSH_HOME:-/root/.dsh}
profile_dir="$dsh_home/profiles/agentenv"
mkdir -p "$profile_dir"

node -e "
const fs = require('fs')
const path = require('path')
const profileDir = process.argv[1]
const manifest = {
  name: 'agentenv-profile',
  private: true,
  dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] } },
  dependencies: { '@deepseek-ai/dsh-web-app': '0.1.1-rc.2' },
}
fs.writeFileSync(path.join(profileDir, 'package.json'), JSON.stringify(manifest, null, 2) + '\n')
const patchPath = path.join(profileDir, 'cordis.patch.yml')
if (!fs.existsSync(patchPath)) {
  fs.writeFileSync(patchPath, '# agentENV profile: no user overrides.\n[]\n')
}
" "$profile_dir"

cd "$profile_dir"
pnpm install --frozen-lockfile=false --silent

exec /opt/harness/node_modules/.bin/dsh --profile agentenv "$@"
