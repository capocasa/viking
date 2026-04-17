# State

## TODO

- [ ] ERiC version lookup: replace hardcoded version with a proper lookup (e.g. scrape ELSTER developer portal or maintain a version manifest). Current approach just hardcodes the known latest version.

## Done

- [x] Multi-source viking.conf: `[personal]`/`[spouse]` reserved, freeform sections inferred (`income` → source, `kindschaftsverhaeltnis` → kid). KAP values inline on `income = kap` sections; `kap.tsv` retired. Source positional arg on submit/ust/euer; auto-loads `<year>-<source>.tsv`. ESt scans all sources (both Anlage G and S emitted as needed). Conf search chain: `--conf` → `./viking.conf` → `~/.config/viking/viking.conf` (merged field-by-field).
- [x] GitHub Actions release workflow: Linux, macOS ARM, and Windows build, test, and package successfully. Triggers on tag push and manual dispatch.
- [x] Cross-platform support: zippy for extraction, platform-aware lib/dll paths, VIKING_ env var prefix.
- [x] Windows CI: DLL search path fix (add DLL dir to PATH), cross-platform env var handling in tests (runWithEnv helper), remove Unix shell redirect.
