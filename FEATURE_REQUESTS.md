# Feature Requests

Surfaced during 2025 tax session (Carlo + Beatrice). Prior FRs #1–3,
#5–8 were implemented 2026-04-22.

FR #9 status (2026-04-22):
- TSV loader + Ertragsanteil computation: DONE. `personal.rente =
  rente.tsv`; columns `art zahler betrag zahlung_am gefoerdert
  ertragsanteil_prozent lebensalter_beginn herkunftsland`.
  See `src/viking/rente.nim`, example `example/rente.tsv`.
- `est` logs a per-row summary.
- Anlage R / R_AUS XML emission: DONE for three cases — domestic
  Leibrente → `<R>/Leibr_priv`, foreign Leibrente →
  `<R_AUS>/Leibr_priv`, foreign Kapital/Freizügigkeit (nicht
  gefördert) → `<R_AUS>/Leist_bAV` (E1823101 country, E1823901
  Einmalleistung). See `classifyRente` in `src/viking/est_xml.nim`
  and the ERiC-validated e2e assertions in `tests/test_example.nim`.
- Remaining gaps (not routed; surface as warnings so the filer can
  add them via ELSTER Online):
  * gefördert cases (Riester/Rürup/bAV) → Anlage R-AV/bAV. The XSD
    type is `RAV_bAV_67907_CType` / `Leist_AV_betr` with the
    E1803xxx/E1804xxx Kennzahlen (Vertragsart + amount + begin +
    Zulage-Nr. + Riester-Nr.). Needs more conf fields (Vertragsart,
    Riester/Rürup-Vertragsnummer) before we can safely emit.
  * Domestic Kapitalleistungen (§22 Nr. 5 Satz 2) — no dedicated
    Kennzahl outside bAV; typically filed on SO or via Sonstige
    Nachricht.
  * Domestic gesetzliche Rente with Oeff_Kl / Rentenanpassungsbetrag
    handling — today we only emit `<R>/Leibr_priv`.

## 10. Anlage R-AUS Leist_bAV: Vertragsabschluss-Datum missing (blocks foreign Freizügigkeit)

**Observed** (real Beatrice 2025 dry-run, `personal.rente = rente.tsv`,
one row `art=freizuegigkeit gefoerdert=no betrag=4554.26 herkunftsland=CH
zahlung_am=11.07.2025`):

```
FachlicheFehlerId 101220055:
Der Betrag der Einmalleistungen aus einer ausländischen betrieblichen
Altersversorgungseinrichtung und das Datum des Vertragsabschlusses
müssen gemeinsam angegeben werden (1. Rente; Anlage R-AUS der
steuerpflichtigen Person / des Ehemannes / der Person A).
```

Viking emits `<Leist_bAV><Einz>` with `E1823101` (country) and
`E1823901` (Einmalleistung-Betrag) but no Vertragsabschluss date. ERiC
requires the two to travel together, so any `freizuegigkeit`/`kapital`
row with `gefoerdert=no` and `herkunftsland != DE` blocks the entire
Beatrice ESt dry-run.

**Proposal:**

1. Add a `vertragsabschluss` column to `rente.tsv` (DD.MM.YYYY); thread
   through `RenteRow.vertragsabschluss`.
2. In `est_xml.nim` foreign-Kapital block, when `vertragsabschluss` set,
   emit the companion E-code alongside `E1823901`. Kennzahl is in the
   Anlage R-AUS 2025 XSD — likely around E1823801 or E1824001.
3. Fallback guidance in the example TSV / docs: if the user doesn't know
   the original Vertragsabschluss date, the Freizügigkeitskonto opening
   date (or the date of roll-over from the previous Pensionskasse) is
   usually accepted.
4. Add `tests/test_example.nim` e2e assertion covering the
   `--output-pdf` path for the foreign-Freizügigkeit case so this
   combination is covered under the full schema check (the current
   plausi-only check missed it).

**Workaround for us:** disabled `rente = rente.tsv` in Beatrice's conf;
Anlage R-AUS will be added by hand in ELSTER Online before transmission.

## 9. Anlage R (Renten und andere Leistungen)

**Observed:** Beatrice 2025 received a Barauszahlung of €4,440.39 from a
Swiss Freizügigkeitskonto (UBS CH, 2. Säule vested benefits account,
wound up after she moved to Germany and the savings were no longer
needed). German residents are taxable on this in Germany per §22 Nr. 5
EStG (sonstige Einkünfte aus Altersvorsorge), with the taxation right
assigned to Germany under Art. 18 DBA CH-DE.

Viking currently has no Anlage R support (grep of `src/` for
`Anlage.R`, `Leibrente`, `Ertragsanteil`, `Versorgungsbezug`,
`Altersversorgung`, `Renten` returns nothing), so the payout can't be
declared through viking.

**Use cases beyond Beatrice's Freizügigkeitskonto:**

- Swiss 2. Säule (BVG) and 3. Säule (3a) Barauszahlungen for former
  CH residents now living in DE — common for expats.
- German gesetzliche Rente (typical retirement benefit).
- Private Rente / Rürup / Riester payouts.
- Foreign state/occupational pensions.
- Kapitalabfindungen aus betrieblicher Altersversorgung.

**Minimum useful scope (MVP) for the Swiss Freizügigkeit case:**

- One `[anlager]`-style source or per-payout section with:
  - `art` = type of Leistung (Leibrente, Kapitalleistung, Einmalzahlung,
    Freizügigkeit, etc.)
  - `quelle` / `zahler` = payer name (e.g. "UBS AG, Zürich")
  - `herkunftsland` = country code (e.g. `CH`)
  - `betrag` = gross amount in EUR
  - `beginn` / `zahlung_am` = payment date
  - `gefoerdert` (bool) = whether contributions were steuerlich gefördert
    in Germany (for §22 Nr. 5 Satz 1 vs Satz 2 split)
  - `ertragsanteil_prozent` (optional override) or `lebensalter_beginn`
    so viking can look up the Ertragsanteil table (§22 Nr. 1 Satz 3 a bb
    EStG table for Leibrenten, or the Kapitalleistung-specific rules).
- Emit as a Sonstige-Einkünfte / Anlage R block with the correct ERiC
  codes for the relevant 2025 form line.

**Priority:** low for us right now (small amount, likely small taxable
Ertragsanteil). Workaround for 2025: add Anlage R by hand in ELSTER
Online after submitting viking's ESt, or send a Sonstige Nachricht to
the Finanzamt with the calculation attached.
