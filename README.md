<div align="center">

# Venice Video Creator

**A Mac-native, AI-powered video editor that runs on a single Venice API key.**

<sub><i>Requires macOS 26 (Tahoe) on Apple Silicon</i></sub>

</div>

---

Venice Video Creator is an open-source video editor for Mac. You and your agent generate and edit video together, right inside the timeline — powered entirely by your own [Venice](https://venice.ai) API key. No account, no subscription, no data sent to us: bring your key and everything runs against Venice directly.

## Download

**Don't use GitHub? No problem — it's a normal Mac app.**

1. Go to the **[latest release page](https://github.com/jordanurbs/venice-video-creator/releases/latest)**.
2. Under **Assets**, download **`VeniceVideoCreator.dmg`**.
3. Open the downloaded `.dmg`, then drag **Venice Video Creator** onto the **Applications** folder.
4. Launch it from Applications.

> First launch: because the app is distributed outside the Mac App Store, macOS may ask you to confirm. If you see *"cannot be opened"*, right-click the app → **Open** → **Open**, or allow it under **System Settings → Privacy & Security**.

To start creating, open **Settings → Venice** and paste your Venice API key (get one at [venice.ai](https://venice.ai)).

## What it does

- **Swift-native timeline editor.** Built from scratch for macOS — cut, trim, layout, caption, and export on a real timeline.
- **Generative AI on your Venice key.** Generate video, images, music, and SFX with the models in your Venice catalog, directly on the timeline.
- **Works with your agents.** Drive the editor from the built-in AI agent, or connect Claude / Codex / Cursor over MCP to edit the same project.

## MCP server

When the app is open it exposes an MCP server at `http://127.0.0.1:19789/mcp` over HTTP.

**Claude Code**
```bash
claude mcp add --transport http venice-video-creator http://127.0.0.1:19789/mcp
```

**Codex**
```bash
codex mcp add venice-video-creator --url http://127.0.0.1:19789/mcp
```

**Cursor**

In the app, go to `Help → MCP Instructions → Install in Cursor`, or add this to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "venice-video-creator": {
      "type": "http",
      "url": "http://127.0.0.1:19789/mcp"
    }
  }
}
```

**Claude Desktop**

The app bundles an [mcpb](https://github.com/modelcontextprotocol/mcpb) Desktop Extension for one-click install. Go to `Help → MCP Instructions → Install in Claude Desktop`.

## FAQ

**Is it free?**

The app is free and open source. Generative AI features run against your own Venice API key — you pay Venice directly for what you generate; there's no separate subscription or login here.

**What platforms does it support?**

macOS 26 (Tahoe) on Apple Silicon only.

See [FAQ.md](FAQ.md) for more.

## Development

```bash
swift build
swift run
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## Credits

Venice Video Creator is derived from **[Palmier Pro](https://github.com/palmier-io/palmier-pro)** by Palmier, Inc., used under the GPLv3. Huge thanks to the Palmier team for the editor foundation. Upstream engine improvements are periodically merged in.

## License

Venice Video Creator is open source under [GPLv3](LICENSE).

Copyright (C) 2026 Palmier, Inc. and Venice Video Creator contributors.
