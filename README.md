# Viking

CLI tool for German tax submissions and document retrieval via the ELSTER ERiC library.

Supports UStVA, EUeR, ESt, USt annual returns, and downloading Steuerbescheide (tax assessments) from the ELSTER Postfach.

This is experimental — tax submissions are irreversible, so verify independently.

## Setup

```sh
nimble build
./viking fetch          # downloads ERiC library + test certificates
```

Edit `.env` with your configuration (see below).

## Usage

```sh
# Submit VAT return (Q1 2026, 1000 EUR at 19%)
viking submit --period 41 --amount19 1000

# Both rates
viking submit --period 01 --amount19 5000 --amount7 2000

# EUeR (profit/loss statement) for a named source
# loads 2025-freelance.tsv alongside viking.conf
viking euer freelance --year 2025

# ESt (income tax return) - aggregates all sources
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

# Use a different config profile
viking submit --env .env.production --period 41 --amount19 1000
```

The `download` command queries the ELSTER Postfach, downloads documents from the OTTER server via `libotto`, and sends the mandatory confirmation (PostfachBestaetigung). Existing files are skipped unless `--force` is given.

## Configuration

All configuration is via `.env` files. Copy and edit for different profiles:

```sh
# Test mode (1=sandbox, 0=production)
TEST=1

# ERiC library paths (set automatically by `viking fetch`)
ERIC_LIB_PATH=...
ERIC_PLUGIN_PATH=...

# Certificate
CERT_PATH=path/to/certificate.pfx
CERT_PIN=123456
# Or use a command to fetch the PIN:
# CERT_PIN_CMD=pass show elster/pin

# Hersteller-ID (register at https://www.elster.de/elsterweb/entwickler)
HERSTELLER_ID=40036
PRODUKT_NAME=Viking

# Sender information
DATENLIEFERANT_NAME=Your Name
DATENLIEFERANT_STRASSE=Street 1
DATENLIEFERANT_PLZ=10115
DATENLIEFERANT_ORT=Berlin

# Tax number
STEUERNUMMER=9198011310010
```

## Testing

```sh
nim c -r tests/test_e2e.nim
```

Requires ERiC + test certificates (`viking fetch`).

## License

MIT
