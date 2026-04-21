# Viking example

A complete viking project that exercises every config feature: multi-source
income, alphanumeric aliases, spouse, kids, KAP, abzuege, and the `[auth]`
wiring. Wired up against the public ELSTER sandbox so you can dry-run or
even submit (with `--test`) end-to-end.

One directory per tax year — copy this whole directory to `2025/`, `2026/`,
etc. and edit the TSVs in place. Viking does no year substitution in
paths; the year flag (`--year`) only picks the ERiC schema.

## Files

| File                  | What it shows                                              |
|-----------------------|------------------------------------------------------------|
| `viking.conf`         | All section types in one place, all aliases used           |
| `viking.pin`          | Plain-text PIN (`123456`, the public test PIN)             |
| `viking.pin.sh`       | Alternative: a script that prints the PIN to stdout        |
| `freelance.tsv`       | TSV wired up via `[freiberuf].euer=`                       |
| `gewerbe.tsv`         | TSV wired up via `[gewerbe].euer=`                         |
| `abzuege.tsv`         | All abzuege code groups (vor / sa / agb / per-kid)         |

## Setup

Grab the public ELSTER test certificate (do this once):

```sh
wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
unzip Test_Zertifikate.zip
```

Drop or symlink one of the `.pfx` files into this directory as `viking.pfx`
(the path `[auth].cert` in `viking.conf` points at):

```sh
ln -s "$PWD/test-softorg-pse.pfx" viking.pfx
```

The PIN for all test certs is `123456`, already in `viking.pin` (which is
what `[auth].pin` points at).

## Try it

All commands are safe — `--test` hits the ELSTER sandbox and adds a
`<Testmerker>`, `--dry-run` doesn't talk to ELSTER at all.

```sh
cd example

# UStVA (quarterly VAT advance) — amounts come from freelance.tsv
viking ustva -s freiberuf --test --period q1 --dry-run

# Period aliases — all of these are equivalent:
viking ustva -s freiberuf --test --period q1  --dry-run
viking ustva -s freiberuf --test --period 41  --dry-run
viking ustva -s freiberuf --test --period mar --dry-run     # -> 03
viking ustva -s freiberuf --test --period 3   --dry-run     # -> 03

# Each source declares its own TSV via `euer=` in the conf
viking euer -s freiberuf    --test --dry-run
viking euer -s gewerbe      --test --dry-run
viking ust  -s gewerbe      --test --dry-run         # vorauszahlungen=100

# ESt aggregates every source: Anlage S (freiberuf) + Anlage G (gewerbe)
# + Anlage KAP (ibkr inline values) + Anlage Kind for max & lisa.
# personal.abzuege = abzuege.tsv is picked up automatically.
viking est --test --dry-run
```

To actually submit to the sandbox (drop `--dry-run`):

```sh
viking ustva -s freiberuf --test --period q1
```

You'll get a real round-trip to ELSTER's test endpoint. Drop `--test` once
your real cert is in place and you mean it.

## Picking the PIN format

By default, `[auth]` points `pin = viking.pin` at the bundled plaintext
file. Three other variants are commented in the same block:

```ini
[auth]
cert   = viking.pfx
; pin    = viking.pin           ; default: plaintext PIN file
; pin    = 123456               ; inline PIN (ok for the public sandbox)
; pincmd = ./viking.pin.sh      ; run the bundled script
; pincmd = pass show elster/pin ; or wrap any secret manager
```

`pincmd` is a shell command; it runs with this directory as cwd, so any
one-liner works — `pass`, 1Password CLI, macOS Keychain (`security
find-generic-password ...`), libsecret (`secret-tool lookup ...`), gpg,
age, `cat`, etc. See `viking.pin.sh` for a script-form example.

## Multi-conf chain

Stick a `viking.conf` in `~/.config/viking/` for shared defaults (your
taxpayer block, say). Per-project confs in CWD override field-by-field.
Both get loaded automatically — pass `--conf` only when you want to bypass
the chain entirely.
