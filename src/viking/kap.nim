## Aggregation for Anlage KAP source sections.
##
## KAP data sits inline in `viking.conf` (no TSV needed), one section per
## broker/account. `aggregateKap` rolls every `income = kap` source up into
## a single `KapTotals` for `viking est`.

import viking/vikingconf

type
  KapTotals* = object
    gains*: float                       ## Zeile 7 — inländisch, mit Steuerabzug
    gainsOhneStAbz*: float              ## Zeile 18 — inländisch, ohne Steuerabzug
    gainsAusland*: float                ## Zeile 19 — ausländisch, ohne Steuerabzug
    tax*: float
    soli*: float
    kirchensteuer*: float
    guenstigerpruefung*: bool
    sparerPauschbetrag*: float
    auslaendischeQuellensteuer*: float
    nichtAnrechenbarAqs*: float
    verlusteAktien*: float
    verlusteSonstige*: float

func hasSteuerabzug*(s: Source): bool =
  ## Per-source answer to: did the payer withhold German KapESt (and
  ## friends)? Explicit `steuerabzug=` in the conf wins; otherwise we
  ## infer from whether any of tax/soli/kirchensteuer carry a value.
  ## Distinction matters for the KAP form: withholding gains go on
  ## Zeile 7, un-withheld ones on Zeile 18/19.
  if s.steuerabzugSet: return s.steuerabzug
  s.tax > 0 or s.soli > 0 or s.kirchensteuer > 0

proc aggregateKap*(sources: seq[Source]): KapTotals =
  ## Sum KAP figures across all sources with kind = skKap.
  ## guenstigerpruefung is OR'd across sources; sparerPauschbetrag is max().
  ## Gains are bucketed per-source by `hasSteuerabzug`: Zeile 7 (withheld),
  ## Zeile 18 (inländisch ohne Steuerabzug), Zeile 19 (ausländisch).
  for s in sources:
    if s.kind != skKap: continue
    if s.hasSteuerabzug:
      result.gains += s.gains
    elif s.auslaendisch:
      result.gainsAusland += s.gains
    else:
      result.gainsOhneStAbz += s.gains
    result.tax += s.tax
    result.soli += s.soli
    result.kirchensteuer += s.kirchensteuer
    result.auslaendischeQuellensteuer += s.auslaendischeQuellensteuer
    result.nichtAnrechenbarAqs += s.nichtAnrechenbarAqs
    result.verlusteAktien += s.verlusteAktien
    result.verlusteSonstige += s.verlusteSonstige
    if s.guenstigerpruefung: result.guenstigerpruefung = true
    if s.sparerPauschbetrag > result.sparerPauschbetrag:
      result.sparerPauschbetrag = s.sparerPauschbetrag
  # Günstigerprüfung implicitly claims the Sparer-Pauschbetrag (1000 €
  # single / 2000 € couple). ELSTER defaults the same way when the box
  # is ticked but the Pauschbetrag field is left blank. Only meaningful
  # for Z.7 income (mit Steuerabzug) — ERiC rule 192021 rejects <Sp_PB>
  # when the only gains are ohne Steuerabzug (Z.18/Z.19), because
  # E1901401 specifically represents the SPB already used at the
  # withholding source.
  if result.guenstigerpruefung and result.sparerPauschbetrag == 0 and
     result.gains > 0:
    result.sparerPauschbetrag = 1000
