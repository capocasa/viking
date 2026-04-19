# State

## Conventions

- **ELSTER / ERiC solutions**: consult only `~/3/ERiC-41.6.2.0` for
  authoritative field, plausi, and schema info. Schemas live in
  `Dokumentation/Schnittstellenbeschreibungen/…/Schema/*.xsd`; plausi
  rules in `Dokumentation/Plausipruefungen/…/Jahresdokumentation_*.xml`
  (search by rule ID, e.g. `100500048`). Don't guess from web or
  memory — the installed ERiC contains everything needed.
- **Live submission guard**: debugging/validation runs MUST pass
  `--test` (ELSTER sandbox). Never invoke a submit-style command
  without `--test` unless the user has explicitly confirmed a live
  submission for that specific call.

## TODO

- [ ] ESt Veranlagungsart wiring. Viking still emits no `<ESt1A>
  <Allg><B>` for the spouse and no `<Vlg_Art>`, so ERiC treats every
  return as Einzelveranlagung regardless of `[spouse]`. As a result
  ERiC fires rule `5075` on Anlage Kind when `kindschaftsverhaeltnis_b`
  is set ("Angaben zum Kindschaftsverhältnis zur Ehefrau nicht
  zulässig bei Einzelveranlagung"). The schema itself is clean and
  rule `100500048` is satisfied. To fully validate a Zusammen-
  veranlagung return we need to: (a) emit the `<B>` block with
  spouse birthdate/name/idnr/religion/profession, (b) emit `<Vlg_Art>`
  with the Zusammenveranlagung code, and (c) add a conf/CLI toggle to
  pick Zusammen vs §26a Einzelveranlagung when a spouse is present.
- [ ] Document the alphanumeric code tables (income, rechtsform, besteuerungsart, religion, kindschaftsverhaeltnis, period) in the README — full word↔number reference with descriptions pulled from `codes.nim`. Error-discovery works at runtime; the reference is for accountants/power users who know the numeric codes. (Partially addressed in `docs.rst`/example — full reference table still pending.)
- [ ] ERiC version lookup: replace hardcoded version with a proper lookup (e.g. scrape ELSTER developer portal or maintain a version manifest). Current approach just hardcodes the known latest version.
- [ ] Daemon / HTTP API mode — sketch in `doc/api-proposal.md`. Session-as-resource model with per-field PATCH, validation as a GET, submit verbs reuse existing `validateForX` + XML generators. Multi-identity from day one (per-session cert+PIN) for the family-taxes-with-AI use case. Daemon-global ERiC init; cert-handle pool keyed by cert path. Self-hosted only for now — hosted multi-tenant needs HerstellerID licensing clearance.

## Done

- [x] ESt Anlage Kind `K_Verh_and_P` (satisfies ERiC rules
  `Regel_Kind_2020_100500048` and `Kind_Kindschaftsverhaeltnis_100500001`).
  Root cause: on Einzelveranlagung with a second parent ERiC requires
  info about the other parent (K_Verh_and_P/Ang_Pers with E0501103
  name, E0501903 Dauer, E0501106 Art). Viking previously emitted
  nothing, tripping plausi 100500048 on every single-filer return with
  kids. Fix: new per-kid conf key `parent_b_name` — when set and
  [spouse] absent, viking emits K_Verh_and_P with the three required
  fields together (full-year Dauer, E0501106 mapped from
  kindschaftsverhaeltnis_b with a "1" fallback when that value is
  "3"/Enkel/Stief which isn't allowed in E0501106's enum). Example
  conf updated (max/lisa → `parent_b_name = Greta Maier`).
  Regression tests added to `test_e2e.nim` (dry-run XML shape:
  emitted/not-emitted per presence of parent_b_name, correct field
  names and values) and `test_example.nim` (live ELSTER sandbox:
  plausi 100500048 and 100500001 no longer fire).
- [x] ESt Anlage Kind Familienkasse (satisfies ERiC rule `5021`).
  New optional per-kid conf key `familienkasse` → emitted as
  `<E0500706>` inside `Ang_Kind/Allg` (right after birthdate).
  Example conf updated (both kids → `familienkasse = Berlin`). E2E
  tests cover emission when set and absence when not set. Against
  the ELSTER sandbox, rule `5021` ("Vorname + Geburtsdatum +
  Familienkasse wurden nicht gemeinsam angegeben") is now gone.
- [x] Fix for ESt Anlage Kind rule `Regel_Kind_2020_100500048`.
  Root cause: viking only emitted `<K_Verh_A>` per kid, so ERiC
  saw no Kindschaftsverhältnis for the "anderer Elternteil" (form
  line 10 right, Kz 03) and flagged each Anlage Kind as incomplete.
  Fix: new per-kid conf key `kindschaftsverhaeltnis_b` — when set,
  viking emits `<K_Verh_B>` with `E0500808` (relationship code) and
  `E0500805` (period). Field is optional; only emitted when present.
  Example conf updated (both kids → `kindschaftsverhaeltnis_b =
  leiblich`). Regression tests added to `test_e2e.nim` (dry-run XML
  shape, emitted/not-emitted per presence of the conf key) and
  `test_example.nim` (assert rule 100500048 no longer triggers in the
  end-to-end validation against the ELSTER sandbox). Caveat: ERiC
  now fires rule `5075` on the example because the Veranlagungsart
  wiring isn't done yet — see TODO.
- [x] Example project + docs + API HTML. `example/` is a runnable showcase of every config feature (multi-source freelance/gewerbe/KAP, spouse, two kids, all word aliases, plain-pin and pincmd-script auth) with auto-discovered TSVs and a deductions file covering vor/sa/agb/per-kid codes. `docs.rst` is a limdb-style progressive guide (single source → multi → words → KAP → family → auth → conf chain → test certs → full example) with a short reference cheat sheet. Module-level `##` doc blocks tightened across `viking.nim`, `vikingconf.nim`, `config.nim`, `codes.nim`, `kap.nim`, `log.nim`. New `nimble docs` task generates `doc/api/*.html` (every module + index) and `doc/docs.html` (user guide) in <5s. New `tests/test_example.nim` runs 51 high-level end-to-end checks against the example project (parsing, multi-source dispatch, aliases, TSV auto-load, period filter, EÜR/USt/ESt aggregation incl. all anlages + kids, Postfach/iban/message dry-runs, real ELSTER schema validation in `--test` mode for UStVA/EÜR/USt; ESt is schema-only since demo IDNRs trip Anlage Kind plausibility). All 51 pass; main 289/289 still green. Caveat documented inline: per-source taxnumber override demo is commented out in the example because it'd fail ELSTER's checksum.
- [x] Config model overhaul: `.env` + dotenv dependency gone. `[auth]` section in viking.conf (all optional) with `cert`, `pin`, `pincmd`; defaults to `<conf-basename>.pfx` + `<conf-basename>.pin` next to the conf. Pin files dispatch by extension (`.pin` plain, `.pin.sh`/`.ps1`/`.cmd`/`.bat`/`.exe` executed for stdout — covers pass/keychain/secret-tool/gpg/age via user-written scripts). `--test` is a pure CLI flag (sandbox endpoint); `--data-dir` replaces `VIKING_DATA_DIR`. All `VIKING_*` env reads and `-e/--env` flags removed. Selective jar extraction (only current platform's tree retained; jar deleted post-extract) reduces data-dir footprint and IT-compliance friction. Test cert bundling dropped — README tells users to `wget Test_Zertifikate.zip` themselves. ERiC logs moved from `$TMPDIR/eric_logs` to `<data-dir>/logs/`. Full regression: 289/289 e2e tests pass.
- [x] Alphanumeric aliases for numeric codes in viking.conf via `src/viking/codes.nim`. `income` (gewerbe/freiberuf/kap), `rechtsform` (einzel/gmbh/ug/gbr/ohg/kg/ag/...), `besteuerungsart` (ist/soll/teilist), `religion` (keine/rk/ev/altkath/...), `kindschaftsverhaeltnis` (leiblich/pflege/enkel), and `--period` (jan..dez, q1..q4). Numerics still accepted, leading zeros optional, unpadded numbers like `3`→`03`. Invoice TSV rate column now tolerates trailing `%` (`19%`, `7%`). Unknown values raise `ValueError` listing the valid words; missing required `rechtsform`/`besteuerungsart` validation errors include the listing. `viking.conf.example` and init template updated to use words.
- [x] Multi-source viking.conf: `[personal]`/`[spouse]` reserved, freeform sections inferred (`income` → source, `kindschaftsverhaeltnis` → kid). KAP values inline on `income = kap` sections; `kap.tsv` retired. Source positional arg on submit/ust/euer; auto-loads `<year>-<source>.tsv`. ESt scans all sources (both Anlage G and S emitted as needed). Conf search chain: `--conf` → `./viking.conf` → `~/.config/viking/viking.conf` (merged field-by-field).
- [x] GitHub Actions release workflow: Linux, macOS ARM, and Windows build, test, and package successfully. Triggers on tag push and manual dispatch.
- [x] Cross-platform support: zippy for extraction, platform-aware lib/dll paths, VIKING_ env var prefix.
- [x] Windows CI: DLL search path fix (add DLL dir to PATH), cross-platform env var handling in tests (runWithEnv helper), remove Unix shell redirect.
