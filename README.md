# Renoise Tools

Standalone Lua/XRNX tools for Renoise. Each root `.xrnx` directory is a complete,
independently versioned tool; runtime modules stay inside its bundle.

| Tool | Version / status | Documentation |
| --- | --- | --- |
| ARP | 0.7 experimental: pattern generation, delayed gates, guarded regeneration | [ARP](com.david303ttl.ARP.xrnx/README.md) |
| ACID | 0.1 experimental: M3 implementation complete for the verified gate/glide/accent profile; live transport acceptance pending | [ACID](com.david303ttl.ACID.xrnx/README.md) |
| DigitaktSampleChain | Existing tool, frozen during this reorganization | [DigitaktSampleChain](com.david303ttl.DigitaktSampleChain.xrnx/README.md) |

ARP and ACID target Renoise 3.5 (Lua API 6.2). Pure-Lua checks do not establish
correct Renoise playback, undo, or save/reload behavior; see [tests](tests/README.md)
for automated checks and manual smoke tests.

Use PowerShell 7 (`pwsh`) for repository scripts. Run all specs with `./scripts/run_tests.ps1`. Build installable archives with
`./scripts/package.ps1`; release files are written to ignored `dist/`.
Both scripts also support selecting a tool; see their `Get-Help` output.

For API documentation and editor completion, run `./scripts/setup_sdk.ps1` to
install the pinned Renoise API 6.2 starter pack. See [development setup](docs/DEVELOPMENT.md).

Use independent release tags such as `arp/v0.7` and `acid/v0.1`, matching the
released tool's `manifest.xml`. Modules are private to each bundle; shared code
should only be introduced when a deliberate build step can keep installed tools
self-contained.

New commits follow [Conventional Commits](docs/COMMIT_MESSAGES.md).

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
