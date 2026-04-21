# Viking

CLI tool for German tax submissions and document retrieval via the ELSTER ERiC library.

Supports UStVA, EÜR, ESt, USt annual returns, and downloading Steuerbescheide (tax assessments) from the ELSTER Postfach.

This is experimental — tax submissions are irreversible, so verify independently.

## Setup

```sh
nimble build
./viking fetch   # downloads and extracts the ERiC library
```

Wire your ELSTER signing certificate (`.pfx`) and PIN explicitly via `[auth]`:

```ini
[auth]
cert = viking.pfx              ; path to the .pfx (relative to this conf's dir)
pin  = viking.pin              ; plaintext PIN file (or the PIN itself, inline)
; pincmd = pass show elster/pin ; or: any shell command that prints the PIN on stdout
```

Exactly one of `pin=` or `pincmd=` is required. `pin=` takes either a path to a file containing the PIN or the PIN text itself (inline is fine for the public sandbox PIN, not recommended for checked-in real confs). `pincmd=` is any shell command — runs with the conf's directory as cwd.

## Usage

```sh
# UStVA (quarterly VAT advance) — amounts come from the source's euer= TSV
viking ustva -s freiberuf --period 41

# EÜR (profit/loss statement) for a named source
viking euer -s freiberuf

# ESt (income tax return) — aggregates every source
viking est

# USt (annual VAT return) for a named source
viking ust -s freiberuf

# Retrieve documents from Finanzamt (Steuerbescheide etc.)
viking list                              # show available documents
viking download                          # download all
viking download Steuerbescheid_2024.pdf  # download specific file(s)
viking download -o ./bescheide           # save to specific directory

# Dry run: validate via ERiC and print XML, don't send
viking ustva -s freiberuf --period 41 --dry-run

# Sandbox submission (uses ELSTER test endpoint; XML gets a Testmerker)
viking ustva --test -s freiberuf --period 41

# Use a different conf
viking ustva --conf ./client-foo/viking.conf -s freiberuf --period 41
```

The tax year comes from `personal.year` in `viking.conf`, not the CLI — copy the conf dir per year.

The `download` command queries the ELSTER Postfach, downloads documents from the OTTER server via `libotto`, and sends the mandatory confirmation (PostfachBestaetigung). Existing files are skipped unless `--force` is given.

## Configuration

`viking.conf` is an INI file. The first section is the taxpayer — its name is your full name ("Vornamen Nachname"). Everything else classifies itself:

```ini
[Hans Maier]
year       = 2025             ; required — copy this dir per tax year
steuernr   = 1234567890123
idnr       = 04452397687
strasse    = Musterstr.
nr         = 1
plz        = 10115
ort        = Berlin
iban       = DE89370400440532013000
abzuege    = abzuege.tsv      ; optional: ESt Abzüge TSV

[Greta Maier]            ; later person-named section + idnr → spouse
idnr         = 04452397688
geburtsdatum = 12.07.1956

[freiberuf]              ; reserved → Anlage S
versteuerung = ist
euer   = freelance.tsv

[Musterfirma GmbH]       ; suffix → Anlage G, rechtsform=gmbh (EÜR only for now)
versteuerung = soll
euer   = musterfirma.tsv

[ibkr]                   ; marker → Anlage KAP
guenstigerpruefung = 1
pauschbetrag       = 1000

[Lena Maier]             ; marker → kid
verhaeltnis   = leiblich
geburtsdatum  = 15.03.2019
idnr          = 02293417683

[auth]                   ; signing material (required for live submit)
cert = viking.pfx
pin  = viking.pin        ; or inline, or `pincmd = pass show elster/pin`
```

Rules: `[auth]`, `[freiberuf]` and `[gewerbe]` are the only reserved section names; `verhaeltnis` flags a kid, `guenstigerpruefung`/`pauschbetrag` Anlage KAP. The first person-named section is you (required: `year = YYYY`); any later person-named section with an `idnr` is your co-filing spouse (Zusammenveranlagung). A trailing legal-form in the section name (GmbH, UG, KG, OHG, GbR, PartG, eK, eG, KGaA, SE, "GmbH & Co. KG", …) picks the Rechtsform; otherwise it's an Einzelgewerbe. Company sections are accepted today but only EÜR is wired — full double-entry bookkeeping (Bilanz / E-Bilanz) is future work. External files are wired explicitly: EÜR sources declare their income/cost TSV via `euer=` (optional — zeros + warning if unset); the taxpayer declares the ESt `abzuege=` TSV; `[auth]` points at the `.pfx` (`cert=`) and either a PIN source (`pin=` file or inline) or a shell command (`pincmd=`). No filesystem scanning, no year interpolation, nothing implicit — copy the conf dir per year for clean data. See `viking init` for a full template and `docs.rst` for the slow tour.

The conf is loaded from:

1. `~/.config/viking/viking.conf` (global defaults)
2. `./viking.conf` (per-directory overrides)
3. `--conf <path>` (explicit — replaces the chain)

The `[auth]` section is required for live submissions — point `cert=` at the `.pfx` and set exactly one of `pin=` or `pincmd=`.

### pin / pincmd

* `pin=` — if the value resolves to an existing file, viking reads it (plaintext PIN file). Otherwise it treats the value as the PIN itself (inline). Inline is fine for the public sandbox PIN (`123456`) but don't check it in for real confs.
* `pincmd=` — any shell command, runs with the conf's directory as cwd. Stdout is the PIN.

```ini
[auth]
cert = viking.pfx
; pin    = viking.pin                ; path to plaintext PIN file
; pin    = 123456                    ; or inline (sandbox only)
; pincmd = ./viking.pin.sh           ; or a local script
; pincmd = pass show elster/pin      ; or a secret manager
; pincmd = security find-generic-password -s elster -w      ; macOS Keychain
; pincmd = secret-tool lookup app elster                    ; libsecret
```

Any shell snippet that prints the PIN on stdout works — `pass`, 1Password CLI, macOS Keychain, libsecret, gpg, age, `cat`, whatever.

### Viking data directory

`viking fetch` installs ERiC under `~/.local/share/viking/` (Linux), `~/Library/Application Support/viking/` (macOS), or `%APPDATA%\viking\` (Windows). Override with `--data-dir <path>` on any subcommand.

Layout:

```
<data-dir>/
  eric/...        # extracted ERiC runtime (only the current platform's files)
  logs/           # ERiC log output
```

## Testing against ELSTER sandbox

Grab the public test certificates from ELSTER:

```sh
wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
unzip Test_Zertifikate.zip
```

Pick one of the `.pfx` files (softpers for personal, softorg for business), point your viking.conf's `[auth]` at it, write `123456` into the matching `.pin` file, and run with `--test`:

```sh
viking submit --test --period 41 --amount19 0 --conf ./test-viking.conf
```

## Testing

```sh
nim c -r tests/test_e2e.nim
```

Requires ERiC installed (`viking fetch`) and the test certificates placed under `<data-dir>/certificates/`.

## License

MIT
