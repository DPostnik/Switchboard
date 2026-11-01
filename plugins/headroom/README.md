# Headroom provider plugin for Switchboard

This directory is a standalone, separately installable plugin. It has no Swift package dependency on Switchboard and is not included in the app bundle. It implements Switchboard provider protocol v1 using Headroom 0.38.0, pinned with dependency hashes. Plugin version: 1.0.1.

## Install

Requirements: macOS, `uv`, and Python 3.12 (installed by uv when needed).

```sh
zsh install.sh
```

From the app repository the equivalent command is `zsh plugins/headroom/install.sh`; `scripts/install-headroom.sh` remains a compatibility wrapper. Installation publishes to `~/Library/Application Support/Switchboard/plugins/headroom`. `SWITCHBOARD_PLUGINS_DIR` overrides the parent directory for isolated installation tests.

In Switchboard, open Settings → Дополнительно / Advanced → Плагины / Plugins, refresh the plugin list, select Headroom for new conversations, and click **Применить выбор / Apply selection**. Existing conversations with route `headroom` keep that route. Direct conversations stay Direct.

For an upgrade from the former built-in adapter, run this installer once. The old `Context Desk/headroom` directory is left untouched, and no credentials or state are migrated from it. The new plugin keeps its own private runtime data under `plugins/headroom/data`.

## Update or remove

Quit Switchboard with Cmd+Q before updating or removing a running plugin. Re-run the installer to update. To uninstall, move its installed `plugins/headroom` folder out of the plugin directory, then reopen Switchboard or refresh and reconnect. Conversations and their route identifiers remain; affected chats show that the plugin is missing and never silently use Direct.

The installer refuses an update while readiness files indicate a running instance. After a crash, verify that the plugin is stopped before removing a stale `data/ready-*.json` file.

## Behavior

The plugin runs a loopback-only Responses proxy. It forwards the authentication headers supplied by Codex and does not read or copy credentials. It disables automatic request retries, telemetry, full-message logs, response caching and lossy compression. The parent process owns its lifetime; it exits when the parent disappears.

Status metrics cover this plugin process across conversations; token reductions are not a billing or subscription-savings guarantee. Headroom-specific setup, version validation, metrics and compression configuration live entirely in this folder.

## Independent distribution

`zsh package.sh` produces `dist/Headroom-1.0.1.contextdesk-plugin.zip`, containing only this plugin's installer, manifest, runner, pinned requirements and instructions. The recipient extracts the archive and runs `zsh headroom/install.sh`; no Switchboard source checkout or Swift compilation is needed to install the plugin. The archive installs dependencies on the recipient's Mac instead of shipping a non-relocatable Python virtual environment.
