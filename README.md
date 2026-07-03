# RemoveRedundantSig

A MuseScore 3 plugin that deletes redundant time signatures **without
destroying your layout** — system breaks, custom volta positions, spacers,
and stretch all survive.

Requires MuseScore 3.5+ (developed and tested on 3.6.2).

## Installation

1. Copy `RemoveRedundantSig.qml` into your plugins folder
   (`Documents/MuseScore3/Plugins` by default).
2. `Edit → Plugins → Plugin Manager`, tick **RemoveRedundantSig**.

## Usage

The plugin has three modes, chosen by what is selected when you run
`Plugins → RemoveRedundantSig`:

**Remove one signature** — click the redundant time signature (the real
one, not a courtesy copy at a line end), then run the plugin. It verifies
the signature restates the prevailing meter, refuses anything else, and
removes it. Silent on success: the score simply reopens with the
signature gone.

**Clean up the whole score** — run the plugin with *nothing* selected. It
scans every staff and removes every stored signature that is *fully*
redundant. The criterion is deliberately conservative; a signature is
removed only if **all** of the following hold:

* its complete identity — numerator, denominator, display style
  (common-time **C** vs numeric 4/4 vs cut time), and any custom text —
  matches the prevailing signature (so a numeric `4/4` following **C** is
  kept: removing it would change the engraving);
* it is not the first signature of the piece;
* it is not in the measure immediately after a **section break**
  (restating the meter at a movement start is correct notation);
* an identical redundant signature exists in **every** staff at the same
  measure — which also means local/per-staff time signatures are never
  touched.

Everything the sweep *keeps* is listed in the plugin console with the
reason. To force out an individual keeper, use single mode — clicking a
specific signature is treated as an explicit decision and only the
nominal meter is checked.

Courtesy signatures at line ends are generated at layout time and never
stored in the file, so the plugin structurally cannot affect them; control
those from each signature's Inspector as usual.

**Undo** — run the plugin with nothing selected *when nothing has changed
since the last surgery*. You'll be offered **Undo / Clean Up / Cancel**;
Undo restores the pre-surgery backup. The eligibility rule makes this
safe by construction: undo is only offered when the current score state
exactly matches the post-surgery snapshot, so it can never eat work. If
you've edited since the surgery, Ctrl+Z back to the post-surgery state
and run again.

## The problem

In MuseScore 3 (fixed in Musescore 4), deleting a mid-score time
signature triggers the measure-rewrite ("rebar") machinery across the span
up to the next time signature — **even when the deleted signature restates
the prevailing meter and nothing about the barring actually changes.** The
measures in that span are destroyed and rebuilt as objects, and everything
attached to them goes down with the rebuild:

* manual **system/page/section breaks** are removed;
* **volta segments** are regenerated at default position, discarding any
  manual offsets;
* spacers and stretch in the span are likewise lost.

So the seemingly-trivial act of removing a redundant `4/4` can silently
wreck a carefully formatted lead sheet.

### Why a normal plugin can't fix this

The obvious approach — snapshot the layout state, delete via the API,
restore — was tried and is **provably impossible** in the MuseScore 3
plugin API. Breaks can be saved and restored (early versions of this
plugin did exactly that), but system-anchored spanners such as voltas
cannot: the API exposes no spanner list, they do not appear in range
selections (verified experimentally — a whole-score selection yields
slurs but no volta segments), and the segments that would need their
offsets rewritten don't even exist until a re-layout that happens after
the plugin has finished. Since the MS3 API is frozen, that wall is
permanent.

### How this plugin fixes it

By never letting the rebar run. The plugin edits the **saved file
itself**: it locates the `<TimeSig>` element(s) in the XML and removes
them. MuseScore then simply loads a score whose redundant signature never
existed — no rewrite, no casualties.

* For **.mscx** files this is byte-surgical: the only change to your file
  is the removed `<TimeSig>` lines (verifiable with any diff tool against
  the automatic backup).
* For **.mscz** files the plugin serializes the score to a temporary
  .mscx, performs the same surgery, and has MuseScore repack the result
  over the original. The output is MuseScore's canonical serialization of
  the surgered score: everything that survives a normal Ctrl+S survives
  the surgery.

## Safety model

* The plugin **auto-saves** before operating, so surgery always applies to
  exactly what you see. For .mscx it additionally verifies that the
  serialized score matches the file on disk (guarding against failed
  saves and external modification, e.g. cloud-sync surprises) and aborts
  on mismatch.
* Validation is all-or-nothing across staves; any inconsistency aborts
  with no changes.
* Before every surgery a backup is written to MuseScore's own hidden
  backup folder: `.mscbackup/<name>.rrs.bak` (for .mscz files this
  contains the pre-surgery .mscx serialization). One stable name,
  overwritten per run — it exists so you can revert the surgery you just
  did, not as an archive.
* A post-surgery snapshot (`.mscbackup/<name>.rrs.post.mscx`) is kept as
  the undo-eligibility oracle and consumed on undo.
* The plugin closes and reopens your tab as part of the operation (for
  .mscz, a temporary tab also flickers by — this is normal). The undo
  history is lost in the process; this is a MuseScore limitation (undo
  stacks are in-memory only and cannot be saved by any means), and it is
  exactly what the integrated Undo mode compensates for.

## Why only time signatures?

Because the pathology is specific to them. Clefs and key signatures are
rendering-level annotations; deleting them never rebuilds measures, so
breaks and voltas survive their deletion in the ordinary in-app way
(verified experimentally). Time signatures are the only element whose
deletion re-bars the score. Note that *changing* a time signature to a
different meter also destroys breaks — but there the rebar is doing real
work and old break positions are semantically stale anyway; this plugin
deliberately handles only the case where the rebar is pure destruction:
deleting a signature that changes nothing.

## Limitations

* Local (per-staff) time signatures are detected and left alone; the
  plugin will not remove them.
* Signatures immediately after section breaks are kept by the batch sweep
  (by design; single mode can remove them).
* The undo snapshot tracks only the most recent surgery; there is no
  multi-step history.
* .mscz surgery is a load/save roundtrip, not a byte-level edit of the
  zip (see above for what that does and doesn't guarantee).
* Scores must live in a real file; brand-new unsaved scores should be
  saved once first.

## Version history

* **1.0.0** — first public release: single removal, batch sweep,
  integrated undo, .mscx (byte-surgical) and .mscz (repack) support.

[musescore#21578]: https://github.com/musescore/MuseScore/issues/21578
