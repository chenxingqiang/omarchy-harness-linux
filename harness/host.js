const fs = require('fs')
const net = require('net')
const path = require('path')
const { createHarness, runCli } = require('./lib/omarchy-harness')

function defaultLogPath() {
  const home = process.env.HOME || '/tmp'
  return path.join(home, '.local/state/omarchy/harness/sessions/current.jsonl')
}

function socketPath() {
  const runtimeDir = process.env.XDG_RUNTIME_DIR
  if (!runtimeDir) {
    return null
  }
  return path.join(runtimeDir, 'omarchy-harness.sock')
}

function serve() {
  const sock = socketPath()
  if (!sock) {
    console.error('omarchy-harness-host: XDG_RUNTIME_DIR is unset')
    process.exit(1)
  }

  try {
    fs.unlinkSync(sock)
  } catch {
    // absent is fine
  }

  const server = net.createServer((connection) => {
    connection.on('data', (chunk) => {
      const line = String(chunk).trim()
      if (line === 'ping') {
        connection.end('ok\n')
        return
      }
      connection.end('unknown\n')
    })
  })

  server.listen(sock, () => {
    fs.chmodSync(sock, 0o600)
  })

  const shutdown = () => {
    server.close()
    try {
      fs.unlinkSync(sock)
    } catch {
      // already gone
    }
    process.exit(0)
  }

  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

const argv = process.argv.slice(2)
const harness = createHarness({ logPath: defaultLogPath() })
const result = runCli(argv, { harness })

if (result.serve) {
  serve()
} else {
  if (result.stdout) {
    process.stdout.write(result.stdout)
  }
  if (result.stderr) {
    process.stderr.write(result.stderr)
  }
  process.exit(result.status)
}
