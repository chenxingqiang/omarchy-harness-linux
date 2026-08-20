const fs = require('fs')
const net = require('net')
const path = require('path')
const { createHarness, runCli } = require('./lib/omarchy-harness')
const { parseAcpLine } = require('./lib/acp')

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

function serve(harness) {
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
    let buffer = ''
    connection.on('data', (chunk) => {
      buffer += String(chunk)
      const lines = buffer.split('\n')
      buffer = lines.pop()
      for (const line of lines) {
        const trimmed = line.trim()
        if (!trimmed) {
          continue
        }
        if (trimmed === 'ping') {
          connection.write('ok\n')
          continue
        }
        try {
          const parsed = parseAcpLine(trimmed)
          const reply = harness.acp.handle(parsed.message)
          connection.write(JSON.stringify(reply) + '\n')
        } catch {
          connection.write(
            JSON.stringify({
              jsonrpc: '2.0',
              id: null,
              error: { code: -32700, message: 'parse error' },
            }) + '\n'
          )
        }
      }
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
  serve(harness)
} else {
  if (result.stdout) {
    process.stdout.write(result.stdout)
  }
  if (result.stderr) {
    process.stderr.write(result.stderr)
  }
  process.exit(result.status)
}
