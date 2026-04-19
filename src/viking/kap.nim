## Aggregation for Anlage KAP source sections.
##
## KAP data sits inline in `viking.conf` (no TSV needed), one section per
## broker/account. `aggregateKap` rolls every `income = kap` source up into
## a single `KapTotals` for `viking est`.

import viking/vikingconf

type
  KapTotals* = object
    gains*: float
    tax*: float
    soli*: float
    kirchensteuer*: float
    guenstigerpruefung*: bool
    sparerPauschbetrag*: float

proc aggregateKap*(sources: seq[Source]): KapTotals =
  ## Sum KAP figures across all sources with kind = skKap.
  ## guenstigerpruefung is OR'd across sources; sparerPauschbetrag is max().
  for s in sources:
    if s.kind != skKap: continue
    result.gains += s.gains
    result.tax += s.tax
    result.soli += s.soli
    result.kirchensteuer += s.kirchensteuer
    if s.guenstigerpruefung: result.guenstigerpruefung = true
    if s.sparerPauschbetrag > result.sparerPauschbetrag:
      result.sparerPauschbetrag = s.sparerPauschbetrag
