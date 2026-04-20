******
Viking
******

CLI for German tax submissions over ELSTER ERiC. UStVA, EÜR, USt, ESt,
plus Postfach downloads and IBAN changes — all driven from one
`viking.conf` per project.

This guide is the slow tour: every feature, with progressive examples.
For the cheat-sheet version, the README has you covered.

.. contents:: Contents
   :depth: 2

What's new
##########

The configuration model was reworked. Highlights:

- A single `viking.conf` per project drives every command. No more `.env`,
  no more `VIKING_*` env vars.
- INI sections classify themselves by **name and markers** — no `income =`
  field needed. The first section is the taxpayer, named by full name
  (`[Hans Maier]`). Only `[auth]`, `[freiberuf]`, `[gewerbe]` are reserved.
  Everything else falls out from the shape of the section:

  - `verhaeltnis = ...`            → kid (section name = full name)
  - `guenstigerpruefung`/`pauschbetrag` → Anlage KAP source
  - section name ends with a legal-form suffix (GmbH, UG, KG, OHG, GbR,
    PartG, eK, eG, KGaA, SE, "GmbH & Co. KG", …) → Anlage G with that
    Rechtsform
  - any later person-named section with an `idnr` → spouse
    (triggers Zusammenveranlagung; section name = full name)
  - anything else → Einzelgewerbe (Anlage G with rechtsform einzel)

- German-word aliases for every numeric ELSTER code you used to look up:
  `freiberuf` instead of `3`, `einzel` instead of `120`, `q1` instead of
  `41`, `rk` instead of `03`. Numerics still work.
- Explicit external-file wiring: the cert, PIN source, deductions
  TSV, and every invoice TSV are declared in the conf. No filesystem
  scanning, no basename-derived defaults — you always see which file
  feeds which return. Wire `pass`, Keychain or libsecret with a
  one-line `pincmd` shell command.
- Multi-source per conf: declare `[freiberuf]`, `[gewerbe]`,
  `[Musterfirma GmbH]` and `[ibkr]` (KAP) side-by-side; commands pick by
  section name.
- Two-file conf chain: `~/.config/viking/viking.conf` for shared
  defaults, `./viking.conf` to override per project.

The complete worked example for everything below lives in
`example/viking.conf`.

Getting started
###############

Build the binary, fetch the ERiC runtime, and seed an empty conf.

.. code-block:: sh

    nimble build
    ./viking fetch              # downloads ERiC, ~50 MB once
    ./viking init               # writes viking.conf + deductions.tsv

Point the `[auth]` section at your ELSTER signing cert (`cert=`) and
a PIN source (`pin=` for a plaintext PIN file, or `pincmd=` for a
script that prints the PIN). See *Auth (signing)* below. For sandbox
testing you don't need a real cert — see *Test certificates* below.

A single source
###############

The simplest viable conf: one person, one freelance income source.

.. code-block:: ini

    [Hans Maier]
    year     = 2025
    steuernr = 9198011310010
    strasse  = Musterstr.
    nr       = 1
    plz      = 10115
    ort      = Berlin
    iban     = DE91100000000123456789

    [freiberuf]
    versteuerung = ist
    euer   = freelance.tsv

That's enough for a UStVA:

.. code-block:: sh

    viking ustva --period q1

`freiberuf` is the only source, so you don't need to name it. Quarterly
period `q1` is the same as `41`; either works.

For an annual EÜR or USt you need amounts. The `euer=` key points
at the invoice TSV. Paths resolve relative to the conf dir; no
year interpolation — copy the whole project directory per tax year
(e.g. `2025/`, `2026/`) so each year's data stays pinned.
`euer=` is optional: sources without it submit zeros with a warning,
which is occasionally useful (you filed this source to the tax office
already, or the tax office wants a nil return).

A few per-project invariants, just to be clear:

- ``year`` lives in the conf (required, first section), not on the
  CLI. Copy the conf dir per year.
- There is no ``-y/--year`` flag. There is no ``$year`` interpolation.
- ``viking ustva`` submits the UStVA. Amounts come from
  ``source.euer=``; there is no ``--amount*`` flag.
- ``--dry-run`` validates via ERiC but does not send. Pair with
  ``-v/--verbose`` to also see the generated XML and ERiC response
  on stdout. There is no separate ``--validate-only``.

.. code-block:: sh

    cat > 2025-freiberuf.tsv <<'EOF'
    amount  rate    date            id              description
    1200    19      2025-01-15      INV-001         January
    -300    19      2025-02-01      EXP-001         Office supplies
    EOF

    viking euer --year 2025 --dry-run

Negative amounts are expenses. Both columns past `amount` and `rate`
are optional; `date` enables period filtering on `submit --period`.

Multiple sources
################

Add more sections — each one is a source. Section names can be the
reserved `[freiberuf]` (Anlage S) / `[gewerbe]` (Einzelgewerbe), or a
company name whose suffix picks the Rechtsform:

.. code-block:: ini

    [freiberuf]                    ; Anlage S, rechtsform freiberuf
    versteuerung = ist

    [Musterfirma GmbH]             ; Anlage G, rechtsform gmbh (350)
    steuernr        = 9198011310020   ; overrides personal.steuernr for this source
    versteuerung    = soll
    vorauszahlungen = 100

    [mygewerbe]                    ; no suffix → Einzelgewerbe (120)
    versteuerung = soll

Now commands need to know which source to act on. The section name is
the handle:

.. code-block:: sh

    viking ustva freiberuf          --period q1
    viking ustva "Musterfirma GmbH" --period q1
    viking euer  mygewerbe
    viking ust   "Musterfirma GmbH"      # picks up vorauszahlungen=100

`viking est` is special — it scans every source and emits Anlage G for
each Gewerbe and Anlage S for each `[freiberuf]`, all in one return:

.. code-block:: sh

    viking est

Word aliases
############

Any place you used to write a numeric code, you can write the German
word. Numerics still work; resolution is case-insensitive; leading
zeros are optional.

.. code-block:: ini

    rechtsform   = einzel          ; or 120 (usually set via the name suffix)
    versteuerung = ist             ; or 2
    religion     = rk              ; or 03
    verhaeltnis  = leiblich        ; or 1

The CLI gets the same treatment for `--period`:

.. code-block:: sh

    viking ustva --period q1   ...    # quarterly Q1
    viking ustva --period mar  ...    # March (also accepts "may", "oct", "dec")
    viking ustva --period 3    ...    # unpadded numeric, becomes "03"
    viking ustva --period 41   ...    # original numeric

A bad value gets rejected with the full list of valid words:

.. code-block:: text

    Error: rechtsform = "zzz": unknown; valid: hausgewerbe, einzel,
    landforst, freiberuf, selbst, beteiligung, person, atypisch, ohg,
    kg, gmbhkg, gmbhohg, agkg, agohg, gbr, ewiv, sonstperson, ag,
    kgaa, gmbh, se, ug, sce, genossenschaft, vvag, jp_priv, verein,
    gebiets, relgesell, jp_oeff, ausl_kap, ausl_person

Invoice TSVs got a small upgrade too: trailing `%` on the rate column
is tolerated, so you can write `19%` and `7%` if you prefer.

Anlage KAP (capital gains)
##########################

KAP sources don't need a TSV — gains, withheld tax and Soli go inline.
Marker: `guenstigerpruefung` or `pauschbetrag`:

.. code-block:: ini

    [ibkr]
    guenstigerpruefung = 1
    pauschbetrag       = 1000
    gains              = 1500.50
    tax                = 375.13
    soli               = 20.63

`viking est` aggregates every KAP source into one Anlage KAP. The
section name (here `ibkr`) is just a label for your benefit.

Spouse and kids
###############

Add a spouse section for joint filing (Zusammenveranlagung). Name it
with the spouse's full name. The marker is simply the presence of an
`idnr` on a later person-named section — IdNrs are only issued to
natural persons, so there's no ambiguity with companies:

.. code-block:: ini

    [Greta Maier]
    geburtsdatum = 12.07.1956
    idnr         = 04452397688
    religion     = ev
    beruf        = Lehrerin

Add one section per kid. The section name is the full name; the
first given word (lowercased) becomes the prefix for that kid's
deduction codes. Marker: `verhaeltnis`.

.. code-block:: ini

    [Max Maier]
    geburtsdatum         = 01.06.2018
    idnr                 = 12345678901
    verhaeltnis          = leiblich    ; to Person A (the filer)
    personb-verhaeltnis  = leiblich    ; to Person B (other parent)
    familienkasse        = Berlin      ; Familienkasse zustaendig fuer Kindergeld
    kindergeld           = 2400

    [Lisa Maier]
    geburtsdatum         = 15.03.2020
    idnr                 = 98765432109
    verhaeltnis          = leiblich
    personb-verhaeltnis  = leiblich
    familienkasse        = Berlin
    kindergeld           = 2400

``personb-verhaeltnis`` and ``familienkasse`` are optional but ERiC's
Anlage Kind plausibility checks ask for them — set them if you want a
clean validation. ``personb-verhaeltnis`` is the Kindschaftsverhältnis
to the other parent (can differ from ``verhaeltnis`` for stepchild /
foster cases). ``familienkasse`` is the office name (usually a city
like ``Berlin`` or ``Regensburg``).

Then in `deductions.tsv`, prefix the per-kid codes with the firstname:

.. code-block:: text

    code        amount  description
    max174      2400    Betreuungskosten Max
    lisa174     3600    Betreuungskosten Lisa
    lisa176     1500    Schulgeld Lisa

Wire the TSV into the taxpayer section so `viking est` picks it up
automatically:

.. code-block:: ini

    [Hans Maier]
    ...
    deductions = deductions.tsv

Leaving the key unset prints a warning on ``viking est``; use
``--force`` to silence it when you know there really are no
deductions to claim.

`viking est` emits one `<Kind>` block per kid section.

Auth (signing)
##############

Every submission is signed with a PFX cert + PIN. Both are declared
explicitly in `[auth]` — no basename-derived defaults, no filesystem
scanning. Paths are absolute or relative to the conf's directory.

.. code-block:: ini

    [auth]
    cert   = viking.pfx                 ; .pfx signing cert (required)
    pin    = viking.pin                 ; plaintext PIN file
    ; pin    = 123456                   ; or inline (sandbox only)
    ; pincmd = ./viking.pin.sh          ; or shell command that prints the PIN
    ; pincmd = pass show elster/pin

Set exactly one of ``pin`` or ``pincmd``:

* ``pin`` — if the value resolves to an existing file, viking reads
  the file (treating its contents as the plaintext PIN). Otherwise
  viking treats the value as the PIN itself (inline). Inline is fine
  for the public sandbox PIN (``123456``), not recommended if the
  conf is checked into version control.
* ``pincmd`` — any shell command. Runs with the conf's directory as
  cwd; stdout is the PIN. ``./viking.pin.sh``, ``cat viking.pin``,
  ``pass show elster/pin``, ``security find-generic-password -s elster
  -w``, ``secret-tool lookup app elster``, ``gpg --decrypt …``,
  ``age --decrypt -i key.age …`` — anything that prints the PIN on
  stdout works.

For a repeatable script form, drop the command into a file:

.. code-block:: sh

    #!/bin/sh
    exec pass show elster/main

Save as `viking.pin.sh`, set executable, then point
``pincmd = ./viking.pin.sh`` at it.

The conf chain
##############

Viking loads two confs and merges them field-by-field, CWD wins:

1. ``~/.config/viking/viking.conf`` — global defaults
2. ``./viking.conf`` — per-project overrides

Stick your personal block in the global one and just declare income
sources locally per project. Or override anything else — `[auth]`
defaults, steuernr, even religion if your circumstances change.

Pass `--conf <path>` to bypass the chain entirely; that explicit file
becomes the only conf loaded.

Test certificates
#################

For sandbox work, ELSTER ships a pack of test certs:

.. code-block:: sh

    wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
    unzip Test_Zertifikate.zip

Pick one (`softorg-pse.pfx` for business, `softpers-pse.pfx` for
personal), put it next to your conf as `viking.pfx`, write `123456`
into `viking.pin`, point `[auth]` at both, and submit with `--test`:

.. code-block:: sh

    viking ustva --test --period q1 --dry-run

`--test` does two things: routes to the ELSTER sandbox endpoint, and
adds a `<Testmerker>` to the XML so the production schema check
short-circuits. Drop the flag (and replace the cert) when you're ready
for the real thing.

Putting it all together
#######################

A single conf with the full kit — every section type, all aliases,
spouse and two kids, three income sources including KAP, and an
explicit `[auth]` pointing at `viking.pfx` + `viking.pin`:

.. code-block:: ini

    [Hans Maier]
    year         = 2025
    geburtsdatum = 05.05.1955
    idnr         = 04452397687
    steuernr     = 9198011310010
    strasse      = Musterstr.
    nr           = 1
    plz          = 10115
    ort          = Berlin
    iban         = DE91100000000123456789
    religion     = rk
    beruf        = Software-Entwickler
    krankenkasse = privat
    deductions   = deductions.tsv

    [Greta Maier]
    geburtsdatum = 12.07.1956
    idnr         = 04452397688
    religion     = ev
    beruf        = Lehrerin

    [freiberuf]
    versteuerung = ist
    euer   = freelance.tsv

    [mygewerbe]
    steuernr        = 9198011310020
    versteuerung    = soll
    vorauszahlungen = 100
    euer      = mygewerbe.tsv

    [ibkr]
    guenstigerpruefung = 1
    pauschbetrag       = 1000
    gains              = 1500.50
    tax                = 375.13
    soli               = 20.63

    [Max Maier]
    geburtsdatum        = 01.06.2018
    idnr                = 12345678901
    verhaeltnis         = leiblich
    personb-verhaeltnis = leiblich
    familienkasse       = Berlin
    kindergeld          = 2400

    [Lisa Maier]
    geburtsdatum        = 15.03.2020
    idnr                = 98765432109
    verhaeltnis         = leiblich
    personb-verhaeltnis = leiblich
    familienkasse       = Berlin
    kindergeld          = 2400

    [auth]
    cert = viking.pfx
    pin  = viking.pin

This is `example/viking.conf` in the repo, with TSVs and a deductions
file alongside it. Copy the directory and you have a working sandbox
project.

Postfach
########

Two extra commands talk to the ELSTER Postfach over libotto:

.. code-block:: sh

    viking list                              # list available documents
    viking download                          # download all
    viking download Steuerbescheid_2024.pdf  # specific file(s)
    viking download -o ./bescheide           # save into a subdir

Existing files are skipped; pass ``--force`` to overwrite. After every
download viking sends the mandatory `PostfachBestaetigung` confirmation
— do this within 24h or your HerstellerID gets suspended.

Not covered here
################

XML generators (one per form), the ERiC FFI bindings, the OTTER
bindings — all internals you don't usually need to touch. They're
documented separately in the generated API docs (``nimble docs``).

Reference
#########

Run any subcommand with ``-h`` for the full list of flags. The
short-flag conventions:

================  =================================================
``-c <file>``     viking.conf override
``-p <period>``   01..12 monthly, 41..44 quarterly, or word
``-o <file>``     output PDF / output dir for ``download``
``-D <dir>``      ``--data-dir``
``-v``            verbose (log XML + full server response to stdout)
``-f``            force / suppress warnings
================  =================================================

``--dry-run`` has no short — it's deliberate, spelling it out
prevents accidents. Validates via ERiC and stops before send; pair
with ``-v`` to see the generated XML.

Dev flags
=========

A couple of flags exist for development/CI and stay off the ``-h``
listing:

``--test``
  Submit to the ELSTER **sandbox** (Testmerker 700000004, receiver
  9198) instead of production. Uses the same cert/PIN. Every e2e
  test harness in this repo passes ``--test``; you want it too
  unless you're actually filing.

