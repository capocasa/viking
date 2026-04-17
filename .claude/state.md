# State

## TODO

- [ ] Document the alphanumeric code tables (income, rechtsform, besteuerungsart, religion, kindschaftsverhaeltnis, period) in the README — full word↔number reference with descriptions pulled from `codes.nim`. Error-discovery works at runtime; the reference is for accountants/power users who know the numeric codes.
- [ ] ERiC version lookup: replace hardcoded version with a proper lookup (e.g. scrape ELSTER developer portal or maintain a version manifest). Current approach just hardcodes the known latest version.

## Done

- [x] Alphanumeric aliases for numeric codes in viking.conf via `src/viking/codes.nim`. `income` (gewerbe/freiberuf/kap), `rechtsform` (einzel/gmbh/ug/gbr/ohg/kg/ag/...), `besteuerungsart` (ist/soll/teilist), `religion` (keine/rk/ev/altkath/...), `kindschaftsverhaeltnis` (leiblich/pflege/enkel), and `--period` (jan..dez, q1..q4). Numerics still accepted, leading zeros optional, unpadded numbers like `3`→`03`. Invoice TSV rate column now tolerates trailing `%` (`19%`, `7%`). Unknown values raise `ValueError` listing the valid words; missing required `rechtsform`/`besteuerungsart` validation errors include the listing. `viking.conf.example` and init template updated to use words.
- [x] Multi-source viking.conf: `[personal]`/`[spouse]` reserved, freeform sections inferred (`income` → source, `kindschaftsverhaeltnis` → kid). KAP values inline on `income = kap` sections; `kap.tsv` retired. Source positional arg on submit/ust/euer; auto-loads `<year>-<source>.tsv`. ESt scans all sources (both Anlage G and S emitted as needed). Conf search chain: `--conf` → `./viking.conf` → `~/.config/viking/viking.conf` (merged field-by-field).
- [x] GitHub Actions release workflow: Linux, macOS ARM, and Windows build, test, and package successfully. Triggers on tag push and manual dispatch.
- [x] Cross-platform support: zippy for extraction, platform-aware lib/dll paths, VIKING_ env var prefix.
- [x] Windows CI: DLL search path fix (add DLL dir to PATH), cross-platform env var handling in tests (runWithEnv helper), remove Unix shell redirect.
