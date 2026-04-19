# Viking

CLI tool for German tax submissions and document retrieval via the ELSTER ERiC library.

Supports UStVA, EÜR, ESt, USt annual returns, and downloading Steuerbescheide (tax assessments) from the ELSTER Postfach.

This is experimental — tax submissions are irreversible, so verify independently.

## Setup

```sh
nimble build
./viking fetch   # downloads and extracts the ERiC library
```

Then drop your ELSTER signing certificate (`.pfx`) next to your `viking.conf`, and put the PIN in a matching `.pin` file:

```
viking.conf
viking.pfx
viking.pin        # contains the PIN (plain text)
```

Naming is by convention: `viking.conf` → `viking.pfx` + `viking.pin`. Different conf basename? Same rule: `uncle.conf` → `uncle.pfx` + `uncle.pin`. Override in viking.conf:

```ini
[auth]
cert = /elsewhere/softorg.pfx
pin = /elsewhere/softorg.pin
# or:
# pincmd = /elsewhere/softorg.pin.sh
```

## Usage

```sh
# Submit VAT return (Q1 2026, 1000 EUR at 19%)
viking submit --period 41 --amount19 1000

# Both rates
viking submit --period 01 --amount19 5000 --amount7 2000

# EÜR (profit/loss statement) for a named source
# loads 2025-freelance.tsv alongside viking.conf
viking euer freelance --year 2025

# ESt (income tax return) — aggregates all sources
viking est --year 2025

# USt (annual VAT return) for a named source
viking ust freelance --year 2025

# Retrieve documents from Finanzamt (Steuerbescheide etc.)
viking list                              # show available documents
viking download                          # download all
viking download Steuerbescheid_2024.pdf  # download specific file(s)
viking download -o ./bescheide           # save to specific directory

# Validate without sending
viking submit --period 41 --amount19 1000 --validate-only

# Dry run (show generated XML)
viking submit --period 41 --amount19 1000 --dry-run

# Sandbox submission (uses ELSTER test endpoint; XML gets a Testmerker)
viking submit --test --period 41 --amount19 1000

# Use a different conf
viking submit --conf ./client-foo/viking.conf --period 41 --amount19 1000
```

The `download` command queries the ELSTER Postfach, downloads documents from the OTTER server via `libotto`, and sends the mandatory confirmation (PostfachBestaetigung). Existing files are skipped unless `--force` is given.

## Configuration

`viking.conf` holds personal, source, and (optional) auth information. See `viking init` for a template. The file is loaded from:

1. `~/.config/viking/viking.conf` (global defaults)
2. `./viking.conf` (per-directory overrides)
3. `--conf <path>` (explicit — replaces the chain)

`[auth]` section is optional; the default is `<conf-basename>.pfx` + `<conf-basename>.pin` next to the conf.

### Pin file formats

Picked by file extension. Exactly one of these must exist for the default to resolve:

| File | How viking reads it |
|------|---------------------|
| `viking.pin` | plain text — pin is the file contents |
| `viking.pin.sh` | run via `sh`, stdout is the pin |
| `viking.pin.ps1` | run via `powershell`, stdout is the pin |
| `viking.pin.cmd` / `.bat` | run via `cmd /c`, stdout is the pin |
| `viking.pin.exe` | run directly, stdout is the pin |

For secret-manager integration, make a script that prints the pin:

```sh
#!/bin/sh
exec pass show elster/main
```

Save as `viking.pin.sh`. Works with pass, 1Password CLI, macOS Keychain (`security find-generic-password ...`), libsecret (`secret-tool lookup ...`), gpg, age, or anything else that prints to stdout.

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
