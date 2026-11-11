# SandboxRuntime

App-owned MCP servers for an agent process that runs under the external boundary (the pinned nono
helper in `Contents/Helpers/Nono`). The boundary covers the whole provider process tree, so a server
the app owns (browser, chat diagnostics, user Chrome) cannot run inside it: it would need the
Keychain, Chrome, process information and the app's data. These servers stay outside.

- `mcp_host.py` - started by Switchboard per sandboxed worker, outside the boundary. Listens on a unix
  socket, reads `servers.json` (`{"servers": {name: {command, args, env}}}`, written by the app) and
  starts the named server with the connection as its stdin/stdout. Exits with its children when the
  app terminates it or the owning app process is gone.
- `mcp_relay.py` - the MCP server command the sandboxed provider launches instead. Connects to the
  socket, names the server and copies bytes both ways. Exits on EOF or when its parent is gone.
- `test_mcp_host.py` - round trip, unknown-server rejection, teardown. Binds a socket, so run it outside
  a command sandbox: `/usr/bin/python3 -I -B SandboxRuntime/test_mcp_host.py`.

The sandboxed process chooses only a server name; the spec file is the trusted side and lives in the
worker folder (`~/Library/Application Support/Switchboard-sandbox/workers/<id>/`), which is not granted
to the agent. Only `tmp/` and the socket of that folder are. Project `.mcp.json` servers are not
relayed: they are the agent's own tools and run inside the boundary.
