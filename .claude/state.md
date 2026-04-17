# State

## TODO

- [ ] ERiC version lookup: replace hardcoded version with a proper lookup (e.g. scrape ELSTER developer portal or maintain a version manifest). Current approach just hardcodes the known latest version.
- [ ] Windows CI tests: ERiC DLLs download and extract correctly but fail to load at runtime on GitHub Actions Windows runner. Build and packaging work. Needs investigation into DLL loading (PATH, dependencies, etc.)
- [ ] macOS Intel build: temporarily disabled (`macos-13` runner commented out in release.yml). Re-enable once other platforms stable. Runner queues are slow due to Intel Mac phase-out.

## Done

- [x] GitHub Actions release workflow: Linux and macOS ARM build, test, and package successfully. Triggers on tag push and manual dispatch.
- [x] Cross-platform support: zippy for extraction, platform-aware lib/dll paths, VIKING_ env var prefix.
