# State

## TODO

- [ ] ERiC version lookup: replace hardcoded version with a proper lookup (e.g. scrape ELSTER developer portal or maintain a version manifest). Current approach just hardcodes the known latest version.

## Done

- [x] GitHub Actions release workflow: Linux, macOS ARM, and Windows build, test, and package successfully. Triggers on tag push and manual dispatch.
- [x] Cross-platform support: zippy for extraction, platform-aware lib/dll paths, VIKING_ env var prefix.
- [x] Windows CI: DLL search path fix (add DLL dir to PATH), cross-platform env var handling in tests (runWithEnv helper), remove Unix shell redirect.
