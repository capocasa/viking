# Viking example

A complete viking project that exercises every config feature: multi-source
income, alphanumeric aliases, spouse, kids, KAP, deductions, and the `[auth]`
defaults. Wired up against the public ELSTER sandbox so you can dry-run or
even submit (with `--test`) end-to-end.

## Files

| File                  | What it shows                                              |
|-----------------------|------------------------------------------------------------|
| `viking.conf`         | All section types in one place, all aliases used           |
| `viking.pin`          | Plain-text PIN (`123456`, the public test PIN)             |
| `viking.pin.sh`       | Alternative: a script that prints the PIN to stdout        |
| `2025-freelance.tsv`  | Auto-loaded for `freelance` source                         |
| `2025-mygewerbe.tsv`  | Auto-loaded for `mygewerbe` source                         |
| `deductions.tsv`      | All deduction code groups (vor / sa / agb / per-kid)       |

## Setup

Grab the public ELSTER test certificate (do this once):

```sh
wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
unzip Test_Zertifikate.zip
```

Drop or symlink one of the `.pfx` files into this directory as `viking.pfx`:

```sh
ln -s "$PWD/test-softorg-pse.pfx" viking.pfx
```

That matches viking's default convention (`<conf-basename>.pfx` next to the
conf). The PIN for all test certs is `123456`, already in `viking.pin`.

## Try it

All commands are safe — `--test` hits the ELSTER sandbox and adds a
`<Testmerker>`, `--dry-run` doesn't talk to ELSTER at all.

```sh
cd example

# UStVA (quarterly VAT advance), default source picked from conf
viking submit --test --period q1 --amount19 1000 --dry-run

# Word aliases everywhere — all of these are equivalent:
viking submit --test --period q1  --amount19 1000 --dry-run
viking submit --test --period 41  --amount19 1000 --dry-run
viking submit --test --period mar --amount19 100  --dry-run     # -> 03
viking submit --test --period 3   --amount19 100  --dry-run     # -> 03

# Multiple sources -> name the one you want
viking submit  freelance --test --period q1 --amount19 0 --dry-run
viking submit  mygewerbe --test --period q1 --amount19 0 --dry-run
viking euer    freelance --test --year 2025 --dry-run            # auto-loads 2025-freelance.tsv
viking euer    mygewerbe --test --year 2025 --dry-run
viking ust     mygewerbe --test --year 2025 --dry-run            # vorauszahlungen=100 picked up

# ESt aggregates every source: Anlage S (freelance) + Anlage G (mygewerbe)
# + Anlage KAP (ibkr inline values) + Anlage Kind for max & lisa.
viking est --test --year 2025 --deductions deductions.tsv --dry-run
```

To actually submit to the sandbox (no `--dry-run`):

```sh
viking submit --test --period q1 --amount19 0
```

You'll get a real round-trip to ELSTER's test endpoint. Drop `--test` once
your real cert is in place and you mean it.

## Picking the PIN format

The `[auth]` block in `viking.conf` is commented out because the defaults
already pick up `viking.pin`. To use the script form instead:

```ini
[auth]
pincmd = viking.pin.sh
```

Anything that prints the PIN to stdout works — `pass`, 1Password CLI, macOS
Keychain (`security find-generic-password ...`), libsecret (`secret-tool
lookup ...`), gpg, age. See `viking.pin.sh` for examples.

## Multi-conf chain

Stick a `viking.conf` in `~/.config/viking/` for shared defaults (your
[personal] block, say). Per-project confs in CWD override field-by-field.
Both get loaded automatically — pass `--conf` only when you want to bypass
the chain entirely.
