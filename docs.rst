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
- INI sections classify themselves: `[personal]`, `[spouse]`, `[auth]` are
  reserved; everything else is either an income source (has `income =`) or
  a kid (has `kindschaftsverhaeltnis =`).
- German-word aliases for every numeric ELSTER code you used to look up:
  `freiberuf` instead of `3`, `einzel` instead of `120`, `q1` instead of
  `41`, `rk` instead of `03`. Numerics still work.
- A new `[auth]` section with sensible defaults — drop `viking.pfx` +
  `viking.pin` next to the conf and you're done. Wire up `pass`,
  Keychain or libsecret with a one-line script.
- Multi-source per conf: declare `[freelance]` and `[mygewerbe]` and
  `[ibkr]` (KAP) side-by-side; commands pick by section name.
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

Drop your ELSTER signing certificate next to the conf as `viking.pfx`,
write the PIN into `viking.pin`, and you're ready to submit. For
sandbox testing you don't need a real cert — see *Test certificates*
below.

A single source
###############

The simplest viable conf: one person, one freelance income source.

.. code-block:: ini

    [personal]
    firstname    = Hans
    lastname     = Maier
    taxnumber    = 9198011310010
    street       = Musterstr.
    housenumber  = 1
    zip          = 10115
    city         = Berlin
    iban         = DE91100000000123456789

    [freelance]
    income          = freiberuf
    rechtsform      = freiberuf
    besteuerungsart = ist

That's enough for a UStVA:

.. code-block:: sh

    viking submit --period q1 --amount19 1000

`freelance` is the only source, so you don't need to name it. Quarterly
period `q1` is the same as `41`; either works.

For an annual EÜR or USt you need amounts. Drop a TSV named
`<year>-<source>.tsv` next to the conf and viking finds it
automatically:

.. code-block:: sh

    cat > 2025-freelance.tsv <<'EOF'
    amount  rate    date            id              description
    1200    19      2025-01-15      INV-001         January
    -300    19      2025-02-01      EXP-001         Office supplies
    EOF

    viking euer --year 2025 --dry-run

Negative amounts are expenses. Both columns past `amount` and `rate`
are optional; `date` enables period filtering on `submit --period`.

Multiple sources
################

Add a second section with `income =` and you've declared a second
source. Names are freeform — use whatever's meaningful to you.

.. code-block:: ini

    [freelance]
    income          = freiberuf       ; -> Anlage S
    rechtsform      = freiberuf
    besteuerungsart = ist

    [mygewerbe]
    income          = gewerbe         ; -> Anlage G
    taxnumber       = 9198011310020   ; overrides personal.taxnumber for this source
    rechtsform      = einzel
    besteuerungsart = soll
    vorauszahlungen = 100

Now commands need to know which source to act on:

.. code-block:: sh

    viking submit freelance  --period q1 --amount19 1000
    viking submit mygewerbe  --period q1 --amount19 5000
    viking euer    freelance --year 2025
    viking euer    mygewerbe --year 2025
    viking ust     mygewerbe --year 2025      # picks up vorauszahlungen=100

`viking est` is special — it scans every source and emits Anlage G for
each `income = gewerbe` and Anlage S for each `income = freiberuf`,
all in one return:

.. code-block:: sh

    viking est --year 2025 --deductions deductions.tsv

Word aliases
############

Any place you used to write a numeric code, you can write the German
word. Numerics still work; resolution is case-insensitive; leading
zeros are optional.

.. code-block:: ini

    income          = freiberuf       ; or 3
    rechtsform      = einzel          ; or 120
    besteuerungsart = ist             ; or 2
    religion        = rk              ; or 03
    kindschaftsverhaeltnis = leiblich ; or 1

The CLI gets the same treatment for `--period`:

.. code-block:: sh

    viking submit --period q1   ...    # quarterly Q1
    viking submit --period mar  ...    # March (also accepts "may", "oct", "dec")
    viking submit --period 3    ...    # unpadded numeric, becomes "03"
    viking submit --period 41   ...    # original numeric

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

KAP sources don't need a TSV — gains, withheld tax and Soli go inline:

.. code-block:: ini

    [ibkr]
    income              = kap
    gains               = 1500.50
    tax                 = 375.13
    soli                = 20.63
    guenstigerpruefung  = 1
    sparer_pauschbetrag = 1000

`viking est` aggregates every KAP source into one Anlage KAP. The
section name (here `ibkr`) is just a label for your benefit.

Spouse and kids
###############

Add a `[spouse]` section for joint filing (Zusammenveranlagung):

.. code-block:: ini

    [spouse]
    firstname  = Greta
    lastname   = Maier
    birthdate  = 12.07.1956
    idnr       = 04452397688
    religion   = ev
    profession = Lehrerin

Add one section per kid. The section name is the firstname — and it's
significant: it becomes the prefix for that kid's deduction codes.

.. code-block:: ini

    [max]
    birthdate                = 01.06.2018
    idnr                     = 12345678901
    kindschaftsverhaeltnis   = leiblich    ; to Person A (the filer)
    kindschaftsverhaeltnis_b = leiblich    ; to Person B (other parent)
    familienkasse            = Berlin      ; Familienkasse zustaendig fuer Kindergeld
    kindergeld               = 2400

    [lisa]
    birthdate                = 15.03.2020
    idnr                     = 98765432109
    kindschaftsverhaeltnis   = leiblich
    kindschaftsverhaeltnis_b = leiblich
    familienkasse            = Berlin
    kindergeld               = 2400

``kindschaftsverhaeltnis_b`` and ``familienkasse`` are optional but
ERiC's Anlage Kind plausibility checks ask for them — set them if
you want a clean validation. ``_b`` is the Kindschaftsverhältnis to
the other parent (can differ from ``_a`` for stepchild / foster
cases). ``familienkasse`` is the office name (usually a city like
``Berlin`` or ``Regensburg``).

Then in `deductions.tsv`, prefix the per-kid codes with the firstname:

.. code-block:: text

    code        amount  description
    max174      2400    Betreuungskosten Max
    lisa174     3600    Betreuungskosten Lisa
    lisa176     1500    Schulgeld Lisa

`viking est` emits one `<Kind>` block per `[<name>]` section.

Authentication
##############

Defaults first: with no `[auth]` section, viking looks next to your conf
for `<basename>.pfx` and a `<basename>.pin*` file. So `viking.conf`
pairs with `viking.pfx` + `viking.pin`. `client-foo.conf` pairs with
`client-foo.pfx` + `client-foo.pin`. No config required.

Override anything you want with `[auth]`:

.. code-block:: ini

    [auth]
    cert   = /elsewhere/softorg.pfx     ; absolute paths stay as-is
    pin    = secret/the.pin             ; relative -> resolved against conf dir
    ; pincmd = scripts/get-pin.sh       ; alternative: any script printing PIN

The pin file is dispatched by extension. Pick one:

==========================  ==========================================
File                        How viking reads it
==========================  ==========================================
``viking.pin``              plain text — pin is the file contents
``viking.pin.sh``           run via ``sh``, stdout is the pin
``viking.pin.ps1``          run via ``powershell``, stdout is the pin
``viking.pin.cmd|.bat``     run via ``cmd /c``, stdout is the pin
``viking.pin.exe``          run directly, stdout is the pin
==========================  ==========================================

For secret-manager integration, write a tiny script that prints the
PIN. Anything works that talks to stdout:

.. code-block:: sh

    #!/bin/sh
    exec pass show elster/main
    # exec security find-generic-password -s elster -w        # macOS Keychain
    # exec secret-tool lookup app elster                      # libsecret
    # exec gpg --decrypt ~/.elster.gpg

Save as `viking.pin.sh`, set executable, done.

The conf chain
##############

Viking loads two confs and merges them field-by-field, CWD wins:

1. ``~/.config/viking/viking.conf`` — global defaults
2. ``./viking.conf`` — per-project overrides

Stick your `[personal]` block in the global one and just declare income
sources locally per project. Or override anything else — `[auth]`
defaults, taxnumber, even religion if your circumstances change.

Pass `--conf <path>` to bypass the chain entirely; that explicit file
becomes the only conf loaded.

Test certificates
#################

For sandbox work, ELSTER ships a pack of test certs:

.. code-block:: sh

    wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
    unzip Test_Zertifikate.zip

Pick one (`softorg-pse.pfx` for business, `softpers-pse.pfx` for
personal), drop it next to your conf as `viking.pfx`, write `123456`
into `viking.pin`, and submit with `--test`:

.. code-block:: sh

    viking submit --test --period q1 --amount19 0

`--test` does two things: routes to the ELSTER sandbox endpoint, and
adds a `<Testmerker>` to the XML so the production schema check
short-circuits. Drop the flag (and replace the cert) when you're ready
for the real thing.

Putting it all together
#######################

A single conf with the full kit — every section type, all aliases,
spouse and two kids, three income sources including KAP, and an [auth]
default that just picks up `viking.pfx` + `viking.pin`:

.. code-block:: ini

    [personal]
    firstname    = Hans
    lastname     = Maier
    birthdate    = 05.05.1955
    idnr         = 04452397687
    taxnumber    = 9198011310010
    street       = Musterstr.
    housenumber  = 1
    zip          = 10115
    city         = Berlin
    iban         = DE91100000000123456789
    religion     = rk
    profession   = Software-Entwickler
    kv_art       = privat

    [spouse]
    firstname    = Greta
    lastname     = Maier
    birthdate    = 12.07.1956
    idnr         = 04452397688
    religion     = ev
    profession   = Lehrerin

    [freelance]
    income          = freiberuf
    rechtsform      = freiberuf
    besteuerungsart = ist

    [mygewerbe]
    income          = gewerbe
    taxnumber       = 9198011310020
    rechtsform      = einzel
    besteuerungsart = soll
    vorauszahlungen = 100

    [ibkr]
    income              = kap
    gains               = 1500.50
    tax                 = 375.13
    soli                = 20.63
    guenstigerpruefung  = 1
    sparer_pauschbetrag = 1000

    [max]
    birthdate                = 01.06.2018
    idnr                     = 12345678901
    kindschaftsverhaeltnis   = leiblich
    kindschaftsverhaeltnis_b = leiblich
    familienkasse            = Berlin
    kindergeld               = 2400

    [lisa]
    birthdate                = 15.03.2020
    idnr                     = 98765432109
    kindschaftsverhaeltnis   = leiblich
    kindschaftsverhaeltnis_b = leiblich
    familienkasse            = Berlin
    kindergeld               = 2400

This is `example/viking.conf` in the repo, with three TSVs and a
deductions file alongside it. Copy the directory and you have a working
sandbox project.

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
``-y <year>``     tax year (defaults to current)
``-p <period>``   01..12 monthly, 41..44 quarterly, or word
``-i <file>``     invoice TSV/CSV (overrides ``<year>-<source>.tsv``)
``-D <file>``     deductions TSV
``-o <file>``     output PDF / output dir for ``download``
``-n``            ``--validate-only``
``-d``            ``--dry-run``
``-v``            verbose (full server XML)
``-f``            force / suppress warnings
================  =================================================
