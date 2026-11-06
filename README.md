# Renoise Tools

Standalone Lua tools for Renoise 3.5 / scripting API 6.2. Each `.xrnx` directory
contains one independently installable tool.

| Tool | Description |
| --- | --- |
| [ARP](com.david303ttl.ARP.xrnx/README.md) | Pattern arpeggiator with guarded regeneration. |
| [ACID](com.david303ttl.ACID.xrnx/README.md) | PITCH/TIME phrase editor and generator. |
| [Digitakt Sample Chain](com.david303ttl.DigitaktSampleChain.xrnx/README.md) | 48 kHz mono WAV chain exporter. |

Use PowerShell 7 (`pwsh`) for repository scripts. Run `./scripts/run_tests.ps1`
to run the suites and `./scripts/package.ps1` to build installable archives in
`dist/`. See [development setup](docs/DEVELOPMENT.md).

## License

Copyright (C) 2026 David303ttl. Licensed under GNU GPL version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE).
