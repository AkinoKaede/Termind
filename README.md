<p align="center">
  <a href="https://termind.akinokaede.com">
    <img src="https://raw.githubusercontent.com/AkinoKaede/com.akinokaede.termind/7d1f97782333bd1e6c6fb0c1a3bd391af5ef4905/public/brand_mark.svg" alt="Termind logo" width="128" height="128" style="background-color: transparent;">
  </a>
</p>

<h1 align="center">Termind</h1>

<p align="center">
  AI-driven remote workspace for Mac, iPhone, and iPad
</p>

<p align="center">
  <a href="https://termind.akinokaede.com">Website</a>
  &middot;
  <a href="https://apps.apple.com/app/apple-store/id6805856690">App Store</a>
  &middot;
  <a href="https://discord.gg/3dzmRAUA36">Discord</a>
  &middot;
  <a href="https://t.me/termind_updates">Telegram</a>
</p>

## Preview

<p align="center">
  <img src="https://raw.githubusercontent.com/AkinoKaede/com.akinokaede.termind/7d1f97782333bd1e6c6fb0c1a3bd391af5ef4905/assets/captures/en/mac-14/workspace_window.png" alt="Termind macOS window with two SSH terminals and an SFTP browser" width="960">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/AkinoKaede/com.akinokaede.termind/7d1f97782333bd1e6c6fb0c1a3bd391af5ef4905/assets/captures/en/ipad-15/assistant.png" alt="Termind AI Assistant on iPad investigating a server issue" width="960">
</p>

## Features

Termind brings terminals, remote files, server metrics, and a controllable AI
assistant together in one app.

- **Remote connections.** Connect with SSH, Mosh, Eternal Terminal, and Telnet,
  plus serial connections on Mac.
- **Workspaces and persistent sessions.** Organize terminals and SFTP sessions in
  multi-pane workspaces on Mac. Integrate with Herdr, tmux, Zellij, or zmx to
  return to remote sessions after disconnecting.
- **Visual SFTP.** Browse, preview, and manage remote files across multiple
  connections, or upload files by dragging them into the terminal.
- **Host management.** Organize saved hosts, identities, known hosts, and
  connection settings in one place.
- **AI, commands, and snippets.** Use your own provider and API key with an
  Assistant whose actions you control. Generate commands without automatically
  running them, and save reusable snippets.
- **MCP integrations.** Connect external MCP tools to the Assistant. The built-in
  local MCP service on Mac also exposes SSH and SFTP tools to other AI clients,
  with per-tool controls and an audit trail.
- **Agentless Linux monitoring.** Monitor servers over SSH without installing a
  monitoring agent. Track CPU, memory, disk, network, GPU, filesystem, and process
  metrics.
- **Network tools.** Set up SSH port forwarding, with multi-connection support on
  Mac. Connect through built-in Tailscale and wake devices on your local network
  with Wake-on-LAN.
- **Storage and sync.** Store app data locally with optional iCloud sync across
  devices, and protect credentials with Apple Keychain.

The apps support **macOS 15+, iOS 18+, and iPadOS 18+**.

## Development

### Build from source

```sh
git clone https://github.com/AkinoKaede/Termind.git
cd Termind
open Termind.xcodeproj
```

### Local configuration

Firebase and RevenueCat setup is optional; see [local service configuration](Configuration/README.md).

### Website and assets

The [website and assets](https://github.com/AkinoKaede/com.akinokaede.termind) live
in an optional submodule. Follow its README for setup and development; native app
builds do not require it.

## Dependencies and Credits

### Dependencies

- [AgentKit](https://github.com/AkinoKaede/AgentKit)
- [libssh2-spm](https://github.com/AkinoKaede/libssh2-spm)
- [libtailscale-spm](https://github.com/AkinoKaede/libtailscale-spm)

### Credits

Thanks to these open-source projects and their contributors:

- [libghostty-spm](https://github.com/Lakr233/libghostty-spm)
- [swift-mosh](https://github.com/wiedymi/swift-mosh)
- [swift-et](https://github.com/wiedymi/swift-et)
- [openssl-spm](https://github.com/Lakr233/openssl-spm)
- [MarkdownView](https://github.com/Lakr233/MarkdownView)
- [ListViewKit](https://github.com/Lakr233/ListViewKit)
- [GlyphixTextFx](https://github.com/Lakr233/GlyphixTextFx)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [DeviceKit](https://github.com/devicekit/DeviceKit)
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)

# License

This repository is licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only).
