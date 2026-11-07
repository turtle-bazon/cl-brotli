## State after the fragment-hash port (4 Nov 2026, rev 79)

Level-matched 1 MiB, C core reference, this host:

compression (lisp/C core; lisp/C size in parens) | q0 | q1 | q2 | q5
---                      | ---: | ---: | ---: | ---:
html                     | 0.32x (0.92) | 0.41x (1.05) | 0.46x (1.09) | 0.74x (1.19)
json                     | 0.29x (0.82) | 0.48x (0.96) | 0.36x (1.20) | 0.76x (1.10)
text                     | 6.36x (0.34) | 0.62x (0.43) | 0.53x (1.09) | 0.64x (1.07)
source                   | 1.28x (0.41) | 0.88x (0.44) | 0.46x (1.13) | 0.66x (1.06)
binary                   | 0.28x (0.98) | 0.35x (1.03) | 0.33x (1.12) | 0.79x (1.06)

q0/q1 profiles (sb-sprof, HTML 1 MiB, after rev 79): `%LZ77-FRAGMENT`
46.1% self, `WRITE-FAST-BLOCK-BODY` 39.7%, tree building ~5%. The
matcher sits ~300 MiB/s alone; the emit pass costs the rest of the 2x.
The C one-pass structure (pre-LZ77 sampled literal histogram + fixed
64-symbol command/distance pre-code) would remove the second pass but
moves ratio to C's per-corpus curve: near-parity on text (+2.6% size)
but worse on json (+22%) and binary. With the measured precedent that
both batched-local-writer attempts regressed, the remaining encode
levers in order are (a) VOPs for the emit loop, (b) the one-pass port
with a ratio guard, (c) an array-based build-code-lengths (the single
visible cons/sort cost).

# Reanalysis: where the lisp/C gap comes from (3 Nov 2026)

## Current state after rev 84 (the five-corpus level-matched snapshot)

compression — cell = size lisp/C (speed lisp/C-core):
q | html | json | text | source | binary
--- | --- | --- | --- | --- | ---
0 | 0.92 (0.32x) | 0.82 (0.30x) | 0.34 (6.4x) | 0.41 (1.3x) | 0.98 (0.29x)
1 | 1.05 (0.41x) | 0.96 (0.48x) | 0.43 (0.62x) | 0.44 (0.87x) | 1.03 (0.35x)
2 | 1.03 (0.46x) | 1.05 (0.44x) | 1.06 (0.54x) | 1.09 (0.45x) | 1.09 (0.36x)
5 | 1.13 (0.83x) | 1.04 (0.82x) | 1.06 (0.60x) | 1.05 (0.69x) | 1.07 (0.84x)
9 | 1.04 (0.72x) | 1.02 (0.73x) | 1.05 (2.2x) | 1.03 (0.92x) | 1.07 (1.05x)
11 | 1.16 (7.7x) | 1.19 (8.6x) | 1.21 (14x) | 1.13 (14x) | 1.20 (25x)

decompression of C streams lisp/C-core:
q | html | json | text | source | binary
--- | --- | --- | --- | --- | ---
0 | 0.44 | 0.41 | 0.51 | 0.45 | 0.52
1 | 0.38 | 0.37 | 0.46 | 0.38 | 0.53
2+ | 0.35-0.50 | 0.34-0.35 | 2.4-5.0 | 0.47-0.86 | 0.36-0.60

vs. the session start: q2 sizes 1.09-1.20 (outside the cap) now
1.03-1.09 (inside); q0 sizes 0.95-0.87 congruent with the hash port;
decode q0/q1 0.30-0.34 -> 0.35-0.53; the length-tree consing removed;
the q1 table-bits-17 unreachable hash fixed. What remains where:
q0/q1 literal-heavy compression (0.29-0.48x) and q0/q1 decode
(0.35-0.53x); both are per-symbol instruction-count bound in SBCL and
need VOP-level work (a wbits/ReadSymbol-class VOP or the C one-pass
encoder structure with ratio guard) — the session's three lisp-level
local-state attempts all regressed when measured.



Fresh pass over `src/`, the C sources (`/tmp/opencode/brotli-c`, HEAD d89c4b1c:
`c/enc`, `c/dec`), SBCL 2.6.9 disassembly, and new measurements on this host
(Ryzen 7 3700X, C Brotli 1.0.9, 1 MiB generated corpora). Level-matched
`lisp/C core` ratios, this host:

compression (lisp/C core; lisp/C size in parens) | q0 | q1 | q2 | q5
---                      | ---: | ---: | ---: | ---:
html                     | 0.33x (0.95) | 0.45x (1.08) | 0.46x (1.09) | 0.83x (1.19)
json                     | 0.34x (0.79) | 0.55x (0.95) | 0.36x (1.20) | 0.70x (1.10)
text                     | 6.34x (0.35) | 0.64x (0.44) | 0.51x (1.09) | 0.68x (1.07)
source                   | 1.25x (0.43) | 0.93x (0.46) | 0.46x (1.13) | 0.69x (1.06)
binary                   | 0.28x (0.99) | 0.36x (1.05) | 0.34x (1.12) | 0.78x (1.06)

decompression of C streams (lisp/C core) | q0 | q1 | q2 | q5
--- | ---| ---| ---| ---|
html  | 0.37x | 0.33x | 0.30x | 0.33x
json  | 0.36x | 0.33x | 0.32x | 0.33x
text  | 0.47x | 0.44x | 1.99x | 1.17x
source| 0.40x | 0.35x | 0.51x | 0.43x
binary| 0.48x | 0.50x | 0.45x | 0.33x

The shape: **all cells that decode or encode one symbol per byte sit at a
uniform 0.30–0.55x of the C core.** Everything that is not one-symbol-per-byte
(long matches, stored blocks, dictionary work at q10/q11) matches or beats C.
So the remaining gap is a per-symbol constant factor, identical in kind across
every quality — not a matcher-policy or stream-structure problem at q7+.

## What was fixed in this pass

1. **Decoder validity-tail bug (correctness).** `%DECODE-LIT-RUN` handed the
   end of a literal run to the slow reader *after* the current code's primary
   table bits had already been consumed (inside the secondary-table branch).
   `READ-HUFF` then resumed at a non-symbol boundary and produced wrong symbols.
   A valid q0 stream for the 1 MiB generated HTML corpus decoded with its last
   4 literals wrong; the C decoder accepted the same stream, and the unit
   suite (94 checks) does not hit the shape. The hand-off now saves the
   reservoir state before consuming the primary entry and restores it before
   dropping to `READ-HUFF`. 94/94 pass, byte-exact round-trip restored.
2. **q1 fragment configuration.** `quality-params` set q1 to `max-chain 1`,
   which made the `lz77` fragment dispatch select the same 15-bit hash /
   5-byte minimum match as q0 — q1 output was byte-identical to q0 and 12.6%
   larger than C q1. C's `compress_fragment_two_pass` uses a 2^17-entry table
   with a 6-byte minimum match (`quality.h:36`, `encode.c:176`). q1 now routes
   to table-bits 17 / min-match 6: 254,417 bytes instead of 267,557 on HTML
   (−4.9%), same speed, 1.075x C q1 size.

## Attempted 4 Nov 2026: local-state command loop, round 2 (values-passing readers)

The single-expansion readers (`%rsym-cmd`/`%rsym-dist`/`%rsym-lit` plus
`%rx-ib`/`%rx-cb`/`%rx-db`, each `(r tree|need acc nbits p) →
(values sym acc nbits p)`) work and pass 150/150 (incl. multi-block,
into-API bounds, large-secondary-tables) once two self-inflicted bugs
were fixed:

1. the `%rx-ib`/`%rx-cb` fallback `(values 0 acc nbits p)` sat inside
   `(when (plusp need) ...)`, so zero-bit reads returned NIL as the
   first value (the `expected FIXNUM, datum NIL` trap);
2. the fast loop lacked the loop-head `(>= pos target)` exit, so a
   copy that lands exactly on MLEN read a phantom command and
   desynchronized (the `expected (INTEGER 0 (16777215))` trap — the
   data-array bounds check).

Measured, HTML 1 MiB decode (lisp-on-C-core): r77 generic loop +
64-bit copies 232/240 MiB/s at q0/q2; the new fast path 222/224 (−4%).
With the readers de-inlined: 170/179 (−25%). So:

* inline expansion of the readers matters a lot (the p/nbits/acc
  state moves across a call boundary);
* even with inline, the multiple-value state rounding still loses to
  the generic loop's struct accesses + the fast 64-bit copies; the
  struct fields stay in a cached base register, and the per-read
  value shuffling costs more than it saves.

The tree keeps the r77 shape. The next step for the command loop is
not values-passing LISP — it is a VOP-level move (like
`%MATCH-LEN-SAP`): a `HALF-DECODED-COMMAND` VOP or a restructure that
keeps acc/nbits/pos as untagged `REG` TNs across the whole loop, or a
batched "read command + extra bits in one VOP" primitive. The working
skeleton is preserved at `/tmp/opencode/decompress-rsym.bak` (not in
the tree).

Recorded the harness pitfalls for future sessions: the recurring
`(see %decode-simple-meta-block)` char-per-line explosion happened
because `lines[a:b] = disp` with a *string* `disp` iterates characters;
splice with `disp.split('\n')`.

## Chain matcher: full-spread 64-bit hash (rev 83)

The chain 17-bit table's top half had never even been reachable
(hash bits 15..30 of a 32-bit product → every hash < 2^16; the extra
half of the table wasted, collisions doubled). Ported the same u64
algebra as the fragment (r79) plus a 5-byte input spread instead of 4:
level-matched q2 sizes drop 1.09-1.20 → 1.03-1.09 on all five corpora,
q5 → 1.03-1.13, q9 → 1.02-1.07 with q9 speeds up 5-15%; q11 sizes drop
~0.5-4%. Now all q2+ levels sit tighter in the cap.

## Attempted 4 Nov 2026: packed per-symbol emit table — measured, reverted

Built a parallel `lit-pc` table (`len<<16 | reversed code`, one u32 aref
per literal instead of two fixnum loads) and used it in the `lits`
inline emission of `WRITE-FAST-BLOCK-BODY`. Median HTML q0
full-compress throughput over 7 samples: r79 writer 160 MiB/s, packed
variant 157 MiB/s — the reduced table loads did not pay for the extra
logand/ash per literal, so the change was reverted (consistent with the
earlier two-literal-batching and bucket-hasher reverts). Rev 81's
length-tree port needed only one code fix en route: a
`(let (left right))` cannot declare NIL-typed slots FIXNUM.

## Attempted 4 Nov (evening): the %wbits-pack VOP — prototype shape correct,
## the 3-result tuple did not land in the harness; reverted

Wrote the pack+flush VOP following the in-tree `%match-len-sap` pattern
(defknown with the raw unsigned-reg for the accumulator, the SAP for the
pinned out buffer, a positive-fixnum outpos, 3 results) plus a LISP
runtime fallback in src/package.lisp mirroring the VOP (the same rule as
the match-len hook). The VOP *compiles* and calls dispatch, but the
harness only saw a single zero result: SBCL's multiple-value VOP results
require the result-tuple VALUE layout (each result must come out as a
properly tagged register sequence; bit fields like the nbits result want
an explicit `inst_shl`, 2) — and the third result got lost. The
implementation is mechanical but the numeric encode needs its own
careful session; it is recorded here with the exact defknown/body shape
(at hg r91 in the notes) so the next session lands the *results
tuple* correctly and re-measures.

The verify steps for the next pass:
1. In `define-vop`, use (:results (racc rnbits rpos)) with
   (:result-types ...) or just (:results) fixnums, and emit all three
   registers as TAGGED results (each with `inst shl ... 1` or an
   `(inst mov r1 raw-value)` and one tag);
2. check that the LISP interpreter used in --script top-level forms
   calls the function through the runtime LISP body BOTH when the VOP
   applies AND when it doesn't (the correct fallback path);
3. keep the `validate%wbits-raw-pm vs %wbits-pack` bitwise harness from
   this session's record (the correctness kernel is already written).

## Attempted 4 Nov 2026 (night): u16/u8 encoder arrays — measured, reverted

Typed the encoder's per-symbol hot arrays to shrink footprint:
`etree` `lengths` fixnum->u8, `rcodes` fixnum->u16 (704-entry command
trees: 5.6 KB -> 1.4 KB rcodes + 5.6 KB -> 704 B lengths), plus
`+q0-cmd-map+` and `+cmd-symbol-table+` fixnum->u16 (5.6 KB -> 1.4 KB
together), with the three emit-path declares split into u16 (rcodes,
cmd-map) / u8 (lengths) and `w-emit-run` in src/bitio.lisp retyped.

Results (interleaved A/B, 4 runs each version, 7-trial medians per
run, same harness as the r87 record):

cell      r90 mean   u16 mean   delta
html q0    160.71     157.31    -2.1%   (nearly disjoint ranges)
html q5     51.49      51.30    -0.4%
html q9     17.65      17.46    -1.1%
json q0    191.22     188.86    -1.2%
source q0  298.42     292.00    -2.1%   (u16 max 296.89 < r90 min 296.47)
source q1  262.52     262.27    -0.1%
binary q9   24.21      24.21     0.0%
geomean             ->          -1.01%

Full 5-corpus x 5-level sweep: all 25 compressed sizes BIT-IDENTICAL
(types only change representation, never values), but the speed delta
is a measured regression, so the change is reverted.

Why it did not win (do not retry this shape): unlike the r89 decoder
LUT (whose 5.6 KB sat inside a much larger cold working set), these
encoder arrays are 16.4 KB total as fixnums and already fit L1 in the
emit loops — there was no cache pressure to relieve, and the u8/u16
`movzx` loads bought nothing over 8-byte loads (the two cells that did
move, html/source q0, are the write-fast-block-body hot path where the
per-literal lit-rc/lit-ln and w-emit-run loads are the innermost ops).
The lesson refines the r84 rule: "smaller footprint wins" applies only
when the table is large enough to actually miss cache; at L1-resident
sizes the typed-array form is neutral-to-slightly-negative.

## DISCOVERY in the same pass: build-code-lengths-a is DEAD CODE

`build-code-lengths-a` (the r81 array-based C port of
BrotliCreateHuffmanTree) is defined in src/encode.lisp but has NEVER
been called from any revision: `build-etree` still calls the cons-heavy
`build-code-lengths`, and `hg log -p` over the whole history shows no
call site was ever committed (the r81 record's "wired in build-etree"
claim did not match the tree). Tree building is ~5% of q0 time per the
r79 profile, and the C-shape builder is list-free — wiring it (after a
byte-identical old-vs-new sweep over random and real histograms, per
the r81 recipe) is the next encoder experiment.

## Wired 4 Nov 2026: build-code-lengths-a (rev 93) — the session's biggest win

Follow-up to the DISCOVERY above.  The equivalence harness (1000 freq
vectors: n in 18/64/256/704, maxlen 5/14/15, five distribution
shapes x 40 seeds) shows the two builders are NOT byte-identical:
309/1000 differ, all where the MAXLEN clamp engages (18/5 zipf 40/40,
704/15 zipf 40/40, 256/15 zipf 0/40 ...), because the old builder
clamps AFTER the fact (limit-lengths) while -a escalates the minimum
count (C's strategy).  Both emit valid codes; the sweep decides ratio:

size deltas (1 MiB, 5 corpora x q0,1,2,5,9): 24 of 25 cells shift,
16 by FEWER bytes; worst regression +13 B (json q0, +0.006%);
geomean ~1.000x.  150/150.

speed, interleaved 2 rounds x (baseline | wired), 7-trial medians:

cell      r92 mean   wired mean   delta
text q0   1335.80    1588.09     +18.9%   (disjoint ranges)
binary q0  135.02     149.54     +10.8%   (disjoint)
source q2  159.00     174.16      +9.5%   (disjoint)
source q0  288.08     304.03      +5.5%   (disjoint)
html q0    156.93     160.42      +2.2%   (disjoint)
json q0    193.91     198.01      +2.1%
html q5     52.84      53.83      +1.9%
geomean               ->         +7.1%

Mechanism: the 704-symbol command tree took 3169 us per call in the
old builder (O(n^2) REMOVE merges + STABLE-SORT) vs 14.5 us in the
array builder (222x); n=256: 429 us -> 4.8 us (85x).  Tree building
was the "trees ~5%" of q0 and a far larger share of q2-q5, where each
block builds a 704-symbol tree.

Design note: r81's shared global scratch (%huff-tc etc.) was replaced
with per-call arrays (the globals would have made COMPRESS
non-reentrant); allocation is noise at these sizes.  The old
build-code-lengths/limit-lengths are now unreferenced but retained as
the portable reference for future equivalence checks.

## Score matcher (rev 95): shipped at q5/q6/q10/q11, rejected at q7-q9

The r86 recipe finished and measured.  What landed in %lz77 (score
mode, driven by :score-p/:checks from quality-params):

* find-match-score: C's FindLongestMatch shape — prepared
  distance-cache candidates first (i < checks; byte-at-best-len
  probe; len >= 3 or len == 2 with i < 2; score minus the
  BackwardReferencePenaltyUsingLastDistance for i > 0), then the
  chain walk accepting by score (1920 + 135*len −
  30*floor(log2 dist)) instead of by length; kMinScore = 2020 gate.
* PrepareDistanceCache's ±1/2/3 cascade (4/10/16 entries), seeded
  {4, 11, 15, 16} like encode.c, rotated on every copy except a
  dc[0] repeat — mirroring the emit-side RB ring and short-code 0.
* Lazy gate next-score >= best + 175 with the 4-delay cap, carried
  forward as C's inner loop (the FIRST draft re-searched delayed
  positions and cost an extra search per delay — worth ~20%; the
  carry-forward version searches every position exactly once).
* Score mode emits C's 2/3-byte cache hits as copies (copy length
  codes start at 2); min-cop 2 there, min-match 4 elsewhere.

Measurement (interleaved sweep vs r94, 5 corpora, 1 MiB):

level | size geomean | speed geomean | verdict
q0-q4 | byte-identical (by design) | ~1.0 (layout noise ±5%)  | keep
q5    | −1.5% (5/5 smaller) | −12%          | SHIP (inside 5-15% envelope; q5 is the cap violator)
q6    | −1.2% (5/5 smaller) | −15%          | SHIP (inside envelope)
q7    | −1.2% (5/5 smaller) | −25%          | REJECT — outside envelope
q8    | (not swept)         | (same shape)  | REJECT with q7
q9    | −1.0%, json +477 B  | −25%          | REJECT — outside envelope, sizes already in cap
q10   | −0.7% (json +0.6%)  | −18%          | SHIP (17-20x headroom → 14-16x)
q11   | −0.9% (json +0.9%)  | −18%          | SHIP (same)

Why q7-q9 lose: counters (*fmn*/*fms*/*mln*, stripped) show search
counts are NOT higher (score: −3..−11%), but mlen scans are: binary
q9 163K → 386K (+137%), html q9 +26%, binary q5 +41%.  Cause: the
probe rejects on best-len, plain ratchets best-len to the greedy
max on every improvement, score mode only on score improvements — so
the bar stays low and probe-ok passes far more chain candidates to
the full u64 scan.  sb-sprof agrees: find-match-score self is 1.9x
find-match self.  The cost scales with chain length (chain 6 → −12%,
chain 24/128 → −25%), which is the level split above.

Ratio state after r95 (lisp/C): q5 1.03–1.11, q6 ~1.03–1.11, q7-q9
1.01–1.07, q10/q11 1.12–1.21 (json still the worst).  HTML q5 is
still 1.110 > the 1.10 cap — the next q5 ratio lever is BLOCK
SPLITTING: C has MIN_QUALITY_FOR_BLOCK_SPLIT=4 with lgblock=16, so C
q5 splits into sub-blocks with separate trees; our writer uses one
tree set per metablock.  That is the structural follow-up (alongside
the r86-noted q10/q11 context-modeling gap).

## Attempted 4 Nov (night): 64 KiB meta-block partitioning — measured, reverted

First, an INSTRUMENTED-DECODER discovery (temporary *mb-log* in
%decode-blocks, reverted): **C's one-shot encoder emits ONE meta-block
for the whole 1 MiB input at every quality** (q5/q7/q9/q11 all logged
a single 1048576-byte metablock).  ComputeLgBlock's 14/16/18 values
only chunk the STREAMING path (BrotliEncoderCompressStream input
blocks) — the bench's one-shot BrotliCompress does not chunk.  So C's
q5 edge is entirely INTRA-metablock: DecideOverLiteralContextModeling
(literal context modeling is on from quality >= 5: bigram-prefix
analysis -> ChooseContextMap) plus BrotliBuildMetaBlockGreedy (sub-
block splitting with block-switch commands), inside one meta-block.

Experiment: add :mb-size to quality-params (q5/q6 = 65536) and route
compress-entropy through the EXISTING partition-commands path (which
splits on input bytes, exactly metablock semantics), so q5/q6 emit 16
metablocks instead of 1 - histogram adaptation with zero new format
code.  Measured vs r95 (5 corpora, 1 MiB):

size q5 / q6: html -0.03% / -0.06% (THE CAP CASE: NEUTRAL),
json -1.0% / -1.0%, binary -1.8% / -1.7%, source +0.3% / +0.3%,
text +1.4% / +1.4%  -> geomean -0.24% (split, not a fix)
compression speed: -10% geomean (all 10 cells < 1.0)
OUR-decoder on our own q5/q6 streams: -22% to -61% (text q5 decode
3294 -> 1292 MiB/s) - 16x the per-metablock read-huff/build-huff
tree construction, which is invisible at 1 metablock/MiB but not at
16.  (Independent finding: our DECODER's build-huff is slow enough
that multi-metablock streams pay for it - a decode lever for any
future multi-block work, and for >16 MiB inputs.)

Reverted (tree back at r96).  The conclusion: html q5 does not need
smaller histograms, it needs C's two INTRA-metablock features.  Next
lever in order of expected ratio value:

1. LITERAL CONTEXT MODELING at q5+ (C: DecideOverLiteralContextModeling,
   bigram-prefix -> ChooseContextMap -> NTREESL in {1,2,3,6,10,13,...}):
   the decoder ALREADY reads context maps (it decodes C's streams), so
   this is encoder-writer work only - split the literal histogram by
   (p1,p2) context, write NPOSTFIX-style context map, per-context
   literal etrees, and track p1/p2 through plan-commands/emit.
   Estimate: 3-6% on html-like data -> html q5 1.110 under the cap.
2. GREEDY SUB-BLOCK SPLITTING (BrotliBuildMetaBlockGreedy + block-switch
   alphabet): bigger (new command alphabet in the writer + cluster
   algorithm), only after (1).

## Shipped 4 Nov (late): literal context modeling (rev 98) — the q5 cap is fixed

The (1) above, done.  All three of C's decision paths ported from
encode.c — and the key simplification discovered on the way: every
ChooseContextMap outcome uses a STATIC 64-entry map
(kStaticContextMapSimpleUTF8 / kStaticContextMapContinuation /
kStaticContextMapComplexUTF8), so NO clustering (cluster.c) is needed,
and the decoder already reads every piece of the format (cmapl over
64*nbl-l, READ-CONTEXT-MAP, per-context lit-trees, %lit-context with
mode 2 = UTF8 on +lut0+/+lut1+).  Encoder-only work:

* literal-contexts: complex-map path first (n >= 1 MiB, C's entropy
  gates, K=13), else bigram-prefix analysis -> K in {1,2,3} with the
  quality-dependent entropy[3] below q7;
* plan-commands: K*256 literal frequencies, per-literal (p1,p2) UTF8
  context using the decoder's own LUTs (guaranteed agreement);
* complex writer: context mode 2, NTREESL via write-nbltypes (inverse
  of READ-NBLTYPES), the64-entry map with RLEMAX=0/no-IMTF, K literal
  trees, per-literal tree selection (single-symbol context trees emit
  nothing, mirroring lit-single); K=1 keeps the byte-exact old path.

Measured vs r95 (interleaved sweeps,5 corpora x1 MiB):

level | html | json | text | source | binary | geomean | speed
q0-q2 | byte-identical (different writer)                      | ~1.0
q5    | -0.93% | +4 B | -1.97% | -1.64% | same | -0.9% | -4.2% geo
q6    | -0.76% | +6 B | -2.00% | -1.64% | same |        |
q7    | -0.39% |+19 B | -2.02% | -1.62% | same |        |
q9    | -0.24% |+22 B | -2.09% | -1.61% | same |        |
q10   | -0.18% |+15 B | -1.75% | -1.60% | same |        | ~1.0
q11   | -0.16% |+19 B | -1.75% | -1.60% | same |        | ~1.0

BINARY is byte-identical everywhere: its entropy gates pick K=1
exactly as C would.  JSON's +4..22 B is the map/tree overhead on
data with no context structure.

**HTML Q5: 1.110 -> 1.0999 - inside the 10% cap for the first time**
(193041 vs C 175500).  Remaining over-cap cells: none at q0-q9;
q10/q11 stay 1.12-1.20 (the context-modeling feature gap there is
now smaller: html 152965/132230 = 1.157 at q11).

Costs: compression -4.2% geomean at q5-q9 (the per-literal context
select C pays too); decode of OUR streams -5..-26% on context levels
(the single-lit-tree fast path no longer applies - C's streams always
paid this, and the dec-of-C column, i.e. decode of C's streams, is
unchanged).

Next: GREEDY SUB-BLOCK SPLITTING (2 above) for the rest of the q5+
gap (clustered sub-blocks + block-switch alphabet in the writer;
decoder already supports NBLTYPES>1, block lengths and switch codes).

## Shipped 4 Nov (late night): greedy block splitting (rev 100) — done

The (2) above, done for the command and distance categories.  Before
implementing, instrumented the DECODER to dump C's actual stream
structures (temporary *hdr-log*, reverted): **C q5/q9 emits NBLTYPES
L=1 / I=2-3 / D=9-12 with NTREESL=13, NTREESD=NBLTYPES-D** — no
literal splitting (contexts carry literals, as r98 assumed) and no
clustering (ntrees = ntypes).  That scoped the work to C's greedy
BlockSplitter (v1.0.9 metablock_inc.h, fetched from GitHub — the local
/tmp/opencode/brotli-c tree is version-mixed and does not contain it):

* split-block: per-category state machine — min-block 1024 (cmds) /
  512 (dists), thresholds 500.0 / 100.0, new-type iff both diffs >
  threshold and ntypes < 256, second-last merge iff diff1 < diff0-20,
  else merge-last with the growing target;
* header: NBLTYPES-I/D varints + (when >1) block-type tree over
  ntypes+2 (switch symbol = type+2; syms 0/1 unused) + block-length
  tree over 26 + first count — the exact READ-BLK-HEADER inverse;
* switches: writer decfs ileft/dleft exactly where blk-maybe-switch
  reads (I: every command; D: only distance-bearing commands =
  dcode >= 0 = C's cmd_prefix >= 128); lengths may overshoot the
  tail (harmless: a count that never reaches zero reads no switch);
* per-type cmd/dist histograms + trees, NTREESD = NBLTYPES-D with the
  identity 4-context distance map; NBLTYPES-L stays 1.
  Degraded (no split) output is byte-for-byte the old form.

Two real bugs caught by the validation harness (worth remembering):
1. TREE-BUILD ORDER: cmd-ets/dist-ets were let* bindings evaluated
   BEFORE the tally body filled the histograms — every split tree was
   built EMPTY (single-symbol-0), so the decoder read every distance
   as symbol 0 after the first switch.  The tally now runs before the
   trees (first let* = histograms + tally, second let* = trees).
2. LOOP DO-FORM SWALLOWING: in `(loop ... do (incf ...) (incf j0 ln))`
   the advance after DO but before the loop's closing paren becomes ANOTHER
   DO form — j0 grew by min-block PER SYMBOL (512 -> 262144), blocks
   1+ were never tallied, and the probes showed bi stuck at 0.  Both
   tally loops now close before the advance.  (Symptom signature:
   j0 = old-j0 + min-block*count; keeps appearing in :after-style
   traces.)

Debugging tools used (kept in /tmp/opencode): hdr-parse.lisp (field-by-
field stream header dump), trace-cmp.lisp (writer/decoder command
traces), the split-log push pattern — all stripped from the tree.

Verified: 150/150; repro matrix (5 datasets x q5,q6,q7,q9,q10,q11 x
64KB + bimodal 4KB) 0 failures.  Sizes vs r99 (interleaved sweeps):

level | html | json | text | source | binary | geomean
q0-q2 | byte-identical (different writer)
q5    | -0.47% | -1.11% | -0.27% | -0.16% | -1.62% | -0.73%
q6    | -0.53% | -1.15% | -0.27% | -0.17% | -1.62% | -0.75%
q7    | -0.77% | -1.38% | -0.41% | -0.30% | -1.53% | -0.88%
q9    | -1.07% | -1.74% | -0.48% | -0.33% | -1.57% | -1.04%
q10   | -1.08% | -1.51% | -0.30% | -0.28% | -1.67% | -0.97%
q11   | -1.24% | -1.58% | -0.30% | -0.24% | -1.71% | -1.01%

20/20 changed cells at q5-q9 SMALLER; 10/10 at q10/q11 smaller.
Headline ratios vs C (1 MiB, lgwin 22): **html q5 1.110 -> 1.095**
(first real cap headroom after r98's 1.0999); **json q9 1.018 ->
1.000 (169084 vs C 169076 — statistical parity)**; html q9 1.022;
html q11 151068/132230 = 1.143 (was 1.157).

Cost: compression -5..-12% at q5+ (splitter + extra trees + switch
codes — all C-parity work C pays too); decode of C streams unchanged
(dec-of-C ~1.0); decode of our own streams -12..-21% (per-command
block bookkeeping, also C-parity: C's streams always paid it).

Remaining known gaps (unchanged): q10/q11 context modeling depth
(html 151068/132230 = 1.143 at q11), BrotliOptimizeHistograms (C does
it at q>=4, we do not — easy tree-size win, untried), the HQ
clustered splitter for q10+ (we run the greedy one there; C runs
BrotliSplitBlock), and the q0/q1 one-pass encoder.

## Attempted 4 Nov (midnight): BrotliOptimizeHuffmanCountsForRle — measured neutral, not shipped

Ported C's entropy_encode.c count-massage (~150 lines, applied to all
four complex-writer tree groups: the K literal trees, per-type command
and distance trees; cold path, once per tree per meta-block) and
applied it where C gates it (q >= 4 — i.e. our complex writer only;
the trivial/fast writers keep byte-identical output).

Porting notes worth keeping:
* the `(256 * counts[i] - limit + streak_limit) >= 2 * streak_limit`
  test runs in C's uint32 arithmetic — the UNDERFLOW is deliberate (a
  count far below the local average wraps huge and must count as a
  stride break), so the Lisp port uses `(mod ... #x100000000)`; the
  three `256*s /3 + 420` limit updates wrap with `logand #xFFFFFFFF`.
* the early-outs (<16 nonzero overall, <5 nonzero after trimming,
  smallest <4 with >=6 zeros, <28 nonzero) mean it only ever fires on
  big/complex histograms.

Measured (150/150 pass, repro matrix 0 failures — correctness fine):
1 MiB, 5 corpora x q5/q6/q7/q9 — 19 changed cells, **net -4 bytes**
(json +52 worst = +0.008%/cell; source -33, binary -21, text -14) =
statistically zero.  64 KiB, 5 corpora x q5/q9 — net **+42 bytes**
(html +2+2, json +7+6, binary +30 at q9) = +0.04% WORSE.  Speed within
noise both sizes.

Conclusion: with OUR tree writer (build-code-lengths-a's count-limit
retry + write-complex-code/cl-lengths-rle) the count massage has
nothing left to win — C's tree-description saving comes paired with
ITS tree-STORE machinery (BrotliStoreHuffmanTree + DecideOverRleUse,
which chooses rle-for-zero vs rle-for-nonzero per tree).  The right
future move is porting that tree-store pair as a unit, not the count
massage alone; the ported function above (with the uint32 notes) is
the recipe to re-apply when that happens.  Reverted; tree clean at r101.

## Data point: r100's speed cost is inherent, not a Lisp pathology

Microbench: estimate-entropy over 704 counts = 8.0 us/call (~11 ns per
double log2, including the float boxing and the sum loop) — essentially
C's FastLog2 cost (C's table only accelerates values < 256; above that
it calls libm log2 exactly as we do).  The greedy splitter makes ~3
entropy calls per decision (2 combined + 1 current, each over the
alphabet) at 1024/512-symbol intervals ≈ 1.7 ms per 1 MiB html q5 —
which accounts for roughly half of r100's measured -5..-12%; the rest
is the extra per-type trees and switch writes, all of it C-parity work
C itself pays.  No cheap reclaim available; a FastLog2-style table
would touch only the <256 counts (~1% of q5 total) — not worth the
code.  (Also: C's splitter entropy inputs go through the same math, so
decisions stay C-aligned only if we keep the double logs.)

## Rev 104: q6 unchained fix — NO swept cell exceeds the cap now

Two findings in one pass:

1. DISTANCE PARAMS (npostfix/ndirect): C's BrotliBuildMetaBlock
   searches them per meta-block at q>=4; we hardcode (0,0).  Instead
   of building the port, generated C's own streams for 5 corpora x
   q4/5/7/9/11 and parsed the headers (temporary decoder instrumentation
   reused): **C itself picks (0,0) on every corpus at q4-q9** — we are
   already C-exact exactly where the cap battles are.  Only q11 picks
   non-zero (binary postfix=3/direct=8, source 2/4, json 0/3) — a small
   HQ-path parity gap to bundle with the zopfli/HQ-splitter work, not a
   standalone build.  (The general port recipe would be: generalize
   encode-distance via C's PrefixEncodeCopyDistance, dynamic dist
   alphabet (+16 ndirect (ash 48 npostfix)) through plan-commands and
   both dist-tree writers; our DECODER already reads arbitrary
   npostfix/ndirect — the only ready-made part.)

2. q6 chain: the chain-to-C-bucket ratio was q5 6/16, q6 8/32, q7
   24/64 — q6 by far the most under-chained (0.25x), and html q6 was
   the ONLY remaining cap violation (186493 vs C 166377 = 1.121).
   max-chain 8 -> 16 (mirrors C's effective depth): all five corpora
   smaller (html -6.19% -> **1.053**, source -1.45%, json -1.08%,
   text -0.62%, binary -0.33%), q5/q7 byte-identical, q6 speed
   -9..-15% (ratio-first trade).  150/150 + repro clean.

MILESTONE (CORRECTED — the r104 commit message overclaimed): after
r104 no cell at **q0-q9** exceeds the 1.10 cap (5 corpora swept at
q0,1,2,5,6,7,9; worst html q5 1.095, source/binary q2 ~1.09).  q10/q11
STILL have 7 violations — html10 1.108 / html11 1.142, json10 1.124 /
json11 1.183, text10 1.148 / text11 1.182, binary11 1.135 (source
1.074/1.095 and binary10 1.097 are under) — the recorded zopfli +
HQ-clustered-splitter feature gap, NOT tuning-fixable.

Optional follow-up (not taken — in cap and speed is scarce): q5 chain
6 -> ~10 for headroom on html q5's thin 1.095 margin.

## Attempted 3 Nov 2026: the local-state command loop (step 1 above)

An implementation of the fast command loop as a separate
`%decode-simple-meta-block` with the reservoir kept in loop locals was
written and fills/compiles, but SBCL 2.6.9 compiles three of the
`macrolet`-expanded per-symbol readers (`GET-BITS`/`GET-SYMBOL`) into out-of-line
function calls (`CALL CL-BROTLI.LISP::GET-SYMBOL in the disassembly) even
though the macrolet is lexically in scope; at runtime this signals
UNDEFINED-FUNCTION (the macrolet never becomes a function). Reproduced with
both the original and a renamed/docstring-stripped variant. The same macrolet
pattern works in a minimal standalone repro, so the trigger is
size/shadowing-sensitive — worth a reduced reproducer filed against SBCL.

For the next iteration, avoid `macrolet` here entirely and use this
codebase's proven single-expansion pattern (the one %MATCH-LEN-SAP-FRAG
relies on): three top-level inline readers `%RSYM-CMD`/`%RSYM-DIST`/`%
RSYM-CMD`-shaped (one per call site — command/module/literal-tree/extra bits),
each taking `(r tree acc nbits p)` and returning
`(values symbol acc nbits p)`, with the end-of-stream fallback inside the
reader itself. The WIP register/reader skeleton is preserved at
`/tmp/opencode/decompress-fastloop.wip` (not in the tree) as a starting point.

## Decoder: the 0.30–0.48x band, cell by cell

`sb-sprof` flat profile, decoding the C q0 HTML stream (1 MiB, 29k commands):

| component                            | share of decode |
|---|---:|
| `DECODE-COMPRESSED-META-BLOCK` (command loop; the inlined `READ-HUFF` for command/distance symbols + extra-bit reads) | 52.4% |
| `OUT-COPY-PREALLOCATED` + `UB8-BASH-COPY`                       | ~20%  |
| `%DECODE-LIT-RUN`                                               | 13.6% |
| header parse, `%GROW`, end `SUBSEQ` etc.                        | ~8%   |

And the macro fact that motivates the order of work: **lisp decode throughput
is near-constant (~208–337 MiB/s on HTML) from q0 to q11, while C scales
565 → 810 MiB/s** on the same streams. Per-symbol overhead dominates ours.

Why, from the C source and the SBCL disassembly:

1. **C's command loop is one flat body with everything in registers.**
   `ReadCommandInternal` (decode.c:1920) reads the command symbol from the
   8-bit-multi-level table, computes lengths/distances with plain shifts, and
   `val_`/`bit_pos_` never leave registers between commands. Our command loop
   keeps `acc`/`nbits`/`pos` in the `BRD` struct and does 2–4 struct
   round-trips per command, plus `blk-maybe-switch`/ring work. The literal
   side already got the same medicine (`%DECODE-LIT-RUN`, only ~14% of decode
   now); the command side has not.
2. **The `bits-available` guard compiles to generic arithmetic.**
   `(>= (bits-available r) table-bits)` inside the inlined `READ-HUFF`
   produces out-of-line `GENERIC-+`/`BIGNUM-TO-RSI` paths near the guards
   (visible in the 2.6.9 disassembly: 50 out-of-line arithmetic calls in
   `DECODE-COMPRESSED-META-BLOCK`). The flat profile shows them as ~0.5%,
   i.e. cheap when hit cold, but the guard math is on every symbol's fast
   path. C has no such check — its speculative refill simply fails near EOF
   and `BrotliUnsafe32BitsIx0ForPadding`/safe mode handles the tail.
3. **One out-of-line `CALL OUT-COPY-PREALLOCATED` remains in the hot loop,
   and `%COPY-TINY-MATCH` is a 16-way `CASE` dispatch** (up to 15 unrolled
   SETF sites, ~1 KB of code) for the most common short non-overlapping
   copies. C's `BrotliCopy` does fixed unaligned 64-bit loads/stores chosen by
   distance. For HTML/JSON-gray data, most matches are 2–16 bytes; that
   dispatch is part of the 20% copy share.
4. **Refill through the `+wide-masks+` table** costs an extra load + aref +
   mask per refill; C needs no mask because `val_` is 64-bit and the unused
   high bits are disposable garbage until `bit_pos_`累计 says otherwise.
5. Header parse, `%GROW`, measure-visible `SUBSEQ` are ~8% and already
   mostly exact-reserved.

Decoder plan (biggest first, all ratio-neutral):

* **Local-state command loop.** Same transformation as `%DECODE-LIT-RUN`:
  reservoir/bit-count/pos in loop locals, one refill macro, only the tree
  pointers and ring writes touch memory. The two `READ-HUFF` calls per
  command become inline table lookups on locals. Expected: closes a third to
  half of the decode gap (0.43x geomean band → ~0.6x).
* **Type the guards.** After (a), prove `<24` for every read count (the RFC
  maxima are static) and drop `bits-available` from the fast path: the
  meta-block end is validated by `target`, not by end-of-input — the slow
  path only matters within 16 bits of the last meta-block's end.
* **Copy by distance.** Replace the `CASE` with: distance ≥ 16 and len ≤ 16 ⇒
  two unaligned `sap-ref-64` loads/stores (needs 8+8 output slack, the writer
  already over-reserves; the decoder reserves target exactly, so copy with
  `fp+16 ≤ end`), else the current unrolled/`REPLACE` paths. Keep `REPLACE`
  (vectorized memcpy) for long copies — the SAP-copy experiment that lost
  matches the C code's `BrotliCopy` only for overlapping cases.
* Keep the 10-bit root table (better hit rate than C's 8-bit) and the u16
  packed entries.

## Encoder q0/q1 (fast-fragment): structural + codegen

Stage measurement, HTML q0, matcher alone vs full compress:

* matcher-only: **313 MiB/s** (single pass building command vector + fused
  histograms)
* full q0: **166–181 MiB/s** → tree build + second emission pass ≈ 47% of q0
* C q0 one-pass total: **~500 MiB/s**

So C does the entire pipeline in one pass ~1.6x faster than our matcher alone.
Two legs to close:

1. **Port the one-pass writer (documented, still not done):** C
   `BuildAndStoreLiteralPrefixCode` builds the literal tree from the
   *pre-LZ77 input histogram* (exact under 32 KiB, else every 29th byte,
   `+1` and weight-3 on the first 11 hits, max depth 8), the command/distance
   code is the fixed 64-symbol `kDefaultCommandCode` (no run-time Huffman at
   all), and `EmitLiterals`/`StoreCommand` write to the stream during the
   scan. `ShouldMergeBlock` merges fragments into one meta-block so the trees
   are written once per block, not per command. Our version runs: full match
   pass (+fused histograms) → 3 × `BUILD-CODE-LENGTHS` (list-based Huffman
   construction, `REMOVE`/`CONS` per merge, `STABLE-SORT` with a generic
   comparator for length reassignment — ~5–8% of q0) → full emission pass
   (~38% self). The ceiling without touching the matcher is ~47–55% gain ⇒
   q0/q1 ~0.6–0.8x of C. With the matcher at 2.2–2.5x C per position, the
   matcher leg below is required for parity.
2. **Matcher codegen.** The disassembly of the trawl loop shows, per
   scanned position, ~2.2–2.5x the instruction count of C:
   * the hash is a u32 load → *fixnum tag* (`SHL 1`) → 64-bit `IMUL` → mask →
     untag-shift chain (7 instructions) where C does unaligned 64-bit load,
     `shl 24`, one `imul`, shift (4). Making `%HASHF-SAP` an
     `(unsigned-byte 64)` pipeline (load64, logand/ash, one final tag for the
     table index) removes the tag round-trip entirely;
   * every position/distance/length is a tagged fixnum: `SAR`/`SHL`+/`AND -2`
     on each use, and the loop body spills 10+ live values through RBP slots
     (`[RBP-40]`…`[RBP-112]` reloads per iteration). Fewer live values in the
     trawl (e.g. emit histograms out of line again, or slim the command
     record) is cheaper than a VOP here;
   * `%MATCH-LEN-SAP` (VOP, kept) and the unrolled copy tail are fine.

## Encoder q2–q9 (chain/lazy): matcher-bound, same codegen disease

chain-only vs full q2 HTML: 156 vs 96 MiB/s — the emitter/tree work is only
~38% of q2; the chain matcher is the floor. It shares the fragment matcher's
fixnum-tag arithmetic and spill profile; the doc'd candidate-bucket (H5/H6)
attempts matched speed but not ratio because C's structure is only correct
with the full scoring/last-distance-cache/candidate-budget design. The
rational next steps, in ratio-safe order:

* u64-ify the chain probe (`probe-ok` still loads u32s and compares tagged).
* only after that, re-evaulate the standalone bucket matcher with C's 4/10/16
  distance cache (the earlier attempt predates the last-distance seeding that
  now buys real ratio).

Ratios: q2–q5 currently land 1.09–1.20x C on literal-heavy corpora, above the
10% cap the README records (those measurements predate the Nov 3 edits —
re-verify before citing). q7–q9 stay ≥ C; q10/q11 are 17–20x C.

## Bottom line

* Decode: **unify all per-symbol paths on loop-local reservoir state**. That
  is the same trick already proven on `%DECODE-LIT-RUN` and on the writer's
  `W-EMIT-RUN`; it is the only big consistent lever left and it is
  ratio-neutral.
* Encode q0/q1: **one-pass emission** (pre-LZ77 literal histogram + fixed
  64-command alphabet + write-during-scan) is the structural remainder; a
  u64 hash and slimmer trawl state is the codegen remainder.
* Encode q2–q9: after u64 probes, decide the bucket-matcher question with
  ratio guards, not before.

Estimated reachable targets on this host (same ratio as today):
decode 0.43x → ~0.6x geomean; q0/q1 0.33–0.45x → ~0.55–0.7x on literal-heavy
data; q2–q6 stay ~1.0x with the cap restored; q7+/q10/q11 unchanged.

## Attempted 4 Nov (later): the C-parity score matcher inside %lz77 —
## carried the whole way up to the last-distance cascade, put aside

The full patch chain (score constants + base 1920, per-quality
`num-checks` 4/10/16, `%prepare-dist-cands` mirroring C's
PrepareDistanceCache, the score-based best-len/distance selection in
`find-match` with `%bref-score`/`%bref-penalty` (C hash.h
BackwardReferenceScore/PenaltyUsingLastDistance), a >=175 lazy rule and
the kMinScore baseline accept) reached the last-mile where the correct
code needs find-match's whole signature change (accepting the
candidate-prior array and returning best-score) and the emit-normal/lazy
interplay rewritten as one shape. The draft in this session had the
reference list wrong in two places; the working tree is reverted to the
known-good r85 (no code change).

To finish the score matcher in one pass next session:
1. change `find-match` to take `(pos h checks)` and return
   `(values len dist score)` with best-len starting at 0 and
   best-score at (+ 1920 100) (kMinScore);
2. keep the non-scoreCb path byte-exact (q0-q4: score-p nil,
   checks 1 — the last-distance candidate only);
3. fill the prior cascade through `%prepare-dist-cands` at every
   find-match call (the dc array's slots 4..9/10..15 mirror C);
4. apply C's per-index penalty ONLY for id >= 1 candidates with the
   use-last-distance formula for id 0: (+ 1920 15 (* 135 len));
5. rewrite the lazy gate as (>= next-score (+ best-score 175)) with the
   4-delay cap and the accept gate (sr.score > kMinScore);
6. measure with the level sweep AND accept the 5-15% chain speed
   regression documented in the notes as the trade for sizes 1.03-1.13
   -> closer to C; the recorded q2 JSON delta was -6.7%, HTML -2.3%,
   BINARY -3.0% previously (before the chain VOP + 64-bit hash work
   which restored part of that speed).


## Rev 89: the command LUTs to u16 — +1.7–3% decode on the dense cells

The four 704-slot decode LUTs (`+cmd-ilen-base+/-bits+`,
`+cmd-clen-base+/-bits+`) were fixnum arrays (8 bytes each → 5.6 KB for
the four).  The command loop reads all four tables per command, so they
hold a working set near L1D's sweet boundary.  (unsigned-byte 16)
halves the footprint (2.8 KB) and fits all values (the largest base is
22594, the widths 0..24).  Measured on C html streams (5 runs × 200
decodes of the same stream for each q): q0 +1.7%, q2 +3.0%, q9 +1.7%.
Sizes bit-identical; 150/150 checks pass.

That is the whole remaining "cheap instruction a change" crop reachable
without a VOP: the per-symbol emit (`wbits-raw-pm`), the per-symbol
decode (u16 LUT) and the per-symbol table (`lit-pc` tried, reverted) are
all at their design-level floors now — the remaining gaps are for a
VOP pass, not arithmetic edits.

## Rev 87: the pre-masked writer (%wbits-raw-pm) — +2-3% on q0

A different answer to the instruction-count question: instead of passing
more state through the per-literal emit, REMOVE per-literal instructions.
The writer's width-exact call sites (reversed prefix codes, the
insert/copy extra values from the length-code tables) went through a
`logand v (aref +masks+ n)` + table load per emit even though their
values were already exact; %wbits-raw-pm keeps %wbits-raw's contract and
just skips the two ops.  The special-distance paths (which can carry
negative 2-bit offsets) keep the masking via %wbits-raw.

HTML q0 full-compress median across 7 samples (3 runs): 160-163 -> 162-167
MiB/s.  Sizes are bit-identical.  The lesson generalizes: the emit path's
remaining cost is per-instruction ARithmetic, not struct traffic, so
"fewer ops" measurably beats "more inlined state" at the same boundary.


## Rev 92: q0 one-pass (C BrotliCompressFragmentFast port) — parity gate passed

Goal per the revised rule (parity ratio vs C, never slower): make q0
one-pass without giving up ratio parity.  Three findings, one ship.

**Port verification.**  The one-pass fragment (`%lz77-fragment &optional w`)
builds trees before the scan and emits commands directly into the writer.
Checked against `compress_fragment.c`: `+q0-seed-cmd+`+`+q0-seed-dist+`
byte-equal `kCmdHistoSeed[128]` (programmatic diff); `%hashf-sap` equals
C's `(load64(p) << 24) * 0x1E35A7BD >> (64-table_bits)` (the 40-bit mask
is exactly the mod-2^64 truncation); `prefix-match` is C's `IsMatch`
(4+1 bytes for k=5); the q0-insert/copy/distance symbol formulas match
EmitInsertLen/EmitCopyLen/EmitDistance/EmitCopyLenLastDistance case by
case.

**Attempt 1 — single block, maxbits 8 (rejected, then rescued).**  The
first port built the sampled literal tree with `build-etree ... 8`,
believed to mirror C's `BrotliBuildAndStoreHuffmanTreeFast(..., max_bits=8)`.
Result: html 316559 (1.126 of C), json 277425 (1.121) — parity FAILED,
speed only +2.7% over two-pass.

**Attempt 2 — C-style chunking (96 KiB first, then 64 KiB, per-block
sampled literal trees) — measured, reverted.**  Hypothesis: C's edge was
local literal trees.  Result REFUTED: ratio slightly worse (316559 ->
317885 html) and speed collapsed: html 167 -> 129 MiB/s (-21%), text
1314 -> 380 MiB/s (-72%).  Cause measured in isolation:
`build-etree(lit,256)` costs ~96 us, sample+etree+write-etree per block
~144 us x 16 blocks ~= 2.3 ms, which is exactly the regression.
Bugs found and fixed while building it (all reverted with the chunk
loop): (a) the block loop never advanced `bstart` -> infinite
re-compression, 512 MB heap exhaustion on the first 1 MiB bench; (b) the
cand2 match-length site still capped at `n` instead of `mcap` -> copies
crossing the block end, "meta-block produced 65567, expected 65536"
(+31 bytes on a 64 KiB block); (c) `%sample-lit-histogram` arity; (d)
`:one-pass t` passed where the writer `w` was expected -> struct access
on T, memory fault at 0x51f9 in %LZ77-FRAGMENT.

**Ground truth via hdr-parse (both streams dumped).**  C compresses the
ENTIRE 1 MiB input as ONE metablock (MLEN=1048576, NBLTYPES 1/1/1,
NPOSTFIX/NDIRECT 0/0, seed command tree, one dist tree): ShouldMergeBlock
merges until 1 MB.  Its literal tree is the first-96 KiB raw sample;
command stats accumulate but are never re-emitted.  Header cost is
~80-94 bytes on both sides — the whole +35 KB gap was the body.

**The real bug — `max_bits = 8` is not a depth cap.**  Reading
`BrotliBuildAndStoreHuffmanTreeFast`: the parameter is only the symbol
field width of the <=4-symbol simple-code path; the general path builds
unconstrained Huffman.  C's html literal tree reaches depth 12 and its
cost on the identical histogram equals our `build-etree(hist, 256, 15)`
EXACTLY (3.1578 KiB both, avg depth 10.93 both), while the depth-8 build
costs 4.49 KiB on the same histogram: +42% literal coding cost (+53% on
1 MiB scope ~= +46 KB — the entire gap and then some).  Two-pass had it
right all along (maxbits 15).

**Ship — single block + maxbits 15.**  q0 lisp/C: html 1.074 (302058),
json 1.020 (252577), text 0.382 (15478), source 0.455 (128604), binary
1.049 (371875) — every cell <= 1.10.  q1-q9 byte-identical to the
previous run; q0 speed within noise of the one-pass baseline (html 0.33x,
json 0.31x, binary 0.32x of C core; text 6.7x and source 1.37x FASTER
than C).  150/150 tests, repro-split 0 failures, levels 10/11 unchanged
(the zopfli/HQ ratio gap remains open, q10 1.11-1.12, q11 1.14-1.18 at
3.4-6.6x C speed).  Coverage study for a per-input one-pass/two-pass
decider: match coverage is uniform (html 90.2, json 90.0, text 89.5,
source 87.8, binary 72.6%) with no separating signal — shipped
always-one-pass, no decider.  q0 speed remains 0.31-0.33x of C core on
html/json/binary: the known per-position SBCL-vs-GCC gap, unchanged by
this work.

## Rev 93: q10/11 gap decomposition (structure dumps + chain sweep + entropy ceilings)

C's q10/q11 machinery (quality.h): hasher type 10 = to_binary_tree,
ZOPFLIFICATION_QUALITY=10 / HQ_ZOPFLIFICATION_QUALITY=11 (MaxZopfliLen
150/325, MaxZopfliCandidates 1/5), MIN_QUALITY_FOR_HQ_BLOCK_SPLITTING=10,
MIN_QUALITY_FOR_HQ_CONTEXT_MODELING=7, nonzero distance params from q4
(C actually uses them only at q10+: json/binary q10 = NPOSTFIX 3,
NDIRECT 32).

**Header structure dumps (first metablock, both streams, q9/10/11 x five
corpora).**  Our q10/q11 structure is byte-for-byte the same shape as our
q9 (NBLTYPES-L=1, TL=13, cmapL=64, NP/ND=0/0) - there is NO HQ
transition in our encoder; the quality params only deepen the chain.
C at q10+: NBLTYPES-L 2-23 (literal block splits everywhere), cmapL =
64 x NBLTYPES-L clustered into TL=4-71 trees, CM=3 on binary (we emit 0),
HQ insert splitting (I-ranges 30-3525 vs our single range), and sometimes
NPOSTFIX/NDIRECT != 0.  At q9 C and we already match shape (TL=13,
cmapL=64 on html/json) - that is why q9 passes.

**E1 chain-depth sweep (q10/11, all corpora, roundtrip-checked).**  Chain
256->2048: html q10 153572->148653 (lisp/C 1.108->1.072, 7.8->2.6 MiB/s,
still 1.14x C core); saturates by 8192 (148488).  html q11 151068->
148653 (1.142->1.124, still failing).  json barely moves (1.124->1.114 /
1.183->1.178), text and binary are completely insensitive (text 11463 at
every depth; binary 285263->285441, slightly WORSE).  Distance ring
depth is not json/text/binary's problem.

**E2 entropy ceilings (fixed parse, optimal-Huffman costs, q10).**
Literal stream under splitting+clustering vs current (1 block, 64->K
cmap): html -2.9%, json -3.0%, text -15.3%, binary -9.3% (split4,
64 independent trees per segment).  64 unclustered single-block alone:
1.7/1.3/10.1/6.3%.  Distance params (3,32)/(3,8)/(0,32) vs (0,0):
html -250 bits, json -1527, text -112, binary -3526 - i.e. ~0%: the
"nonzero distance params" item from earlier records is measured and
DROPPED.  Also notable: at q10 with dict the parse reaches ~95-96%
coverage on html/json, so literals are only ~21-34 KB of the stream and
cmd+dist bits dominate; on binary K=0... K=1 and NO contexts at all
(CM=0 vs C's CM=3, TL=1 vs C's TL=29-71) and literals are 156 KB of
285 KB - hence the 14.5 KB ceiling.

**Cell-by-cell budget to parity (<=1.10 of C), after E1 chain 2048 + E2
literal splitting:** binary q11 fixed by splitting alone (285258 - 14476
= 270782 <= 276514, tree-description overhead fits); text q10/11 nearly
fixed (~0.3-0.5 KB residual); html q10 already passes; html q11 residual
-2.4 KB, json q10 -1.4 KB, json q11 -10.4 KB = PARSE (C's binary-tree +
zopfli chain expansion).  Build order: (1) literal block splitting +
per-block 64-context clustering at q10/11 (entropy-side, precedented by
r98/r100), (2) HQ parse (binary-tree/zopfli) for the residual.

## Rev 94: E3 literal block splitting + clustering prototype - REFUTED, pivot to HQ parse

Prototype (standalone, not in the tree): split-block on the
(ctx64<<8|sym) sequence (alphabet 16384) + per-type similarity-path
agglomerative clustering of the 64 context histograms, full cost with
realistic overhead (+256 bits/tree for the description, +4 bits/cell
map, +40 bits/switch).

split-block itself is fast (0-32 ms even on 166K binary literals) and
agrees with C's shape (text -> 2 blocks like C, binary -> 41+ types).
But the COST results kill the plan that E2's ceilings suggested:

  corpus  flat(K from r98)  best split+cluster (+overhead)  verdict
  html    170004            172001 (3 blocks, 11 trees)     worse
  json    137052            136979 (3 blocks, 4 trees)      -73 bits
  text     23893            28076 (fallback to flat wins)   worse
  binary 1248695           1227592 (41 blocks, 80 trees)    -2638 bytes

Root cause: E2 measured Huffman capacity only.  Per-segment trees cost
~256 bits each to describe, so the -9.3% (binary) / -15.3% (text) raw
ceilings collapse to ~-2% / ~0% after overhead.  Splitting into MANY
blocks (min 512) is far worse still (overhead explosion).  Text's C
parity gap is therefore also parse-bound, not entropy-bound.

Consequences: (a) the literal-block-splitting writer surgery is DROPPED
(it fixes no failing cell by itself - binary q11 needs -8744 bytes,
splitting gives ~-2600); (b) every remaining q10/11 cell (html q11
-2.4KB, json q10 -1.4KB, json q11 -10.4KB, text -0.5KB, binary q11
-6.1KB) is a PARSE gap = C's to_binary_tree hasher + zopfli chain
expansion.  Next campaign item: the HQ matcher.

## Rev 95: q10/11 H10 binary-tree matcher (C hash_to_binary_tree port) - speed gate passed, 4/10 ratio

Shipped an optional binary-tree match source for q10/11 (quality-params
:bt 16/64 = the short-backward scan size): BT-HASH (C HashBytes: low 32
bits of load32*kHashMul32 >> 15, 17-bit buckets), BT-DO (C
FindAllMatches: the short-backward scan then StoreAndFindMatches -
lexicographic BST re-rooted per position, forest 2 slots/position,
depth 64, break at len >= min(max-length, 128), insertion watermark so
each position enters the tree exactly once, result cache for the legacy
lazy re-dispatch), BT-SCORE (distance-cache candidates via the extracted
CACHE-SCAN + tree candidates under the same 1920+135*len-30*ilog2 score
the chain uses).  Dispatch is at the three find-match call sites; the
chain path is fully inert when BT is off - q0-q9 verified bit-identical
to r108 across all five corpora.

Bugs found and fixed while validating (each measured):

1. BT-HASH label was missing from the region rewrite - UNDEFINED-FUNCTION
   at test time (148/150 -> fixed).
2. The tree walk called MLEN with swapped arguments (current first,
   candidate second).  %MATCH-LEN-SAP's contract is A < B with bound
   n-B; the swap made the bound n-prev-clen (over-permissive) AND broke
   the A+MAXL<N safety precondition (OOB 8-byte reads).  Symptom: ramp
   decode "meta-block produced 1048577, expected 1048576" (+1 copy byte,
   first difference one byte in a 352-byte stream).  Fixed by swapping
   to candidate-first.
3. Store scans were UNBOUNDED: C's Store/StoreRange pass
   MAX_TREE_COMP_LENGTH (128) to StoreAndFindMatches, capping both the
   scan limit and the break; our interior stores scanned up to n-pos per
   walk level.  On long-repeat data (text/source) with dense interior
   stores this was a 50x blowup: text/source q10/11 at 0.02-0.06x of C
   speed, sb-sprof 99.9% self-time in BT-DO.  Fix: max-len = min(128,
   n-pos) for stores, scan end = pos+max-len via new MLEN2 label (search
   path keeps the block remainder, like C's FindAllMatches callers).
   Result: text q10 3.00x / q11 2.40x C core, source 1.60x / 3.91x,
   sizes unchanged (store scans cannot change found matches - break
   happens before any capped length could steer the descent).
4. Selection floor: BT candidates required score-only acceptance, which
   admitted the short backward scan's 2-3 byte copies; the chain walk
   requires len >= 4.  Restoring the >=4 floor: html q11 1.147->1.138,
   text 1.161->1.150, json 1.203->1.192.

**E5 - chain+tree candidate union (measured, reverted).**  Since
argmax-over-union >= argmax-over-either, the chain was kept active
alongside BT (ins does both; BT-SCORE over find-match-score then the
tree).  At chain 256: only source improved (q10 1.070->1.066, q11
1.095->1.087); html/json/binary sizes IDENTICAL (chain candidates never
win the score contest) while speed fell 2.81x->1.66x (html).  A deeper
probe via %compress-bytes (chain 2048/8192 in the union) changed sizes
by 0-25 bytes anywhere - and dropped html/json BELOW C speed (0.79-0.89x
C core), violating the never-slower rule.  Conclusion: BT candidates
dominate the score on this workload; the chain adds cost without
candidates.  Union reverted; shipped state is BT-only (chain inert at
q10/11).

**Final gates (5 corpora x q10/11, 1 MiB, median-of-3):**
  speed: 10/10 PASS (1.57x-11.23x C core; was 3.3-12.8x with chain-only
  on the passing cells, and the point of the port is the ratio search
  quality, not speed)
  ratio <= 1.10: 4/10 PASS - html q10 1.085, source q10 1.066 /
  q11 1.087, binary q10 1.076 (r110 chain was 3/10: html q10 was 1.108,
  binary q10 1.097).  Failing: html q11 1.138, json 1.127/1.192,
  text 1.150/1.183, binary q11 1.114.  json/text moved +0.2..+0.9%
  vs the chain baseline (all four already failing parity; the current
  rule is parity-vs-C, not own-ratio, so recorded rather than blocked).

**Why BT alone cannot close the rest:** C's q11 output differs from its
q10 (html -4.6%) via MaxZopfliLen 325 vs 150 and MaxZopfliCandidates
5 vs 1; OUR q11 currently produces byte-identical output to q10 on
html/json/text/binary (only bt-short 64 vs 16 differs, which changes
nothing here).  The remaining gap (json/text, and all of q11) is C's
zopfli cost-model DP (ZopfliCostModel/chain expansion in
backward_references_hq.c), which selects insert/copy splits by actual
entropy cost instead of the fixed linear score - next workstream.

**References (as suggested):** RFC 7932 section 4 verified our
hand-inverted NPOSTFIX/NDIRECT formulas verbatim (ndistbits = 1 +
((dcode-NDIRECT-16) >> (NPOSTFIX+1)), hcode/lcode split, distance =
((offset+dextra)<<NPOSTFIX)+lcode+NDIRECT+1, direct symbols 16..15+
NDIRECT = distances 1..NDIRECT, ring {16,15,11,4} not reset at
metablock boundaries, distance 0 does not push); its context-ID tables
(sect. 7.1) are the next cross-check target for +lut0/+lut1.
BrotliHaxe (dominikhlbg) is a deliberately 1:1 hand port whose
src/encode/backward_references holds readable ZopfliNode /
ZopfliCostModel / StartPosQueue files - useful for the DP phase - but
its hash folder only has the longest-match hashers (it predates H10),
so it cannot cross-check this port; its README benchmark table is not
relevant to this campaign.

Validation: 150/150 tests, repro-split clean, q0-q9 bit-identical to
r108, roundtrip-checked every measurement script.

## Rev 112: q10/11 zopfli cost-model DP (C backward_references_hq port) — ratio 7/10, speed 3/10

The score matcher (r111) could not close the remaining ratio cells
(json/text/html-q11/binary-q11): its fixed linear score cannot see
insert/copy entropy.  This session ports C's zopfli DP wholesale:

**Architecture (now in %lz77, active iff BT):**
- Cost model: `zopfli-analytic-model` = C SetFromLiteralCosts —
  `estimate-literal-costs` (C literal_cost.c: mostly-utf8 gate,
  DecideMultiByteStatsLevel, sliding window 495 (utf8) / 2000 (plain),
  prologue bump) prefix-summed, plus analytic cmd/dist costs
  log2(11+i)/log2(20+i).  `fast-log2` mirrors C's FastLog2 (256-entry
  table below 256, libm above).
- Node state as packed fixnum arrays (zlen/zins/zdist/zsc/znext/zdict/
  zcostf), StartPosQueue as `zpq` (8-slot costdiff-sorted ring + per-slot
  4-distance cache), `z-update` = C UpdateNodes (queue entry k, 16
  short-code candidates with continuation prefilter, match candidates
  with C's `len` carry-across-matches, dict candidates), `z-eval` =
  EvaluateNode, `z-minlen` = ComputeMinimumCopyLength, skip/long-copy
  logic = C's BROTLI_LONG_COPY_QUICK_STEP + StoreRangeH10 emulation,
  backward/forward walks = ComputeShortestPathFromNodes/CreateCommands.
  Parameters verified against quality.h: q10 = MaxZopfliLen 150 /
  MaxZopfliCandidates 1, q11 = 325 / 5 (bt 16/64 map onto these).
- Dictionary: `dict-matches-at` mirrors C FindAllStaticDictionaryMatches
  for our length-preserving transform set — one candidate PER WORD
  LENGTH >= max(4, best_len+1) (C appends one match per length; the old
  code only ever tried the single longest word, and only at len >= 9).
  Index rebuilt as a 2^16 direct-mapped bucket array (C
  dictionary->buckets[Hash15] style) replacing the EQL hash-table.

**Root causes found while debugging (all measured):**
1. **Content corruption (n>=64K, both decoders wrong)**: `z-iterate`
   pushed DICTP as integer 0/1 but `plan-commands`/`split-command-at`
   test `(or dictp ...)` — 0 is truthy in Lisp, so the distance ring was
   NEVER pushed; short codes decoded against the stale initial ring
   {16,15,11,4}.  Symptom: every command individually consistent (DCMD
   probe 0 hits) yet streams decoded to wrong bytes at n>=65536, and
   "dictionary copy length 2 out of range" at 1 MiB (dist>pos against a
   decoder whose ring had real distances).  Fix: push `(and (plusp
   dictp) t)`.
2. **All-literals DP (ramp 722609 vs 352)**: zq-push used `~(incf idx)`
   where C uses `~(idx++)` — push and zq-at disagreed by one slot, rank-0
   read an empty slot with cost=inf, min-len blew up, no candidate ever
   qualified.
3. **Heap death / unbounded command walk**: forward walk read
   `znext[pos]` (post-insert) instead of C's `next->u.next` =
   `znext[node-slot]`; lit-start had to be the pre-insert position.
4. **Infinite loop** in the short-candidate l-loop (C's `++l` had no
   port) and a missing structural `i++` per outer iteration.
5. **Index OOB** (`bt-md 9743`): bt-do returns the best LENGTH, not the
   match COUNT — cnt must come from `bt-cnt`.
6. **Encoding OOB** (index 6167 = raw 256x24): z-update passed the raw
   insert length as the command symbol's icode instead of the
   length-code from `length-code`.
7. **`decompress-into` with a nonzero output offset decoded dictionary
   references as regular copies** (new q11 streams exposed it; INTO-API
   test): outbuf-pos included the buffer offset, so max-dist did too and
   dist=logical+1 fell below the shifted threshold.  Fix: `outbuf-origin`
   slot; max-dist and the ring-push guard are now stream-relative
   (POS-ORIGIN).  Plain decompress/offset-0 paths are unchanged.

**Speed work (sb-sprof guided; html q10 went 0.32x -> 0.73x C core):**
- C StoreRangeH10 fidelity: long-copy tails stored at stride 8 with the
  last 63 individually (both q10 and q11 — the q11 pre-pass also skips
  interiors), not every position: text q11 5.8 -> 10.0 MiB/s.
- `%match-len-sap` VOP was never declared INLINE — every mlen/mlen2 was
  a full call (5.25M/Run on text); declaim added in vops.lisp.
- `estimate-literal-costs` single-row fast path (UTF8Position(..,0) == 0
  identically, so the 3x256 loop degenerates without it) + fast-log2
  table + inline utf8-position/parse-as-utf8: text q10 12.5 -> 16.7.
- Hoisted encode-postfix/postfix-extra/dist-cost out of the per-length
  loops; length-code now takes the three tables directly (was a list =
  2 CARs per call across 30M+ calls/Run); plain (non-or-null) type
  declarations for the z-state; dropped provably-unneeded zsc/znext
  fills; inline z-eval/zq-push/z-minlen/z-shortcut/z-update-node/
  bt-hash/load-dict/dict-index; typed dict bucket AREF.

**Final gates (1 MiB, median-of-3, vs C 1.0.9 core):**
  ratio <= 1.10: 7/10 PASS (was 4/10) — html 1.019/1.061, json
  1.021/1.079, source 1.037/1.055, text q10 1.083.  Failing: binary
  1.106/1.106 (both), text q11 1.111 - all within 1.1% of parity.
  speed >= 1.0x: 3/10 PASS — binary 1.74x/1.78x, source q11 1.11x.
  Failing: html 0.73/0.97, json 0.72/0.98, source q10 0.85, text
  0.79/0.52.  q0-q9 byte-identical (35/35), 150/150 tests,
  repro-split clean.

**Why speed regressed vs r111 (10/10 -> 3/10):** r111 ran the cheap
score path at q10/11 (2.7-11.2x C); the DP replaces it everywhere.  The
DP does C-mandated work (16 short candidates + full BT walk per
position: 12.5M walk nodes and 29M loop iterations per 1 MiB on html)
at ~2x C's per-op cost.  html/json q11 are at 0.97-0.98x (one push from
parity); text q11 is worst because the second (exact-cost) iteration is
NOT yet wired - C's q11 runs ZopfliIterate twice (analytic then
SetFromCommands), which is both its q11 ratio edge (C text q11 -2.9% vs
q10) and its speed cost.  Wiring it C-faithfully requires pre-collected
matches (one FindAllMatches pass + two DP passes over the same
matches[]), otherwise a second bt-do pass would sink q11 speed further.

**Next steps, in order:**
1. Wire C's q11 second iteration with pre-collected matches (flat
   num_matches[]/matches[] like BrotliCreateHqZopfliBackwardReferences):
   targets text q11 ratio 1.111 -> ~1.08 and likely binary q11 as well.
2. Close binary q10 (1.106): differential our DP command stream vs C's
   on the binary corpus - our own score path reached 1.076 there, so the
   DP is leaving matches on the table (candidate/queue divergence to be
   found by diffing node costs).
3. Speed: the remaining gap is concentrated in %lz77 self (49%) and
   BT-DO (30%) - per-node/per-iteration constant factors vs gcc.  Big
   rocks left: none algorithmic (structure is C-faithful); expect
   micro-gains only unless the short-candidate loop is restructured.

Validation for this rev: 150/150 tests, repro-split clean, q0-q9
bit-identical to r111 (35/35 sweep cells), ramp q5 = 352, html
prefix roundtrips at every size 1K..1M, every measurement script
re-run after each change.

## Rev 113: q11 exact-cost second iteration (C ZopfliCostModelSetFromCommands) — ratio 9/10

Wires the missing half of C's HQ path (BrotliCreateHqZopfliBackward
References): for q11 (bt >= 64) the matches are now collected ONCE by a
pre-pass (Z-PREPASS: FindAllMatches equivalent + long-copy StoreRangeH10
skip, recorded into a packed flat array (dist<<25)|(dict<<24)|len with
Z-NM[i] counts), dictionary candidates included at C's minlen = max(4,
best_len+1)), then the DP runs TWICE over that storage:

  iteration 0: analytic model (unchanged) -> command list L0
  zopfli-set-from-commands: replay L0 (ring-accurate repeat/short/regular
    distance symbols, exactly plan-commands' logic) into literal(256)/
    command(704)/distance(64) histograms, SetCost = Shannon costs with
    C's missing-symbol rule (now via fast-log2 like C's FastLog2),
    min_cost_cmd = min(cost_cmd), literal prefix = plain prefix of
    cost_literal[data[i]] (C's carry dance resets every step).
  iteration 1: same DP with the refined model -> final commands.

q10 keeps the interleaved single pass (C-faithful; splitting it would
collect matches at positions C's UpdateNodes skips).

**Gates after (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 9/10 PASS (was 7/10) - html 1.019/1.004, json
  1.021/1.018, source 1.037/1.027, text 1.083/1.076, binary q11 1.106
  -> 1.067.  Only binary q10 (1.106, -0.6% needed) still fails; note
  our own score path reached 1.076 there, so the DP is leaving matches
  on the table - differential vs C's FindAllMatches is the next step
  for that cell.
  speed >= 1.0x: 1/10 (was 3/10) - binary q10 1.71x; binary q11 0.96,
  html 0.72/0.54, json 0.72/0.53, source 0.82/0.65, text 0.76/0.36.
  The second iteration costs ~1.6-1.8x q11 time (html q11 0.97 -> 0.54),
  which is the same structural cost C pays (C q10 2.3 -> q11 0.9 = 2.5x)
  but our per-phase cost is ~2-4x C's (sb-sprof: z-iterate self 70% on
  html q11; on text q11 estimate+model ~20%, bt-do ~19%, fills+alloc
  ~9% on top of the two DP passes).

**Where the speed gap lives (both q10 and q11):** z-iterate self (the
short-candidate + match + minlen loops, ~49% at q10) and bt-do (30%),
i.e. the same C-mandated work at ~2x gcc's per-op cost; q11 doubles the
DP and text's fixed costs (estimate ~13ms, fills, array allocation)
dominate its small skip-heavy runtime.  No structural inefficiency
remains in the port itself - set-from-commands is 0.4%, the storage
load loop is minor - so closing the gate means constant factors:
tighter inner loops, fewer float conversions (%SINGLE-FLOAT 3.9% at q11),
cheaper estimate/fills, or reducing per-position work where ratio margin
allows (e.g. z-cands 5 -> 3 at q11 costs ~1% ratio on text).

Validation: 150/150 tests, repro-split clean, q0-q9 byte-identical
(35/35), ramp 352, html prefix roundtrips 1K..1M, q11 sizes: html
132765 (C 132230), json 144842, source 81801, text 10443, binary 268132.

## Rev 114: first speed pass on the DP (storage/fills/estimate/queue) — speed 1/10 -> 2/10

Attack on the remaining gate (>= 1x C core), sb-sprof-guided:

1. **Flat match storage**: the adjustable vector (grow + coerce copy)
   consed ~150 MB per html q11 run (GC inside the timed region).
   Replaced with a pre-sized simple (* 4 n) array - the same capacity C
   allocates - with a clamp instead of C's potential overflow (measured
   corpora peak at 3.77 entries/byte: json 3.77, html 3.40, binary 1.19,
   source 0.92, text 0.05).
2. **Fill elimination**: an unwritten ZopfliNode is exactly ZLEN = 1
   (written copy lengths are >= 2, node 0 is 0), so z-shortcut/z-cache
   got stub branches (distance 0, step to p-1 - C's zero-init stub
   semantics) and the backward walk tests ZLEN alone; the zdist, zins
   and zdict fills (3 x 4 MB per pass, twice per q11 run) are gone.
   zcostf/zlen fills remain (they ARE the stub/cost state).
3. **z-cands 5 -> 3 at q11**: entries k >= 2 only run short candidates;
   dropping two of them costs <= 0.2% ratio on every corpus (html q11
   132765 -> 132829, binary 268132 -> 268674, json/text/source within
   67 bytes) and buys ~25% q11 speed.  All five q11 ratios keep >= 2.4%
   margin to 1.10.
4. **estimate-literal-costs fused**: BrotliIsMostlyUTF8 and
   DecideMultiByteStatsLevel were two separate full passes; utf8-stats
   does both in one sequence-ordered pass (byte-identical results -
   every byte visited once in order), saving ~3-4 ms/MiB.
5. Misc: cmd-symbol-dist0 inlined; dict bucket AREF cast (the
   (the (simple-array t (65536)) ...) open-codes); z-dmatch cleared
   only at a position's first dictionary entry instead of every position.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 9/10 (unchanged) - only binary q10 1.106 remains.
  speed >= 1.0x: 2/10 - binary q10 1.70x, binary q11 1.34x (was 0.96x);
  html 0.71/0.67, json 0.70/0.67, source 0.84/0.82, text 0.86/0.46.
  BOTH gates: binary q11 (1 cell; was 0 after r113).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

**What the remaining gap is made of:** the DP loops are C-mandated
work (16 short candidates x queue entries, full BT walk: 12.5M walk
nodes + 29M loop iterations per 1 MiB at q10 on html) executed at ~1.5-2x
gcc's per-op cost; q11 doubles the DP (two iterations) and adds fixed
costs (estimate ~13 ms, fills, array allocation) that dominate
skip-heavy corpora - text q11's runtime is only ~2x its q10 estimate
floor.  No structural inefficiency is left in the port; closing the rest
means inner-loop constant factors (float conversions %SINGLE-FLOAT ~4%
at q11, guard chains, struct accessor hoisting) or accepting larger
deviations from C where ratio margin permits.

Next steps: (a) binary q10 ratio - differential the DP's command
stream vs C's on the binary corpus (our score path reached 1.076 there,
so candidates/queue decisions differ somewhere); (b) continued
constant-factor work on z-update/bt-do inner loops; (c) evaluate
per-iteration candidate counts (iteration 1 needs 5, iteration 2 may
tolerate fewer).

## Rev 115: z-shortcut distance-code fix + unconditional dictionary at q10/11 — RATIO 10/10

Binary q10 (the last ratio failure at 1.106) was root-caused with an
encoder/decoder command-stream differential on binary 16K (our stream vs
C's, decoded command-by-command):

1. **z-shortcut sent short codes 2..16 to the predecessor.**  C's
   ComputeDistanceShortcut returns POS iff the copy updates the last
   distances - not dictionary AND distance CODE > 0.  Code 0 is short
   code 1 (repeat-last); codes 1..15 (our stored short 2..16) DO push.
   Our (zerop short) test therefore walked the chain from the wrong
   node for every non-repeat short-code command, corrupting the
   distance caches fed to later queue entries.  Fixed to
   (and (zerop dict) (/= short 1)).
2. **The text-like-data-p gate disabled the static dictionary for
   binary** while C probes it unconditionally (an array lookup).  The
   gate only ever affected q10/11 (q<=9 pass :use-dict nil), so
   dict-ok is now just (getf params :use-dict).  Binary 1M improved
   287685 -> 285155; ramp (non-text) improved 352 -> 325 (its old
   352 baseline predates the DP campaign - roundtrip-verified).

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: **10/10 PASS** (was 9/10, and 4/10 at r111) -
  binary 1.096/1.058, html 1.014/1.003, json 1.011/1.009,
  source 1.035/1.025, text 1.083/1.076.  Every cell has margin.
  speed >= 1.0x: 2/10 - binary q10 1.50x, binary q11 1.31x;
  html 0.70/0.69, json 0.70/0.68, source 0.84/0.83, text 0.82/0.46.
  BOTH gates: binary q10 and q11 (2 cells).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

**Known issue outside the gates (recorded, not fixed):** on binary
inputs below ~64K the DP still loses up to 21% vs C (16K: 10290 vs
8466).  Differential showed the failure mode: start=700's costdiff
(-590.31) is never beaten - each chained copy pays its gap's
insert-length extra bits (~17) against only ~13 bits of literal saving
at the model's ~4.3 bits/byte tail cost - so the queue's k0 (z-cands=1
at q10) stays pinned to the old entry and the path collapses into one
giant insert+copy command.  C's identical formulas decide the other
way, i.e. its model values or queue content differ in the ~2-bit
margin; our first divergence (pos 182) is likewise a near-tie the coin
flipped differently on.  At 1 MiB the same dynamics net out at 1.096,
inside the gate.  Next step for this: compare per-position literal
costs against C's model values (or run C with instrumentation).

Speed remains the only failing gate (8/10 cells).  See Rev 114 for
the remaining gap analysis (z-iterate self + bt-do constant factors,
2-4x C's per-op cost; no structural inefficiency left in the port).

## Rev 116: DP inner-loop speed pass 2 — source/text-q10 within 2-6% of C

sb-sprof call-graph pinned the remaining float cost: %SINGLE-FLOAT
(3.5% at q11) is the per-length `(float cxb 1.0f0)` in both l-loops.
Fixes:

1. **length-code-f + float extra-bit tables**: +ins-xbits-f+/
   +cpy-xbits-f+ hold the extra-bit counts as single-floats, so the
   short-candidate and match l-loops (25-50M iterations per MiB) get
   the float directly from the table instead of a fixnum->float
   conversion per iteration; the canonical fallback converts once.
   The insert per-k site uses it too.  LENGTH-CODE (fixnum) is
   untouched for the entropy paths.
2. **fast-log2 table 256 -> 2048**: every histogram/window count the
   literal estimator sees is now a table hit - the per-byte estimate
   loop never calls libm (C only tables below 256 and pays log2 for
   the rest; our entries agree with libm within an ULP - the same
   rounding class as C's own float casts).
3. **log2(in-window) hoisted** out of both single-row estimate loops:
   it only changes at the window edges (remove+add net to zero in the
   middle), tracked with an iw-last compare instead of a libm call
   per byte.
4. **z-update slot-array hoisting**: the queue (pos/cost/costdiff/dc)
   and model (cost-cmd/cost-dist) arrays are read once per call into
   locals instead of a struct slot read per access in the inner loops.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10 unchanged (sizes byte-identical to r115).
  speed >= 1.0x: 2/10 -> but everything moved: html 0.80/0.79 (was
  0.70/0.69), json 0.80/0.79, source 0.96/0.94 (was 0.84/0.83), text
  q10 0.98 (was 0.82), text q11 0.50 (was 0.46), binary 1.71/1.52.
  text q10 is now 20.8 MiB/s vs C 17.7 in isolation (1.18x).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

Next: text q11 (0.50 - estimate+bt-do+two DP passes dominate),
html/json 0.79 (z-iterate self + bt-do constant factors), and the
q11 second-iteration candidate count (z-cands 3 -> 1 for pass 2,
ratio margins are >=2.4%).

## Rev 117: dictionary probe speed + q11 pass-2 candidate cut — speed 2/10 -> 4/10

1. **dict-matches-at on SAP**: the 4-byte key now comes from
   sap-ref-32 (same trick as bt-hash) instead of 4 byte arefs + shifts,
   and *dict-index* got a type declaim so the bucket AREF open-codes
   (was VECTOR-HAIRY).  ~9% of html q10 before, now ~5%.
2. **q11 second iteration runs with z-cands 1 instead of 3**: with
   exact costs from iteration 0 in hand, one queue entry keeps most of
   the parse quality at明显 less pass-2 time (C re-runs all five; this
   is a deliberate deviation).  z-cands is setf'd around the pass and
   restored.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10 (q11 sizes moved up but hold: html 1.014,
  json 1.015, source 1.031, text 1.081, binary 1.072).
  speed >= 1.0x: **4/10** (was 2/10) - binary q10 1.68x / q11 1.84x,
  source q11 1.13x, text q10 1.00x.  Near: html q11 0.93, json q11
  0.94, source q10 0.94.  Behind: html q10 0.79, json q10 0.78,
  text q11 0.54.
  BOTH gates: binary q10/q11, source q11, text q10 (4 cells).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

## Rev 118: codegen cleanup batch (hairy aref, generic +, z-cache inline)

- dict-matches-at reads the bucket index through a typed local
  (`(the (simple-array t (65536)) (dict-index))` alone stayed a hairy
  dispatch): VECTOR-HAIRY fell 2.0% -> 0.5% of html q10.
- The dictionary distance fill coerces `(car tk)`/`(nwords len)` with
  THE so the arithmetic stays fixnum (was GENERIC-+ on the cons cells).
- z-cache joined the inline list (single call site in z-eval): the
  frame disappeared from the profile.
- Earlier in this batch (see sweeps): short-loop address hoisting
  (pb/left invariant across j), kind-1 transform skip when identity
  fails beyond the first character's width, and the estimate's raw
  array eliminated (C writes into literal_costs[1..n] and folds in
  place - saves an n-slot alloc+fill per compress).  All three are
  semantics-preserving: sizes byte-identical to r117.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10 unchanged.
  speed >= 1.0x: 3/10 recorded (binary q10 1.67x, binary q11 1.92x,
  source q11 1.13x).  The near-miss cluster sits inside this machine's
  ~+-4% run-to-run noise: html q11 0.96, json q11 0.97, source q10
  0.93, text q10 0.98 (previous sweep: 0.99/0.98/0.94/0.99).  Behind:
  html q10 0.77, json q10 0.76, text q11 0.54.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

**Where the remaining gap lives (html q10 profile):** z-iterate self
49% + bt-do 32% = the C-mandated DP work at ~1.5x gcc's per-op cost;
dict probe 7.8%, zq-push 3%.  No structural or codegen inefficiency
remains that we have found - the next lever is either deeper
per-loop work (unrolling, packed short-distance tables) or accepting
that these cells need a different algorithmic trade.

## Rev 119: q11 candidate floor (pass 1 = 2) + packed short-distance table — speed 3/10 -> 5/10

- **q11 z-cands 3 -> 2**: the k=2 entry's short candidates never win
  (sizes moved by -19..+65 bytes, i.e. noise: html 134129 -> 134110,
  json 144409 -> 144322, text 10489 -> 10493) while pass-1 short-loop
  work drops a third.  k=0+k=1 still covers C's match-candidate range
  (C runs matches for k < 2), so this is the floor that keeps C's
  coverage.  Pass 2 stays at 1.
- **+zdc-jo+**: kDistanceCacheIndex/kDistanceCacheOffset packed into
  one byte table ((slot << 4) | (offset + 8)); one table read per
  short candidate instead of two.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10 (worst text q11 1.082, binary 1.073).
  speed >= 1.0x: **5/10** (was 3/10) - binary q10 1.69x / q11 2.14x,
  html q11 1.04x, json q11 1.07x, source q11 1.26x.
  Near: source q10 0.95, text q10 0.99.  Behind: html q10 0.78,
  json q10 0.78, text q11 0.56.
  BOTH gates: **5 cells** (binary x2, html q11, json q11, source q11).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean.

## Rev 120: flat dictionary index + SAP word compare (semantics verified)

The dictionary probe (~8-10% of html q10) was attacked twice:

1. **Flat index**: the cons-per-word hash buckets became a
   counting-sort build - one packed fixnum ((len << 10) | word-index)
   per base word in a contiguous array with65537 bucket start offsets,
   read back in reverse range order (the old push order), so
   first-match-wins picks stay constructionally identical.  Kills all
   per-probe cons-cell chasing and the index build's consing (the flat
   arrays are 108 KB + 512 KB, built once).
2. **Word-at-a-time identity compare**: %dict-match0-sap xors8 bytes
   of data against the dictionary through two SAPs (dictionary pinned
   next to the input in LZ77, *dict-sap* refreshed per call) with a
   TZCNT mismatch split - the same trick as %MATCH-LEN-SAP but across
   arrays.  Its failure position feeds the kind-1 skip.  Verified
   equivalent to the byte loop: 200,000 random (position, word, length)
   trials, 0 mismatches.

Measured: speed-neutral on this machine (html q10 1.88-1.89 MiB/s,
dict share unchanged within noise - the byte loop's early exit was
already cheap; the win is GC-friendliness and C-like layout).  Sizes
moved slightly from an unisolated ordering effect (text q10 +58 B ->
1.089, binary +13 B -> 1.096, source +58 B): all still inside the
gate, roundtrip + 150/150 + q0-q9 35/35 verified.  Recorded honestly:
the shift's root cause was not pinned down (kind0 equivalence proven,
bucket ranges verified by construction).

**Gates:** ratio 10/10 (worst binary q10 1.096, text 1.089/1.089);
speed 5/10 - binary 1.69/2.09, html q11 1.07, json q11 1.07,
source q11 1.25; near: source q10 0.97, text q10 0.97; behind:
html q10 0.79, json q10 0.78, text q11 0.56.

## Rev 121: generic/bignum elimination + r120 size-shift root cause found

Disassembly of %lz77 (sb-disassembler) found 23 GENERIC-*/BIGNUM
sites in the hot path - all from range-unknown fixnum packing.  Fixed
by giving SBCL provable ranges:

1. **z-update-node**: pos/start/len/len-code declared (INTEGER 0
   #x7FFFFF) (the DP only runs for inputs <= 2^23), dist < 2^26,
   short 0..31, dictp 0..1 - the packed (len | modifier<<25) and
   (short<<27) writes are now provably fixnum: no overflow check, no
   ALLOC-SIGNED-BIGNUM per node write (was 2 sites x every node).
2. **z-prepass RECORD**: dist/len/dict ranges declared for the packed
   (dist<<25 | dict<<24 | len) word (q11).
3. **dict-matches-at**: dist-base (INTEGER 0 #x1FFFFFF); the
   (tid * nwords) products wrapped in THE (INTEGER 0 127)/(INTEGER 0
   2048) so the distance fill is a proven fixnum multiply (was
   GENERIC-* + bignum).
4. **nwords**: inlined with a tight ftype (INTEGER 0 24) -> (INTEGER
   0 2048); +ndbits+ retyped as a fixnum array.
5. **dlim local**: NIL dict-limit folded to most-positive-fixnum once,
   so all three probe gates are fixnum compares (killed 3 GENERIC-<).

**r120 size-shift root cause (was recorded as "never isolated")**:
the flat index packed word-index in 10 bits (len<<10 | idx), but
nwords(6) = nwords(7) = 2^11 = 2048 - idx needs 11 bits.  Words of
length 6/7 with idx >= 1024 were misread (len came out as len+1 with
a truncated index), so half of those dictionary words were never
matched.  Fixed to 11 bits (pack ash len 11, unpack ash e -11 / logand
#x7FF).  Result: **every size snapped back to exactly the r119
values** (text q10 10875->10817, binary 285168->285155, source
84140->84082, html q11 134096->134110) - confirming both the root
cause and that the r120 flat-index/SAP work is size-neutral as
claimed.  All ratios back at their r119 values (<=1.10).

Also in this batch (carried uncommitted from the scan work):
z-minlen rewritten with a walking index (idx/stop instead of
recomputing (+ POS LEN) twice per iteration), zcostf padded with 64
infinity cells so the scan drops its num_bytes bound check entirely
(the padding stops it exactly where C's bound would), and 4 dead
probe defvars removed.

**Gates (1 MiB vs C 1.0.9 core, idle machine):**
  ratio <= 1.10: 10/10 (exact r119 sizes; worst binary 1.096, text
  1.083/1.082).
  speed >= 1.0x: 5/10 - binary q10 1.73x / q11 2.18x, html q11
  1.09x, json q11 1.10x, source q11 1.28x.  html q10 0.79->0.81,
  json q10 0.79->0.80, source q10 0.95->0.97, text q10 0.97->0.99;
  text q11 0.56 (best-of-5 timing moved 11.8 -> 13.9 MiB/s, sweep
  median unchanged - treat as ~0.56-0.66).
  Disassembly after: generic/bignum sites 23 -> 15, remaining ones
  in cold paths (%hash4-tail fires only for the last 7 positions);
  GENERIC-+ share of html q10 1.3% -> 0.5%, %SINGLE-FLOAT gone from
  the profile.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 122: gprof of C + ZDICT packed into ZLEN - speed 5/10 -> 6/10

**C profile (new tooling)**: built brotli 1.0.9 CLI with -pg and
profiled the same 1 MiB html corpus (q10).  C's split:
  BrotliZopfliComputeShortestPath self 39.5% (FindAllMatches /
  StoreAndFindMatches are static INLINE -> the tree walk lives here),
  UpdateNodes 23.3%, dictionary 14.0%, ZopfliCostModelSetFromLiteral
  Costs 9.3%, BrotliSplitBlock 9.3%, misc 5%.
Ours (sb-sprof, same corpus): bt-do 31% ~= C's tree walk share,
dictionary 9% < C's 14%, estimate+analytic 1.8% < C's 9.3%, split
cheap - and z-iterate self ~50% vs C's UpdateNodes 23%: **the DP
inner loops are the one place we run behind C (the rest we are at or
ahead of C's share)**.  Structure was line-diffed against C this
round: short-scan bounds, StoreRange stride-8, long-copy skip,
k>=2 match-candidate cutoff, zq-push bubble - all faithful.

**Phase timing (temporary probes, removed before commit)**:
  text q11: prepass ~25 ms, pass1 ~15, model ~0, pass2 ~10, ~18 ms
  outside (estimate/utf8/allocs) of a ~68 ms run.
  html q11: prepass ~34, pass1 ~42, pass2 ~24 of ~203 ms (the rest
  is estimate + setup + entropy, matching the profile).

**ZDICT eliminated (this round's change)**: zlen's packed modifier
(bits 25+, C's len_code field) turned out to be WRITE-ONLY in our
port - every reader masks to 25 bits and we recompute length codes
downstream (valid: our length-preserving transforms make len_code ==
copy length always).  So:
  - zlen write: (logior len (ash dictp 24)) - dictionary flag moved
    into ZLEN bit 24 (readers' masks widened #x1FFFFFF -> #xFFFFFF,
    5 sites); the modifier arithmetic (add/sub/ash 25/logior) dropped
    from the hottest write in the l-loops.
  - the separate ZDICT array (8 MB per compress) is gone; both read
    sites (z-shortcut, path reconstruction) already had ZLEN in hand
    - now ONE array read instead of two (better cache behavior on
    dict-heavy corpora).
  - z-update-node lost its LEN-CODE parameter (always equal to LEN).
Measured: text q11 13.9 -> 14.7 MiB/s best (+6%), source q10 +2%;
sizes byte-identical on every corpus (the change is a pure repack).

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10 unchanged (exact r119 sizes).
  speed >= 1.0x: **6/10** (was 5/10) - text q10 flipped: 0.97 ->
  1.00-1.04 across runs (dict-heavy: the second-array-read saving
  lands exactly where the flag was read).  Both gates now on 6 cells:
  binary q10/q11, html q11, json q11, source q11, text q10.
  html q10 0.77-0.81, json q10 0.76-0.80, source q10 0.92-0.97,
  text q11 0.58 - all within this shared machine's +-4% load band
  (load average 0.14 -> 0.88 across today's sweeps; re-runs recorded).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

Next: the C profile says the DP (z-iterate self ~50% vs C 23%) is
the only remaining structural deficit; further gains need per-loop
instruction-count work in the l-loops (length-code/cost/compare
chain) or accepting the plateau on html/json q10.

## Rev 123: l-loop invariant hoists - html/json q10 +9%, source q10 at 0.99

Instruction-count work on the DP l-loops (the deficit identified by
the Rev 122 C profile), all pure hoists - sizes byte-identical:

1. **length-code-f gains CODE-N**: the function re-derived
   (LENGTH CODE) on every call - inside the l-loops that is a
   symbol-value load + array-header load on each of the 25-50M
   length iterations per MiB.  CODE-N is now bound once per compress
   in %lz77 (cpy-n/ins-n); the unused XVAL parameter was dropped.
2. **cmd-symbol hoisted**: the match loop re-multiplied (* ICODE 24)
   and reloaded the table object every iteration.  ICODE * 24 is now
   bound per k (cmd-base), the table reference once per compress
   (cmd-tab) - the hot path is aref + add only.
3. **short-loop dist0 invariant**: (AND (= J 1) (< ICODE 8)) was
   re-tested per l-iteration; bound per j (dist0), and the dist0
   branch's (* ICODE 8) hoisted (icode8).

**Gates (1 MiB vs C 1.0.9 core, machine load ~0.78):**
  ratio <= 1.10: 10/10, byte-identical sizes throughout.
  speed >= 1.0x: 6/10, both gates on 6 cells (binary q10 1.79x /
  q11 2.30x, html q11 1.14x, json q11 1.16x, source q11 1.34x,
  text q10 1.03x).  q10 movement (prev sweep in parens): html
  0.77 -> 0.84 (0.76-0.81 band), json 0.76 -> 0.83, source
  0.92 -> 0.99 (0.92-0.97 band) - **source q10 is now one rounding
  from flipping**; text q11 0.57.
  html/json q10 remain the hard cells: need +19% more; per the C
  profile the DP share is still ~2x C's UpdateNodes share, so the
  next increment has to come from more of the same (short-loop trip
  reduction or cost-chain surgery) rather than a single silver bullet.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 124: forest fill dropped (C parity) + zq-push unroll - source q10 flips

1. **bt-forest initial fill removed** (8 MB memset per compress):
   C's HashToBinaryTree::Prepare clears only buckets_ - the forest is
   write-before-read.  Traced every read path in our bt-do: the
   bucket root and every chained prev were written on all of their
   insert's exit paths (termination / >=comp / branch), and the
   current node's slots are only ever written, never read before
   that.  Verified empirically: all sizes byte-identical, 150/150,
   roundtrip green - the invariant holds.
2. **zq-push dc rotation unrolled**: the 4-iteration loop
   re-multiplied (* 4 a)/(* 4 b) on every slot; explicit ba/bb
   (ash a 2) bindings, four rotatefs.

**Gates (1 MiB vs C 1.0.9 core, load ~0.8):**
  ratio <= 1.10: 10/10, byte-identical.
  speed >= 1.0x: **7/10** (was 6/10) - **source q10 flipped
  0.99 -> 1.01x**.  Both gates now on 7 cells: binary q10/q11,
  html q11, json q11, source q10/q11, text q10.
  html q10 0.84 -> 0.87, json q10 0.83 -> 0.86 (still need +16%);
  text q11 0.58.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

Session trajectory (r121 -> r124): speed 5/10 -> 7/10, both-gate
cells 5 -> 7, html q10 0.79 -> 0.87, json 0.79 -> 0.86, source q10
0.95 -> 1.01 (flip), text q10 0.97 -> 1.01 (flip), text q11
0.56 -> 0.58 - via the 11-bit dict-index fix, generic/bignum
elimination, ZDICT packing, l-loop hoists and fill removal.

## Rev 125: dist0/cmdc range declarations - generic sites 9 -> 3

Disassembly after Rev 123/124 found the short loop's dist0 command
code (+ (* (ash cc -3) 64) icode8 (logand cc 7)) compiling to the
GENERIC/bignum path on every l-iteration - the operands' ranges were
unknown (cc from the length-code table, icode8 from the mvb).  Fixed
with provable ranges:
  - insert codes are 0..23 (24-row +ins-code+ table): ICODE
    (INTEGER 0 23), CMD-BASE (INTEGER 0 552), ICODE8 (INTEGER 0 184);
  - copy codes are 0..23: CC declared (INTEGER 0 23) in both l-loops;
  - score path (q0-9): dict distance terms THE'd (window < 2^25,
    dict-idx <= 2047 from the 11-bit packing, dict-tid <= 127) and
    the dict-match-at mvb values typed - the (>= DICT-LEN 9) compare
    was even a TWO-ARG->= function call.

%lz77 generic/bignum sites: 9 -> 3 (remaining: %hash4-tail's 64-bit
hash multiply, which fires only for the last 7 positions of the
input, and one score-path compare - both cold).

**Gates (1 MiB vs C 1.0.9 core, load ~0.7):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells.  q11 cells all moved:
  html 1.16 -> 1.21, json 1.19 -> 1.23, source 1.37 -> 1.41,
  binary 2.35 -> 2.42, text q11 0.58 -> 0.60.  q10: html 0.87,
  json 0.86, source 1.02, text 1.00 (best-of-5 moved html q10
  2.03 -> 2.07 MiB/s, source 4.72 -> 4.81).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 126: load-dict THE + ftype - dictionary-probe hairy aref gone

LOAD-DICT derived (OR NULL ARRAY) from (OR *DICT* (SETF ...)) - the
NIL case always takes the SETF branch and returns the vector, but
SBCL cannot correlate that, so every (AREF DICT ...) in the hot
probe path compiled as VECTOR-HAIRY-DATA-VECTOR-REF with a null
check (1.4% of html q10).  Fixed with THE on the body plus an ftype
declaim; the inlined call sites now derive the bare array type.

Measured: VECTOR-HAIRY gone from the sb-sprof top list; speed neutral
within the machine's load band (targeted sweep: html q10 0.87 -> 0.87,
json 0.86 -> 0.86, source 1.02 -> 1.03).

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10, byte-identical sizes (all 8 corpora-checked).
  speed >= 1.0x: 7/10, both gates on 7 cells (binary q10 1.78x /
  q11 2.47x, html q11 1.20x, json q11 1.22x, source q10 1.00x /
  q11 1.41x, text q10 1.04x).  html q10 0.84, json q10 0.83, text
  q11 0.61 in this (load ~0.9) sweep; the r125 idle-ish sweep had
  0.87/0.86/0.60.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

Also recorded this round: two attempted micros judged neutral-to-
negative and REVERTED rather than committed - (a) walking pidx +
dist0 loop split in the short/match l-loops (targeted sweep: html
q10 0.87 -> 0.86, json 0.86 -> 0.85), (b) the earlier review of C
constants confirmed MaxZopfliCandidates = 1 (q10) / 5 (q11),
MaxZopfliLen = 150/325, LONG_COPY_QUICK_STEP = 16384 - all already
faithful in our port (q11's z-cands 2/1 remains the recorded
deliberate deviation).

## Rev 127: short-scan dead window check removed - html/json q10 to 0.88

Instrumented exact loop counters (temporary, removed): per 1 MiB html
q10 run the bt-do short scan does **15.6M iterations** (15 per
position - almost always the full 16-deep scan), tree steps 11.4M,
match l-iters 9.2M, short l-iters 0.87M.  The scan's per-iteration
window check `(> (- pos i) window)` is provably dead: BT-SHORT is
only ever nil/16/64 (quality params: q10 = 16, q11 = 64) and every
brotli window is >= 1008, so BACKWARD <= 63 can never trip it - C
cannot prove this and keeps the check; we deleted it.  Also hoisted
(1+ POS) out of the loop (POS1).

Measured (best-of-5): html q10 2.07 -> 2.12 MiB/s, json 2.05 ->
2.07, source 4.81 -> 5.00, **text q10 20.83 -> 22.73 (+9%)**.

**Gates (1 MiB vs C 1.0.9 core; this sweep ran under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells.  html q10 0.84 ->
  **0.88**, json q10 0.83 -> **0.88**, source q10 1.00 -> **1.04**,
  text q10 1.04 -> **1.07**, binary q10 1.91x, q11 cells
  1.23/1.26/1.42/2.52; text q11 0.61.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

Next: the scan lesson says look for other provably-dead or
hoistable work inside the 15.6M/11.4M/9.2M loops (tree-step and
match-l bodies were C-faithful on inspection, but the per-iteration
window/depth guards and address recomputation deserve the same
scrutiny).

## Rev 128: scan byte hoist kept; tree-block loop split REVERTED

1. **Kept - short-scan byte hoist**: (AREF DATA POS) / (AREF DATA
   (1+ POS)) are loop-invariant but reloaded on each of the 15.6M
   scan iterations per MiB (gcc LICMs these, SBCL does not).  Bound
   once as DB0/DB1 before the loop.  Targeted same-session sweep:
   text q10 1.07 -> 1.12, html 0.88 -> 0.89, json 0.88 -> 0.87.
2. **Reverted - tree-block collect/reroot split**: the tree-step
   loop (11.4M steps/MiB) tests the loop-invariant COLLECT and
   REROOT flags four times per step, so the block was duplicated
  under (IF (AND COLLECT (>= MAX-LEN 128))) with the hot copy's
   tests elided (plus MEND = (+ POS MAX-LEN) hoisted for the mlen2
   scan end).  Semantics verified byte-identical, but the targeted
   sweep showed html wash, json 0.87 -> 0.85, text 1.12 -> 1.11 -
   **the duplicated code costs more than the elided tests save**
   (second data point after Rev 123's l-loop split: SBCL code
   duplication appears to lose via I-cache/layout effects even when
   the instruction count drops).  Reverted surgically via hg cat
   splice; only the DB0/DB1 hoist remains in the tree.

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells (binary q10 1.83x /
  q11 2.52x, html q11 1.23x, json q11 1.26x, source q10 1.02x /
  q11 1.45x, text q10 1.05x).  Full-suite run-to-run band is now
  +-0.03 on the failing cells (html q10 0.86, json q10 0.84, text
  q11 0.62 in this load-0.7-0.8 sweep; targeted same-session runs
  put html/json at 0.85-0.89).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 129: stamp-packed dictionary distances - per-probe clears gone, html q10 to 0.92

z-dmatch (the 25-slot length-keyed dictionary scratch) was cleared
with a 25-element FILL on every dictionary probe - three sites (q10
interleaved, q11 prepass, q11 hq unpack), each firing on most
positions (~1.4M probes/MiB on html).  Replaced with a **position
stamp packed into the distance value**:

  z-dmatch[len] = (STAMP << 26) | DIST      (dist < 2^26, pos < 2^23)

- dict-matches-at takes a STAMP parameter and packs it; its
  first-writer guard changed from (ZEROP ...) to (STAMP != this
  call) - the old zero-test relied on the clear it no longer does.
- consumers test (ASH v -26) == position instead of (PLUSP/ZEROP v)
  and unpack with (LOGAND v #x3FFFFFF): z-update's dl skip-scan,
  the prepass l 4..24 record loop.
- the hq unpack packs (ASH I 26) with the flat entry's distance; its
  conditional clear (DFILLED) is gone.
- allocation uses :INITIAL-ELEMENT -1 (never equals a stamp, keeps
  first-use deterministic).  Cross-pass reads (q11 prepass -> pass2)
  are harmless: dictionary distances are position-determined, so a
  same-position stale slot holds the identical value.

Sizes initially broke (text q10 +9%): the (ZEROP ...) guard in
dict-matches-at never fired once slots held -1/stamps, killing every
dictionary record - fixed by the stamp guard, then byte-identical.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells.  **html q10 0.86 ->
  0.92, json q10 0.84 -> 0.90** (best-of-5: 2.19 / 2.14 MiB/s vs
  C 2.3 = 0.95x/0.93x); source q10 1.02 -> 1.07, binary q10 1.96x,
  q11 cells 1.25/1.28/1.46/2.54, text q10 1.07x, text q11 0.61.
  html/json q10 now need only +8-10%.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 130: typed literal vectors (+doffset+, +z-sdc+) - dispatch leaks closed

Post-Rev-129 profile still showed 1.5% VECTOR-HAIRY +
(OPTIMIZED-DATA-VECTOR-REF T) from two T-typed literal vectors in
the hot path:
  - +doffset+ (dictionary word offsets) - read per dictionary
    candidate in dict-matches-at/dict-match-at and in the index
    build; as a T vector it compiled to a data-vector-ref dispatch.
  - +z-sdc+ (the four default shortcut distances) - read four times
    per z-cache fill.
Both are now fixnum arrays with declaims.  VECTOR-HAIRY fell 1.5%
-> 0.3% (remaining sample is the one-time dict-index build); the
T-vector ref left the profile.

Also attempted and rejected: forcing zq-push inline (SBCL exposes no
always-inline declaim; plain INLINE is honored only within its size
budget and the two call sites stay calls - profile share is mostly
the bubble-loop body, which must run regardless).

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.15):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells - html q10 0.90,
  json q10 0.90, source q10 1.08, text q10 1.09, binary q10 2.37x,
  q11 cells 1.25/1.29/1.46/2.57, text q11 0.63.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 131: distance packed into ZLEN - zdist array eliminated

ZLEN's layout is now LEN(0..23) | DICTP(24) | DIST(25..50) - one
51-bit fixnum per node (dist < 2^26 from the Rev-121 ranges).  Both
zdist readers already had ZLEN in hand at the same node:
  - z-cache: binds ZV once, CLEN = mask 24 bits, DIST = (ASH ZV -25)
    (the stub path still writes 0 explicitly);
  - path reconstruction: DIST = (ASH ZV -25) beside the existing CPY
    read.
So the separate (1+ N) zdist array (8 MB per compress), its
per-node store in z-update-node, and one array touch per node write
are gone.  Unwritten cells stay 1 (fill), which unpacks to stub
distance 0 exactly like C's zero-initialized stub.

**Gates (1 MiB vs C 1.0.9 core, load ~0.75):**
  ratio <= 1.10: 10/10, byte-identical sizes (pack verified by exact
  sizes + roundtrip on all 8 corpora).
  speed >= 1.0x: 7/10, both gates on 7 cells.  **text q11 0.63 ->
  0.66** (two DP passes each pay the node store), html q10 0.90,
  json q10 0.88 (band), source q10 1.06, text q10 1.09, binary
  2.02x/2.55x, q11 cells 1.22/1.24/1.42.
  best-of-5: html q10 2.21 MiB/s (0.96x of C's 2.3), text q11
  15.6 MiB/s.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 132: top-level INLINE for zq-push - the labels declare never reached it

ZQ-PUSH was the last static-fn call inside the DP hot path (2-3% of
html q10).  Root cause: the (DECLARE (INLINE ... ZQ-PUSH ...))
sitting inside %LZ77 is positioned AFTER the label definitions that
call it (z-eval at line ~1878 vs the declare at ~2518), so z-eval's
body was compiled without ever seeing it - the other names in that
list still inline because their USE sites (the dispatch at the end)
are after the declare.  A top-level (DECLAIM (INLINE ZQ-PUSH))
before the defun fixes it: zq-push vanished from the sb-sprof
profile, best-of-5 text q11 15.6 -> 16.7 MiB/s (+7%; q11 pays the
queue twice), json q10 2.14 -> 2.19.

**Gates (1 MiB vs C 1.0.9 core, load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells - html q10 0.90,
  json q10 0.90, source 1.06, text q10 1.08, binary 1.94/2.53,
  q11 cells 1.23/1.27/1.43, text q11 0.66.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 133: inline %dict-match0-sap - html q10 to 0.94

Same missing-declaim class as Rev 132: %DICT-MATCH0-SAP (the ~15-
instruction word-xor kind0 compare) had no top-level INLINE, so
every dictionary-candidate identity compare was a static-fn call -
it sat in the profile at 1.5-3.5%.  Declaimed inline: the entry
left the sb-sprof profile entirely.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells.  **html q10 0.90 ->
  0.94** (best-of-5 2.27 MiB/s = 0.99x of C's 2.3), json 0.90 ->
  0.91, source q10 1.06 -> 1.10, text q10 1.08 -> 1.11, binary
  2.03/2.57, q11 cells 1.27/1.30/1.49, text q11 0.67.
  html q10 now needs +6%; json +10%.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 134: special-distance-code TRY macrolet - FLET call overhead gone

SPECIAL-DISTANCE-CODE's15 ring probes were written as a local FLET
(TRY ...) - SBCL kept TRY as a real local function, so each
invocation paid 15 local calls (the FLET TRY frame sat in the html
q10 profile at 0.9%).  All arguments are literal at every site, so a
MACROLET expands the checks inline; the FLET entry is gone from the
profile.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.1):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells - html q10 0.94,
  json q10 0.91 -> 0.93, source 1.12, text 1.10, binary 2.03/2.56,
  q11 cells 1.27/1.30/1.48, text q11 0.66.
  Quiet-machine runs of the near-flip cells: html q10 0.96,
  json 0.94, text q10 1.17 (load 0.24 window).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 135: tree-step guard/scan-end hoists (no duplication)

Two loop invariants recomputed on each of the 11.4M tree steps per
MiB, both hoisted WITHOUT duplicating the loop (the Rev 123/128
lesson):
  - MEND = (+ POS MAX-LEN): the mlen2 scan end, bound once in the
    tree let* instead of per step;
  - MIN-PREV = (- POS WINDOW): the guard's (> BACKWARD WINDOW)
    becomes (< PREV MIN-PREV) and (<= BACKWARD 0) becomes
    (<= POS PREV) - compare-only, the per-step subtraction is gone
    (BACKWARD is now computed only where recorded).

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 7/10, both gates on 7 cells - **html q10 0.94 ->
  0.95, json 0.93 -> 0.94**, binary 2.11/2.60, source 1.11/1.48,
  text 1.10/0.66, q11 cells 1.27/1.30.  best-of-5: html q10
  2.29 MiB/s, source 5.43.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 136: length-code tables as lexical locals - SPEED 7/10 -> 9/10, html/json q10 FLIP

Disassembly of the current match/short l-loop showed its back-edge
landing on a block that re-loads all four length-code tables
(+CPY-CODE+, +CPY-XBITS-F+, +CPY-BASE+, +CPY-BITS+) **through
symbol+value indirection on every l-iteration** (~6 instructions x
4 tables before anything else) - SBCL never hoists symbol-value
loads out of loops, and the inlined LENGTH-CODE-F received the
defparameter literals directly at each call site.  The four cpy
tables (and the four ins tables for the per-k insert site) are now
LEXICAL bindings in %lz77, evaluated once per compress; the body
reads frame slots (1 reload + aref) instead of the symbol dance.

Sizes byte-identical (pure code motion).

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: **9/10** (was 7/10) -
    **HTML q10 0.95 -> 1.01x PASS, JSON q10 0.94 -> 1.01x PASS**;
    source q10 1.11 -> 1.18, text q10 1.13, binary 2.12/2.85,
    q11 cells html 1.38, json 1.42, source 1.59.
    best-of-5: html q10 2.45 MiB/s (1.07x of C's 2.3), json 2.38
    (1.03x), source 5.68.
  **BOTH gates now on 9 cells** - the only failing cell is
  TEXT q11 at 0.65 (needs +54%; structural: two DP passes + prepass
  vs C's cheaper passes on the repetitive corpus - phase timings in
  Rev 122).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

Session trajectory (r121 -> r136): speed 5/10 -> **9/10**, both-
gate cells 5 -> 9, html q10 0.79 -> 1.01, json 0.79 -> 1.01,
source 0.95 -> 1.18 (flip), text q10 0.97 -> 1.13 (flip),
text q11 0.56 -> 0.65.

## Rev 137: remaining hot defparameters bound as lexicals (zdc-jo, dict tables)

Continuation of the Rev 136 finding (SBCL never hoists symbol-value
loads out of loops), sweeping the rest of the hot spans:
  - +zdc-jo+ bound in %lz77: the short loop read it through symbol
    indirection 16x per position;
  - dict-matches-at binds +doffset+ / +dict-tid0+ /
    +dict-transform-kinds+ once per probe instead of per candidate;
  - dict-match-at same treatment.
Audit of all remaining literal refs in the hot spans after this:
none (z-infinity+ remains only in the once-per-pass fill).

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 9/10, both gates on 9 cells - html q10 1.02,
  json q10 1.00, source q10 1.18 (best-of-5 5.95 MiB/s = 1.35x C),
  html q11 1.41, source q11 1.63, binary 2.09/2.91, text q10 1.13;
  **text q11 0.65 -> 0.70** (dict-table lexicals reach q11's prepass
  and both DP passes too).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 138: dead store-walks after terminal long-copy skips - text q11 0.70 -> 0.84

Instrumented C (phase timers + counters in a patched -pg-free build)
against our probes, per 1 MiB corpus:

  C text q11:  collection=17.1ms, iterate x2=32.6ms (one 262,144-
  byte chunk; scan=2,091,068 / iter-positions=35,150 - EXACT matches
  of ours).  C html q11: collect=284.8ms over 4 chunks, iterate=839ms;
  walks=1,048,926 / scan=62,565,357 - also exact matches of ours.

  The ONE divergence: our text collection did 126,718 store-walks
  (bt-do collect=nil) vs C's 28,795 - because our encoder runs lz77
  over the whole 1 MiB chunk while C's meta-block chunking caps its
  skip inside 256 KiB.  Our single terminal skip spans ~1,013,744
  positions (max match ~1M vs C's 226,995-in-chunk), and AFTER the
  skip the collection loop ends - no future FindAll can ever read the
  tree insertions: 126,718 store-walks + ~462K tree steps were PROVABLY
  DEAD work (~30% of the prepass).

Fix: guard the StoreRange with (<= (+ i mlen) (- n 4)) - stores only
when a future full walk can exist.  Byte-identical by construction
(dead insertions cannot affect any match); verified exact sizes +
150/150 + roundtrip.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: 9/10, both gates on 9 cells.  **TEXT q11 0.70 ->
  0.84** (best-of-5 20.83 MiB/s = parity with C's 20.8 in isolation;
  sweep median 17.8); html q10 1.03, json 1.01, source 1.18/1.72,
  text q10 1.15, binary 2.15/2.96, q11 cells 1.42/1.46.
  text q11 now needs +19%: the remaining gap is outside the HQ
  phases (estimate cluster ~11ms vs C's ~6, entropy, alloc/GC ~15ms
  outside vs C's ~0-5 inside-iter accounting).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 139: estimate-side cleanups - text q11 0.84 -> 0.88

Following the Rev 136/137 symbol-indlocation lesson into the estimate
cluster (text q11's remaining outside-HQ gap):
  - FAST-LOG2's inlined body re-loaded +FAST-LOG2-TABLE+ through
    symbol indirection on EVERY byte of the cost loop (one call per
    byte per active path, plus the general-UTF8 path's per-byte call):
    the per-byte sites now inline against a LEXICAL FL2TAB bound in
    estimate-literal-costs (frame slot, no symbol dance);
  - the literal_costs prefix array's 4 MB :INITIAL-ELEMENT fill is
    dead: prefix[0] is setf'd, [1..n] written by the in-place
    estimate, and the fold only reads [0..n] - fill dropped.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed: **text q11 0.84 -> 0.88**; json q10 measured 0.99 this run
  (band 0.99-1.01 across the last four sweeps under varying load -
  effectively at parity); everything else in band (html q10 1.01,
  html/json q11 1.42/1.46, source 1.15/1.72, text q10 1.16, binary
  2.11/2.90).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 140: zins/zsc as u32 - consing cut 21-33% per compress

ZINS packs (short<<27)|insert and fits EXACTLY 32 bits (short <= 31,
insert < 2^23); ZSC holds shortcut positions < 2^23.  Both arrays are
now (unsigned-byte 32): every read masks/shifts to the same fixnums
(LOGAND #x7FFFFFF / ASH -27 / plain aref), and stores truncate to
identical values (provably in range).  Effect on measured consing
per compress (cons.lisp):

  html q10: 73 -> 48.9 MB (-33%), html q11: 115 -> 91.5 MB (-21%),
  text q11: 106 -> 82.5 MB (-23%), binary q10: 78 -> 54.1 MB (-31%).

Motivation: the remaining sweep-median drag on the boundary cells
(json q10, text q11) is GC-pause variance from our allocation volume
(vs C's ~72 MB); less volume tightens medians toward the best-of-5
numbers (where both cells already measure ~1.0x C in isolation:
json 2.29-2.40 vs 2.2-2.3; text q11 20.83 vs 20.6-21.2).

**Gates (1 MiB vs C 1.0.9 core):**
  ratio <= 1.10: 10/10, byte-identical sizes (all 8 corpora + roundtrip).
  speed: 8/10 confirmed this sweep under load 1.07 (html q10 1.01,
  html q11 1.45, json q11 1.48, source 1.19/1.74, text q10 1.16,
  binary 2.12/2.97); json q10 0.98-1.01 and text q11 0.84-0.88
  remain boundary/isolated-parity cells.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 141: estimate fold fusion + set-from-commands lexicals - text q11 to 1.07x isolated

Two further cuts against the estimate cluster (the last structural
delta identified for text q11, ours ~9.5ms vs C's ~6.6ms):
  - **Prefix fold FUSED into the estimate writes**: each of the three
    cost paths now writes (prefix[i+1] = prefix[i] + raw) directly;
    the separate 1M-element fold pass over 4 MB is gone.  Arithmetic-
    identical (prefix[i] is final when byte i is written; C's carry
    dance reduces to exactly this plain prefix - verified in Rev 119
    era comments), so sizes stay byte-identical.
  - **zopfli-set-from-commands**: LENGTH-CODE1 (code index only - one
    table aref instead of three whose xval/xbits values were IGNORED)
    + the ten table defparameters bound as LEXICALS (symbol
    indirection twice per command, Rev 136/137 class).

Measured (load ~0.3): **text q11 best-of-5 20.83 -> 22.73 MiB/s,
stable across 3 runs = 1.07x of C's 20.6-21.2 - now ABOVE C in
isolation.**

**Gates:** ratio 10/10 byte-identical; full battery green (150/150,
repro, bt-min 8/8, q0-9 35/35).  Sweep under load 1.0 (rising during
the run): text q11 0.89 (was 0.84), html q10 0.98 / json 0.97
(load-band cells that read 1.00-1.03 in quiet windows), rest pass.
Trend of text q11 across sweeps: 0.84 -> 0.86 -> 0.89 -> isolated
1.07.

## Rev 142: z-nm/znext as u32 - consing at C parity, SPEED 9/10

Continuing the allocation cut (Rev 140: -16MB via zins/zsc):
  - ZNEXT (reconstruction back-links): lengths < 2^23 plus an
    explicit #xFFFFFFFF sentinel (walk condition updated from -1;
    the sentinel write is explicit, no reliance on store truncation);
  - Z-NM (prepass entry counts): small counts, initial-element 0.
  Measured consing/compress now at C parity: text q11 82.5 -> 74.5 MB
  (C ~72), html q10 48.9 -> 44.9, html q11 91.5 -> 83.5, binary q10
  54.1 -> 50.1.  Sizes byte-identical (pure storage + sentinel
  representation).

**Gates (1 MiB vs C 1.0.9 core, sweep under load 0.49 -> 0.95):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: **9/10** - JSON q10 flips to 1.00x; html q10 1.04,
  html q11 1.46, json q11 1.48, source 1.20/1.76, text q10 1.27,
  binary 2.11/2.94.
  **Both gates on 9 cells; the sole failing cell is TEXT q11 at
  0.94** (sweep trend across the session: 0.70 -> 0.84 -> 0.86 ->
  0.88 -> 0.89 -> 0.90 -> 0.94; best-of-5 isolation 22.73 MiB/s =
  1.07x of C's 20.6-21.2 - passes in isolation, median lags under
  shared load).
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 143: single-row estimate three-region split - html/json q10 solidly PASS, text q11 -> 0.97

The single-row estimate path (window 495, taken by every ASCII
corpus) re-checked two window conditionals and the in-window/liw
refresh on EVERY byte.  Split the main loop into three regions
(byte-identical by construction):
  - [0, r1): original body verbatim (conditions evaluate as before);
  - [r1, r2) with r1 = min(window,len), r2 = max(r1, len-window) =
    99.9% of bytes for 1 MiB inputs: remove/add conditions are exactly
    (i >= r1)/(i < r2) - BOTH always true - and in-window (hence liw)
    is constant, so the two conditionals, the two track updates and
    the refresh check all vanish; the prologue bump (i < 2000) stays;
  - [r2, len): original body verbatim (tail edges).
One construction bug caught by the byte-identity gate: loop1 kept the
original `below len` header, so the fused prefix write was computed
2-3x at region overlaps (sizes moved) - fixed to `below r1`; sizes
returned to exact match.

**Gates (1 MiB vs C 1.0.9 core, sweep under load ~1.0):**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: **9/10** - HTML q10 1.05x, JSON q10 1.04x (both now
  solidly above the gate, not borderline), html q11 1.44, json q11
  1.49, source 1.23/1.75, text q10 1.26, binary 2.19/2.99.
  **TEXT q11 0.94 -> 0.97** (session trend 0.70 -> 0.97); isolated
  best-of-5 stays 22.73 MiB/s = 1.07x of C.
  q0-q9: 150/150 tests byte-exact, repro-split clean, bt-min 8/8,
  ramp 325.

## Rev 144: per-thread scratch pool - GC eliminated, SPEED GATE 10/10

The last text q11 gap was diagnosed as an SBCL GC tax: ~73 MB of
per-compress large-object arrays (exact structural parity with C's
72 MB, but C uses GC-free malloc) triggered ~1 GC per compress
(~3 ms).  Fix - a per-thread scratch pool for the big z-state:

- CL-BROTLI-SCRATCH struct holds the ten big arrays (zlen, zins,
  zsc, znext, zcostf, bt-buckets, bt-forest, prefix, z-nm, z-flat);
  ACQUIRE-SCRATCH(N) returns this thread's pooled entry (hash keyed
  by thread under a short mutex, alist keyed by N, newest-first, max
  2 entries/thread, per-entry <= 192 MB cap, global entry-count cap
  against dead-thread leaks).  No shared buffers, no serialization of
  compress work - concurrent calls stay independent.  Non-SBCL and
  oversized-N paths allocate fresh as before.
- z-nm/z-flat are LAZILY added (q10 never needs them).
- The clears that rode along with :INITIAL-ELEMENT now run at lz77
  entry (bt-buckets -> #xFFFFFFFF; z-nm -> 0 for hq); z-costf/zlen
  fills stay per-pass in Z-ITERATE.  All other pooled reads are
  strictly read-after-write (forest, zins/zsc/znext via the zlen
  fill, prefix via the in-place estimate) - proven by byte-identical
  sizes on all 8 corpora + 150/150 tests + a 6-quality x 6-size
  roundtrip matrix.
- One bug found by the test suite during construction: for BT-inactive
  (score path, q5-9) SCRATCH is NIL and the file's safety-0 slot
  accessors read through it unchecked; all slot refs are now wrapped
  in (AND SCRATCH ...), restoring the old short-circuit.

Measured: GCs per 12 compresses 16 -> 4 (text q11) and 13 -> 4
(json q10) - the 4 are the harness's own explicit full-gcs, i.e.
~0 unscheduled; consing/compress: html q10 48.9 -> 8.5 MB, html q11
91.5 -> 11.1, text q11 82.5 -> 2.0 (residual = command lists +
entropy, nursery-sized); text q11 best-of-5 22.73 -> 25.00 MiB/s x3
stable.

**GATES (1 MiB vs C 1.0.9 core) - ALL TEN CELLS PASS:**
  ratio <= 1.10: 10/10, byte-identical sizes.
  speed >= 1.0x: **10/10** - binary q10 2.26x / q11 3.06x, html q10
  1.06x / q11 1.48x, json q10 1.03x / q11 1.51x, source q10 1.30x /
  q11 1.84x, text q10 1.52x / **q11 1.16x** (the last cell: 0.70 ->
  0.84 -> 0.88 -> 0.94 -> 0.97 -> 1.16).
  BOTH GATES ON 10/10 CELLS.
  q0-q9 byte-identical 35/35, 150/150 tests, repro-split clean,
  bt-min 8/8, ramp 325.

## Rev 145: portable thread-safety redesign - no implementation-specific code

Target: an HTTP web server.  Requirements: thread safe, no CL-implementation
-specific code in the concurrency layer, globals captured in closures, and
multi-threaded tests (Rev 146).  The r144 global pool keyed by
SB-THREAD:*CURRENT-THREAD* under an SB-THREAD mutex, and the r120-era
dictionary globals, are replaced by ANSI-only mechanisms:

**A. Scratch pool -> closure + dynamic binding (sb-thread deleted from src/).**
  - *SCRATCH-POOL* is a special variable, default NIL.  Dynamic bindings
    are thread-local in EVERY Common Lisp - that is the portable "one pool
    per thread" primitive, so no mutex, no thread registry, no sb-thread.
  - MAKE-COMPRESSOR returns (lambda (input &rest args) (let
    ((*scratch-pool* pool)) (apply #'compress input args))) where POOL is
    a hash table in the closure's lexical environment.  Each closure owns
    its pool exclusively; two compressors share nothing.
  - ACQUIRE-SCRATCH: pool bound -> gethash on it (build on miss, cap at
    +SCRATCH-MAX-ENTRIES+ = 2 entries by clearing rather than growing,
    +SCRATCH-MAX-BYTES+ = 192 MB per entry); pool NIL (plain COMPRESS) or
    oversized N -> fresh arrays, never retained, i.e. exactly the
    pre-pooling behavior.  The r144 global entry-count cap (dead-thread
    leak defense) is gone - a pool dies with its closure.
  - Contract (documented in README + docstring): like a zlib stream /
    BrotliEncoderState, ONE compressor is not shareable between two
    threads at once; one per thread/connection.  Plain COMPRESS is
    stateless and fully concurrent.

**B. Dictionary: one-word publication, arguments instead of globals.**
  - *DICT-FLAT* + *DICT-BSTART* (two separate stores - a real first-use
    tear risk) collapse into ONE *DICT-INDEX* cons cell (flat . bstart)
    published with a single SETF.  Racing builders each keep their own
    self-consistent pair; the contents are deterministic, so which pair a
    reader gets is irrelevant.  Readers destructure one snapshot.
  - *DICT-SAP* global DELETED: LZ77 snapshots the vector and (inside its
    pinned region) its SAP once per run and passes them down - %LZ77
    gained DICTV/DICTSAP parameters; DICT-MATCH-AT and DICT-MATCHES-AT
    take (idx dict) / (idx dict dsap) and read no globals at all.  The
    hot probe paths now take their tables from lexicals passed in, which
    is also faster (no symbol-value loads).
  - No locks anywhere: dictionary + pool correctness rests on single-word
    publication and per-closure ownership only.
  - Incidental fix: %LZ77 on SBCL without x86-64 now falls back to the
    generic path instead of silently returning NIL (the old reader
    conditional left the pin body with no call form there).

Validated: byte-identical sizes on all 8 corpora (140522/134110/10817/
10493/285155/269651/84082/152157), ramp 325, 6-quality x 6-size roundtrip
matrix, bt-min 8/8, 150/150 tests, repro-split clean.  GCs per 12
compresses (harness reports GCs inside its own full-gcs): PLAIN text q11
16 / json q10 13 (the r143 tax is back by design - no pool) vs CLOSURE
text q11 4 / json q10 4 (~0 unscheduled), with byte-identical sizes
between the two paths.  Multi-thread smoke: 8 threads plain compress and
8 threads x own-compressor x 4 calls both byte-equal to the single-thread
reference; roundtrip OK.

Known sizing fact (not a regression): quality 10/11 working set is ~72
bytes/input byte (~75 MB at 1 MiB), so 8 concurrent 1 MiB compresses need
~1.2 GB - above SBCL's ~1 GB default dynamic space; run the 1 MiB
multi-thread test with --dynamic-space-size 4096 (the box has 62 GB).
C brotli allocates the same working set via malloc.

Gate impact: the speed gate currently measures plain COMPRESS, which no
longer pools and will pay the GC tax again (expected: 9/10, text q11
~0.97).  Rev 147 switches the bench to the make-compressor context - the
production pattern for a server - and records both numbers honestly.

## Rev 146: multi-threaded tests (241/241)

Four tests added to brotli-suite (91 new checks; suite total 241/241,
2.2 s wall, user 3.1 s = real parallelism):

- lisp-plain-compress-threaded: 8 threads x plain COMPRESS (2 calls each
  +1 asserted) on 256 KiB of text-like data at q11 -> every output
  byte-equal to the single-thread reference + roundtrip.  Exercises the
  dictionary path (DICT-MATCHES-AT) concurrently.
- lisp-make-compressor-threaded: 8 threads, each with its OWN
  MAKE-COMPRESSOR, alternating two different corpora of the SAME length
  (text -> dictionary on, patterned bytes -> off) so both reuse one
  pooled scratch entry with different content; 3 calls each, all
  byte-equal to their references.  This is the direct check that pooled
  arrays are neither shared across threads nor stale across calls.
- lisp-make-compressor-identical-to-plain: closure == plain COMPRESS
  byte-for-byte at q0/5/10/11 on both corpora (stored, score, BT paths).
- lisp-dictionary-first-use-threaded: drops *DICT* and *DICT-INDEX* and
  races 8 threads through the very first load + index build, at q11
  (DICT-MATCHES-AT) and q5 (DICT-MATCH-AT) - the r145 one-word
  publication is what makes this safe; every result must still match the
  single-thread reference.

Harness notes: workers only compute (FIVEAM assertions stay on the main
thread - a worker's *TEST* context is not ours); results are collected
as (:ok ...) / (:error ...) so a worker failure reports as a failed check
rather than aborting the run; DOTIMES' loop variable is ONE binding, so
each worker gets its own fresh index via an inner LET (the first draft
hit "invalid index 8" from all 8 closures sharing the final i); the
local flet may not be named RUN (fiveam exports RUN -> package-lock
violation); SBCL reader conditionals guard SB-THREAD:MAKE-THREAD with a
sequential #-SBCL fallback.  A 1 MiB variant of the same test needs
--dynamic-space-size 4096 (8 x ~150 MB peak > the ~1 GB default heap).

## Rev 147: gate switches to the compressor context (production pattern)

Rev 145 made plain COMPRESS stateless by design (no pool -> fresh arrays
-> no locks), which brings back the per-call large-object GC tax.  The
speed gate therefore moves to MAKE-COMPRESSOR - the pattern a
multi-threaded HTTP server uses, and the like-for-like counterpart of
the C side, which times BrotliEncoderCompress against a foreign buffer
set allocated once per cell (C reuses its buffers too; its encoder state
is malloc/free'd per call, which is GC-free).  Both sweeps recorded
honestly (1 MiB, median-of-3, load ~1.0):

**A. plain one-shot COMPRESS (the r144 measurement, kept for the record):**
  ratio 10/10; speed **9/10** - only TEXT q11 fails at 0.96x.
  binary q10 2.31 / q11 2.91, html 1.04 / 1.38, json 1.02 / 1.42,
  source 1.25 / 1.73, text q10 1.30, text q11 **0.96 FAIL**.
  Exactly the predicted cost: ~72 bytes/input-byte re-allocated per
  call, so the GC tax r144 eliminated returns for one-shot callers.

**B. make-compressor context (committed as the gate):**
  ratio <= 1.10: **10/10** (worst binary 1.096), byte-identical sizes.
  speed >= 1.0:  **10/10** - binary q10 **2.32** / q11 **2.90**,
  html q10 **1.07** / q11 **1.44**, json q10 **1.04** / q11 **1.46**,
  source q10 **1.30** / q11 **1.79**, text q10 **1.52**,
  text q11 **1.13**.
  **BOTH GATES ON ALL TEN CELLS.**
  plain -> context deltas: TEXT Q11 0.96 -> 1.13 (the failing cell
  flips back), text q10 1.30 -> 1.52, html 1.04 -> 1.07 / 1.38 -> 1.44,
  json 1.02 -> 1.04 / 1.42 -> 1.46, source 1.25 -> 1.30 / 1.73 -> 1.79;
  binary unchanged (2.31 -> 2.32, 2.91 -> 2.90 - no GC tax there).
  q0-q9 byte-identical 35/35 between the two sweeps.

Supporting battery at r147: 241/241 tests (including the Rev 146
multi-threaded suite), bt-min 8/8, repro-split clean, byte-identical
sizes on all 8 corpora, ramp 325.

## Rev 148: q0-q9 speed campaign opens - diagnosis + first type fixes

Scope now (user decision): reach BOTH gates (ratio <= 1.10 AND speed >= 1.0)
on all 45 cells (5 corpora x 9 levels), by matching C's algorithm and adding
SIMD VOPs.  The old "q0-9 byte-identical to r147" constraint is superseded:
output may change, guarded by the ratio gate.

Diagnosis (html 1 MiB, pooled compressor, sb-sprof + instrumentation):

* Probe counts: q9 = 7,551,245 chain probes over 92,195 positions = 81.9
  probes/position at max-chain 128, ~5.7 ns/probe (~24 cycles); probe-ok
  rejects 96.4% before MLEN.  q5 = 755,695 chain + 707,996 cache probes,
  12.5% reach MLEN.
* Codegen fat in the probe loop (replica disassembly, 0 CALLs so probe-ok
  and the match-length VOP are inlined): (- N POS) recomputed from two spill
  slots EVERY probe, SAP base reloaded 3x, BEST-LEN untagged twice - ~6-8 of
  ~20 probe instructions redundant.  The INS label shows the same disease
  (repeated SARs, double array-base loads), matching Rev ~714's
  "fixnum-tag arithmetic and spill profile" note.
* C side (ChooseHasher): our gate = lgwin 22 + 1 MiB => H6 =
  hash_longest_match64 with num_last_distances_to_check = 4/10/16 at
  q5/q6/q9 (we run score at q5/q6 only, checks=4; q7-q9 run greedy with 1
  cache check), bucket walk bounded by block_size = 2^(quality-1) with
  PREFETCH_L1, 1-byte probe at best_len (normalised >= 3), score selection.
* GAP's own record: enabling the score matcher at q7/q9 previously cost -25%
  speed for -1.2% size, because score-accepted best-len is lower than greedy,
  which weakens probe-ok and blows up MLEN scans.  => SIMD MLEN first (16
  bytes/iteration), which is what removes that penalty, then C's selection.

Also fixed (committed): missing type declarations that left the generic
hairy accessor in hot code - PLAN-COMMANDS' LIT-CMAP (every CMAP variant is
a #(...) literal vector or NIL): hairy refs 1 -> 0.  Writer declares added
for CMD-SYMS/DIST-SYMS/ITYPES/ILENS/DTYPES/DLENS (SBCL had already derived
these; its 6 remaining hairy sites are cold fallback paths, ~2.8% at q5).

Verified: 241/241 tests, bt-min 8/8, repro-split clean, ALL 45 CELL SIZES
BYTE-IDENTICAL (check45 harness, reference = r147 sweep).

## Rev 149: SSE2 match-length VOP - gate cells all improve, bit-identical

The %MATCH-LEN-SAP template is now a three-stage SSE2 sequence: 16-byte
PCMPEQB/PMOVMSKB loop, then the 8-byte word loop for the 8..15-byte
remainder, then the byte tail.  Every load is guarded by len+K <= maxl, so
reads stay inside the vector (maxl = N-B and A < B imply A+len+K < N).

* Correctness: 0 mismatches vs the reference body on 300,000 random pairs
  (structured regions so matches of every length occur, zero runs for the
  ctz edge) plus an exhaustive a<b, bound sweep.  All 45 gate cell sizes
  BYTE-IDENTICAL; 241/241 tests; bt-min 8/8; repro-split clean.
* CPU requirements: PCMPEQB/PMOVMSKB/MOVDQU are SSE2 = baseline x86-64, so
  this runs on every x86-64 CPU (no BMI1/SSE4.2/AVX).  The only
  non-baseline instruction is TZCNT (BMI1); its F3-prefixed encoding is
  architecturally executed as BSF on pre-BMI1 CPUs, and both uses here have
  a provably non-zero operand (word-loop XOR non-zero by branch; SSE mask
  non-0xFFFF by branch) where BSF and TZCNT agree - same argument as the
  match-length template had before, now stated for both sites.
* Micro-benchmark (2.2M calls, half long matches): 1.60x the old 8-byte
  word-loop template (both confirmed inlined: PCMPEQB vs TZCNT).
* Gate sweep vs r147 (same method): q10/q11 ALL IMPROVED - binary q11
  2.98 -> 3.16, html q11 1.45 -> 1.50, json q11 1.48 -> 1.53, source q11
  1.81 -> 1.85, text q11 1.14 -> 1.17, html q10 1.07 -> 1.09, text q10
  1.54 -> 1.57; ratios unchanged (45/45 <= 1.10, zero flips).
* The same sweep showed binary q5/q6/q7 -0.09/-0.08/-0.09, but a
  controlled A/B (identical harness, both orders) proves that was load
  noise (load 0.87): binary q5 33.07 -> 35.61 MiB/s (+7.7%), q6
  29.83 -> 29.90, q7 33.51 -> 33.97 (+1.4%).

Why this matters beyond its own gain: the probe filter's strength is what
keeps MLEN rare (3.6% of chain probes at q9).  Adopting C's cheaper 1-byte
probe makes MLEN run far more often - affordable only once MLEN is cheap,
which is what this VOP provides.  SIMD first, then C's selection.

## Rev 150: C-style probe + chain-depth tuning - q9 flips to passing (17/45)

Three changes, each measured:

**1. C-style probe (byte-identical).** PROBE-OK now tests the single byte
at MAX(BEST-LEN, 3) for BEST-LEN >= 3 - C's FindLongestMatch filter -
instead of the old 4/8-byte window.  Equivalence argument: both filters are
necessary conditions for an improving match, so a candidate rejected by the
old window has MLEN <= BEST-LEN anyway and could never update; the weaker
filter only permits more MLEN calls, whose results are identical.  The
BEST-LEN < 3 branch keeps the exact old 4-byte window, because a byte-3-only
test there WOULD change outcomes (MLEN could return 1..3 and update a short
BEST-LEN the old window suppressed).  Verified: ALL 45 cell sizes identical.
Measured alone: a wash - it nearly doubles MLEN at q9 (272,664 -> 487,105),
canceling the ~10 instructions/probe it saves (html q5 +1.6%, q6 -4.7%,
q9 -4.3%).  Kept because it is C's shape and pays off together with SIMD
MLEN (Rev 149) once BEST-LEN runs high.

**2. C's score matcher at q7-q9: IMPLEMENTED, MEASURED, REJECTED for
speed.**  quality-params for q7/q8/q9 gained :score-p t with
:checks 10/10/16 - exactly ChooseHasher's num_last_distances_to_check for
H6 (our gate = lgwin 22 + 1 MiB).  Result: ratio improved (binary q7/q9
1.051 -> 1.014, source q9 1.006 -> 0.992, html q7 1.062 -> 1.055) but speed
collapsed -29% (q7: 37.76 -> 26.77) and -39% (q9: 18.74 -> 11.44), matching
this file's old warning.  Composition measured at q9: 136,964 searches
(1.8/position - the lazy delay loop is already C-faithful), 1.74x the
probes, 2x the MLEN calls (272,664 -> 529,067), find-match-score = 84.3% of
runtime.  C affords the same structure because its per-probe is ~2x cheaper;
ours needs the codegen pass first.  Reverted to greedy at q7-q9 pending
that work - recorded here so the next session does not re-derive it.

**3. Chain depth at q9: 128 -> 48 (the lever that flips the cell).**
Greedy + chain48 measured on all five corpora (ours vs C core):
  binary 30.34/22.7 = 1.34x, ratio 1.051
  html   29.55/23.5 = 1.26x, ratio 1.064
  json   27.35/21.6 = 1.27x, ratio 1.015
  source 59.81/49.2 = 1.22x, ratio 1.014
  text  367.6/171.8 = 2.14x, ratio 1.025
Speed swept at chain 32 was higher still (html 1.48x) but pushed html's
ratio to 1.089 - only 0.011 of headroom - so 48 ships for balance.

**SWEEP (ground truth, load 0.83): BOTH GATES 17/45 (was 13).**
  q9: ALL FIVE PASS both gates - html 0.69 -> 1.06, json 0.72 -> 1.06,
  source 0.88 -> 1.14, binary 0.96 -> 1.21, text 2.17 -> 2.26.
  q10/q11: all pass, improved again (binary q11 2.98 -> 3.09, html q11
  1.45 -> 1.50, json 1.48 -> 1.53).
  RATIO: 0 failures across all 45 cells (worst binary q10 1.096).
  Remaining 28 speed fails: q0-q2 = 13 cells (0.30-0.91x), q5-q7 = 15
  cells (0.51-0.84x).  q7 sits closest of those (0.67-0.84).
Verified: 241/241 tests, bt-min 8/8, repro-split clean.

## Rev 151: StoreRange loop hoist + q7 chain 16 - BOTH GATES 18/45

**StoreRange loop (byte-identical).**  Instrumentation showed the interior
position store loop runs 15-51x PER COMMAND: text q7 = 166,196 iterations
for 3,249 commands, html q7 = 944,698 for 52,191, binary q7 = 815,277 for
55,962.  It was paying three per-iteration decisions that are all loop
invariant: the BT branch, the SAP-hash bounds test inside the HASH label,
and a label call to INS.  Now: three hoisted loop variants (BT / SAP-hash /
tail-hash) with INS inlined (its body is exactly head+prev maintenance).
Equivalence for the hash hoist: %HASH4-SAP uses the low 40 bits of its
8-byte load - bytes i..i+4 - and %HASH4-TAIL rebuilds exactly that value
from five byte loads, so whichever variant runs for a given range the hash
value is identical.  Verified ALL 45 cell sizes byte-identical against the
pre-change tree (chain tuning held constant).
Measured: source q7 +9.0% (73.96 -> 80.64 MiB/s), text q7 +6.5%
(378.8 -> 403.2), html q5 +3.4% (40.85 -> 42.23), html q7 +1.3%.

**q7 max-chain 24 -> 16** (ratio-gated, output changes): html's ratio goes
1.062 -> 1.0997 - at the cap, kept because html fails speed either way
(0.95-0.99x) and the other four corpora have headroom (binary 1.052,
json 1.025, source 1.022, text 1.028).  Chain 12 was rejected: it would
push html over 1.10.

**SWEEP (load 1.19 - higher than r150's 0.83, so deltas understate the
gain): BOTH GATES 18/45 (was 17); RATIO 0 failures (worst html q7 1.0997).**
  q7: json 0.83 -> 1.00 PASSES; html 0.84 -> 0.95; binary 0.81 -> 0.87;
  source 0.80 -> 0.82; text 0.67 -> 0.69.
  Controlled timing2 runs at lighter load put binary q7 1.05x and json q7
  1.08x, html q7 0.99x - i.e. three of five q7 cells are at/near parity.
  q10/q11 unchanged and passing; q9 unchanged and passing.
Verified: 241/241 tests, bt-min 8/8, repro-split clean.

Next queued (byte-identical): INCOMPRESSIBLE-P's `(make-array 256)` is an
untyped simple-vector, so its 16K-sample loop does boxed read+write per
byte on every compress call - type it fixnum.  Then the q5/q6 command path
(emit-normal 13-23% + plan 6-8% + writer 6-8%) and the q0-q2 fragment
path (structural: one-pass emission per the older notes).

## Rev 152: kill the remaining generic array dispatch (writer 6->0, split-block 0)

The tree report for html q5 attributed ~5% of samples to
VECTOR-HAIRY-DATA-VECTOR-REF under WRITE-COMPRESSED-BLOCK-BODY and
SPLIT-BLOCK.  Root cause: arrays-of-arrays - a SIMPLE-VECTOR holding
fixnum arrays, so the inner AREF's element type is unknowable and SBCL
dispatches through the generic accessor on every use:

  (incf (aref (aref histos curr-ix) sym))            ; split-block tally
  (replace (aref histos last-ix0) scratch)           ; split-block merge x2
  (aref (aref lit-rcl cid) sym) / lit-lnl            ; literal codes/lengths
  (aref crc ...) where crc = (aref cmd-rcs itype)    ; command codes/lengths
  (aref drc ...) where drc = (aref dist-rcs dtype)   ; distance codes/lengths

All eleven sites now carry (THE (SIMPLE-ARRAY FIXNUM (*)) ...) - every one
of those arrays is a fixnum array (REVERSE-CODES returns fixnum, the histos
are :ELEMENT-TYPE 'FIXNUM, +EMPTY-FIXNUMS+ is declared), so the assertion
is always true and merely teaches the compiler.  Also INCOMPRESSIBLE-P's
`seen` histogram: an untyped simple-vector made all 16K sample iterations
do a boxed read + boxed write; now a fixnum array (same counting).

Verified: writer hairy 6 -> 0, split-block -> 0 (disassembly); ALL 45 cell
sizes BYTE-IDENTICAL; 241/241 tests; bt-min 8/8; repro-split clean.

Measured (timing2, controlled): html q5 +7.6% (42.23 -> 45.45 MiB/s),
html q7 +5.5% (40.19 -> 42.81), binary q7 +4.2% (36.13 -> 37.65),
text q7 +5% (410 -> 431), source q7 +4% (80.64 -> 83.89).

**SWEEP (load 0.79): BOTH GATES 19/45 (was 18); RATIO 0 failures.**
  html q7 0.95 -> 1.01 PASSES (with json q7 1.10) - q7 now 2/5.
  q5 improves across the board (json +0.07, source +0.04) but still
  0.57-0.69x.  q10/q11 unchanged and passing (binary q11 3.10 -> 3.27).
Remaining 26 speed fails: q0 = 3 (0.31x), q1 = 5 (0.36-0.93),
q2 = 5 (0.37-0.61), q5 = 5 (0.57-0.69), q6 = 5 (0.55-0.61),
q7 = 3 (binary 0.91, source 0.90, text 0.73).

## Rev 153: hoist PROBE-OK's per-call invariants (psap/maxl)

PROBE-OK took (CAND POS BEST-LEN) and, on every one of the 7.5M+ chain
probes per compress, re-derived two loop invariants: the POS-side load
address (untag POS + add + base) and the bounds check (N - POS).  It now
takes PSAP = (SAP+ POS) and MAXL = (N - POS), computed ONCE per search by
FIND-MATCH / FIND-MATCH-SCORE before their loops.  Equivalence (both
directions, so output cannot change):
  (< BEST-LEN MAXL)      ==  (<= (+ POS BEST-LEN 1) N)
  (>= MAXL 4)            ==  (<= (+ POS 4) N)
  (SAP-REF-8 PSAP B)     ==  (SAP-REF-8 SAP (+ POS B))   ; same address
  (SAP-REF-32 PSAP 0)    ==  (SAP-REF-32 SAP POS)
Signature is now (CAND BEST-LEN PSAP MAXL); five call sites updated.

Verified: ALL 45 cell sizes BYTE-IDENTICAL; 241/241 tests; bt-min 8/8;
repro-split clean; ratio 0 failures.
Measured: html q9 +3.9% (29.41 -> 30.56 MiB/s), binary q7 +2.8%,
html q5 +1.9%, html q7 +1.0%, source q7 0% (its cost is the command
path, not the matcher - consistent with the r152 profile).

Context - fresh profiles that drove this (html): q5 = find-match-score
43.1% / emit-normal 14.5% / plan-commands 12.2% / writer 11.0%; q7 =
find-match 53.7% / emit 13.1% / plan 7.7% / writer 7.6%; q2 =
write-trivial-block-body 37.7% / find-match 24.9% / emit 13.5%.
Two structural candidates assessed and DEFERRED with numbers: (a)
command-list -> fixnum-vector refactor (the two passes in
WRITE-TRIVIAL-BLOCK-BODY and PLAN-COMMANDS pay ~15 loads/command for
car/cadr/caddr/cadddr/cddddr plus the consing in EMIT-NORMAL; estimated
+6-8% across tiers but a 10+ site change with partition-commands and
dictp's boolean semantics to preserve); (b) C's score matcher at q7-q9,
already measured at -29%/-39% in Rev 150.

## Rev 154: +Q0-CMD-MAP+ type declaim (+9% on q0) - and a FAILED experiment

**Win: one missing DECLAIM.**  +Q0-CMD-MAP+ is a DEFPARAMETER holding a
fixnum array with no type declaration.  SBCL reads a symbol's value at
runtime, so without the declaration it can never open-code the reference:
every (AREF +Q0-CMD-MAP+ CC) in %LZ77-FRAGMENT's per-command emit loop
went through VECTOR-HAIRY-DATA-VECTOR-REF - 5.6% of q0's samples (the
fragment's only hairy site, confirmed by disassembly: 1 -> 0).
(declaim (type (simple-array fixnum (64)) +Q0-CMD-MAP+)) fixes it.
A sweep of every DEFPARAMETER/DEFVAR in src/ for the same defect found no
other HOT one (the length-code tables are declared, +LUT0/1/2+ are
declared, the rest are cold or load-time).

Verified: fragment hairy 1 -> 0; ALL 45 cell sizes byte-identical;
241/241 tests; bt-min 8/8; repro-split clean; ratio 0 failures.
Measured (two independent sweeps, r154 vs r152, median per level):
  q0 = 1.094 (+9.4%) - binary 0.31 -> 0.36, html 0.32 -> 0.35,
  json 0.31 -> 0.33, source 1.33 -> 1.49, text 6.00 -> 6.15-6.81.
  q1 = 1.000 (its emit path is WRITE-FAST-BLOCK-BODY, which does not
  use the map), q2 = 1.021, q5 = 1.035, q6 = 1.017, q7 = 0.989,
  q9 = 0.984, q10 = 1.000, q11 = 0.995 (all within run noise except q0).

**FAILED - do not re-derive: rotating P1/P2 in the literal loops.**
PLAN-COMMANDS and the writer re-read (AREF DATA (1- I)) / (AREF DATA
(- I 2)) per literal; the obvious fix is C's rotating-register form with
pre-loop initialisation (byte-identical, and it did compile and pass
check45).  Measured SLOWER on every cell: html q7 -2.1%, source q7
-4.0%, text q7 -3.3%, html q5 -1.1%, html q9 -0.5%.  Reason: the
original's two loads are independent (hidden by the OoO engine, L1 hits
on sequential data), while the rotation creates a loop-carried
dependency chain (p2<-p1<-sym) that serialises CID computation every
iteration.  Fewer instructions, worse critical path.  Reverted.

**Methodology finding (gate stability):** sweep-vs-sweep on this
13-user box is load-confounded.  html q7 read 1.01 (r152), 0.92 and
0.99 (two r154 runs) while the controlled timing2 A/B for the same
code read 43.86 MiB/s = 1.06x - i.e. the cell straddles 1.0 with
+/-5% run variance and the total gate count can swing 18 <-> 19 from
load alone.  Both r154 sweeps agreed on **18/45 with 0 ratio failures**
(the passing set differed from r152 only by html q7 at the boundary).
Recorded per-level medians above so future comparisons use them rather
than single cells.

## Rev 155: inline EMIT-ONE's local flets + single +Q0-CMD-MAP+ lookup (q0 +4-17%)

The q0 profile showed CMD-BITS (12.0%) and LITS (6.4%) as their OWN
profile entries - i.e. the three local flets inside %LZ77-FRAGMENT's
EMIT-ONE (CMD-BITS / DIST0-BITS / LITS) were never inlined, so every
command paid a local-function call (plus argument marshalling) on top of
the bit writes.  Two changes, both byte-identical:

1. (DECLARE (INLINE CMD-BITS DIST0-BITS LITS)) as the first form of the
   flet body - the bit-writers themselves (%WBITS-RAW / %WBITS-RAW-PM)
   were already declaimed inline in bitio.lisp, so the flet boundary was
   the only thing left preventing the compiler from seeing through it.
2. CMD-BITS looked up (AREF +Q0-CMD-MAP+ CC) TWICE (once for the code
   array, once for the length array); now bound once.

Verified: ALL 45 cell sizes byte-identical; 241/241 tests; bt-min 8/8;
repro-split clean; ratio 0 failures.
Measured (timing2): html q0 183.82 -> 198.41 MiB/s (+7.9%), json q0
223.21 -> 260.42 (+16.7%), binary q0 171.23 -> 178.57 (+4.3%).
q1 is unaffected (its emit path is WRITE-FAST-BLOCK-BODY, not EMIT-ONE).

Also recorded: timing2 itself shows +/-8% run variance on boundary cells
(source q1 read 0.996x, then 1.075x, then 1.05x on three consecutive
runs of identical code) - so single-cell timing claims need either the
controlled A/B (both orders) or the sweep per-level medians.

## Rev 156 (experiment, reverted): inlining FIND-MATCH / FIND-MATCH-SCORE / EMIT-NORMAL

The q5/q7 profiles showed FIND-MATCH-SCORE (43.1% of q5), FIND-MATCH
(53.7% of q7) and EMIT-NORMAL (13-15%) as their OWN label entries -
i.e. never inlined, so every position paid a local call.  The labels
block already carries (DECLARE (INLINE hash ins mlen mlen2 probe-ok ...)),
so the three big labels were added to that list.

Result: inlining DID take effect - the three entries vanished and %LZ77
self jumped 3.6% -> 60.5%.  But a controlled A/B (both orders, minutes
apart, same harness) shows a WASH:
  html q5  45.79 -> 45.13 MiB/s  (-1.4%)
  html q7  43.86 -> 43.25 MiB/s  (-1.4%)
  html q9  30.12 -> 30.94 MiB/s  (+2.7%)
Local static-fn calls were already ~5 cycles; the code bloat (three
large functions duplicated at 3-4 call sites each, %LZ77 far past L1i)
apparently offsets the call removal.

REVERTED, for a second reason that outweighs the wash: the split profile
entries are the campaign's primary diagnostic - every decision since
Rev 148 (matcher vs command path, per-tier lever choice) came from
FIND-MATCH / FIND-MATCH-SCORE / EMIT-NORMAL percentages.  Collapsing
them into one 60.5% blob would blind future iterations for no speed.

Lesson: measure profile STRUCTURE, not just speed, when trading away
instrumentation-friendly code shape.

## Rev 157: first true assembly-vs-assembly comparison (q0 tier) - and a failed exploit

Asked whether we compare COMPILED CODE, not just profiles: yes now.
Method: gcc -O2 -S the real c/enc/compress_fragment.c (our q0 counterpart
is BrotliCompressFragmentFastImpl15 - table_bits 15, matching our q0's
fragment table), and disassemble our %LZ77-fragment; compare loop by loop.

WHAT C'S ASSEMBLY SHOWS (cf.s, Impl15 at line 702):
* Interior hash stores: C does ONE UNALIGNED_LOAD64LE(ip-3) and derives
  all four hashes from it via HashBytesAtOffset(input_bytes, 0/1/2/3,
  shift) - the offsets are LITERALS, so gcc folds them to immediate
  shifts.  Ours called HASH once per position: a fresh 8-byte load each
  time, plus loop overhead.
* IsMatch is emitted as `cmpl %reg, (mem)` - one load folded into the
  compare instruction (5 sites); our PREFIX-MATCH issues two explicit
  loads plus compares.
* C checks the copy distance ONCE after the trawl loop; we test
  (<= (- p c2) window) on EVERY trawl iteration (sub + cmp + branch).
* Total code: C's Impl15 = 1,503 instructions; our %LZ77-fragment =
  3,449 (2.3x).  Part of it is real: our function carries BOTH the
  one-pass and two-pass paths (`if w` everywhere) while C keeps them in
  separate translation units.

FAILED EXPLOIT - DO NOT RE-DERIVE: batching the interior hash stores
(one load, four literal-offset hashes, group of four) was implemented
twice:
  a) runtime offset into %HASHF-ONCE/FROM: 21-29% SLOWER - the runtime
     offset turns `(ash bytes (- (* 8 d)))` into a 3-cycle VARIABLE
     shift, while the loads it replaced are L1 hits (cheap).
  b) literal offsets 0/1/2/3 (as C does): still 3.1% (html) / 5.9%
     (json) SLOWER, binary +1.4% - the batching structure (double
     bounds condition, group index arithmetic, four separate table-index
     computations) costs more than the load it removes.
Conclusion: the per-position loads were never the bottleneck; C's edge
in this loop is denser surrounding code, not the load count.  Both
versions reverted; tree back to r156 state, 45/45 byte-identical.

HONEST ANSWER TO "why still 0.4": the gap is structural, not a single
instruction.  Our scan loop is ~45-55 instructions/iteration vs C's
~35-40 (window check every iteration vs once; extra last-distance
guards; loop bookkeeping), our function is 2.3x the code, and the emit
half (47% of q0) writes through a struct that C keeps in registers.
Closing q0 needs C's exact loop shape - straight-line emission with
next_emit tracking and a single-path function - i.e. the rewrite GAP
already records as the q0/q1 structural remainder, not more micro-tuning.

## Rev 158: narrow SHIFT's declared range - the generic ASH dance dies (q0 +3.3%, q9 +2.8%)

Direct fallout of the Rev 157 assembly comparison.  Our hash ended with
this sequence, executed ONCE PER HASH (every trawl iteration and every
interior store):

    MOV RCX, [RBP-104] / SAR RCX, 1     ; load + untag the shift variable
    TEST RCX, RCX / JNS ...             ; sign check
    NEG RCX / CMP RCX, 63 / JBE ...     ; clamp for |shift| > 63
    XOR EAX, EAX                       ; -> 0
    SHR RAX, CL  |  SHL RAX, CL        ; the actual variable shift

That is SBCL's generic (ASH X Y) expansion for a Y of unknown sign - ~9
instructions and 3 branches - while C emits a single `shr %cl`.  But
SHIFT is (- table-bits 64) / (- hbits 64), i.e. always in -63..-1 for
table-bits/hbits in 1..63 (ours are 15/17).  Declaring the actual
range:

  %LZ77-FRAGMENT: (type (integer -63 -1) shift)
  %LZ77:          (type (integer -63 -1) shift)

lets the compiler emit one SAR/SHR by CL with no sign check, no clamp
and no branches - the arithmetic semantics are unchanged (still an
arithmetic shift), so output cannot move.

Verified: sign-dance patterns in the %LZ77-FRAGMENT disassembly 8 -> 1;
ALL 45 cell sizes BYTE-IDENTICAL; 241/241 tests; bt-min 8/8;
repro-split clean; ratio 0 failures.
Measured: html q0 198.41 -> 204.92 MiB/s (+3.3%), html q9
30.12 -> 30.94 (+2.8%), html q5/q7 flat.

Lesson for this codebase: a runtime parameter that is provably bounded
(a shift derived from a small table size) must carry that bound in its
TYPE, or SBCL pays the generic expansion at every use - and in a hash
called a million times per compress, that is the whole ballgame.

## Rev 159 (diagnostics): we scan FEWER positions than C - the gap is per-operation cost

Instrumented BOTH sides (temporary counters, reverted; C built from the
real source with gcc -O2 -lm):

  trawl iterations, 1 MiB q0:
    html    C = 32,548 + 65,038 = 97,586   (C chunks input at 512 KiB -
            BrotliCompressFragmentFast is called twice; ours is one pass)
            ours = 56,708                   (58% of C)
    binary  C = 184,417 + 205,561 = 389,978
            ours = 202,154                  (52% of C)
  match attempts (emits): html q0 = 19,636 (53.4 bytes/emitted),
            binary q0 = 38,446 (27.3 bytes/emitted)

CONCLUSION: the q0 gap is NOT "we do more work" - we scan HALF as many
positions as C and still take 2.3x longer.  It is per-operation cost,
and the emit half (47.4% of q0) is where the measurement points.

Per-LITERAL cost, counted from both disassemblies (emit-one inlined into
%LZ77-FRAGMENT for the measurement, then reverted):
  ours ~29 instructions:
    3 stack-slot array-base reloads ([RBP-8] data, [RBP-144] lit-rc-1p,
        [RBP-152] lit-ln-1p - frame spills, reloaded EVERY literal)
    3 SAR untags (sym/value/nbits)
    3 struct slot ops ([R9+29], [R9+21], [R9+13] - the bwr state)
    emit calculation (nbits >> 3 + AND) + flush test
  C    ~14 instructions:
    3 table reads (depth[u8], bits[u16], input[j] - register bases)
    BrotliWriteBits: pos>>3 address, one byte load, shift+or,
    UNALIGNED_STORE64LE, *pos += n_bits

FAILED EXPERIMENT - DO NOT RE-DERIVE: (declaim (inline w-emit-run
w-ensure)) to remove the writer's escape points so SBCL could scalar-
replace the bwr struct into registers.  Byte-identical, but neutral
(html q0 -1.6%, q5 0%, q7 -1%, q9 +0.3%) - SBCL does not SRA a struct
that is captured by a closure (emit-one captures W from the enclosing
function's parameter list).  Reverted: a wash that also bloats code.

THE FIX THAT REMAINS: thread the bit-writer state (acc/nbits/pos) as
LEXICALS through EMIT-ONE's bodies - a state-threading write primitive
returning (values acc nbits pos), with a single write-back to W at the
end (and a flush/reload around the non-inline W-EMIT-RUN calls).  That
takes the per-literal path from ~29 instructions to C's ~14 (register
bases, no per-literal SARs, no per-literal struct slot traffic) and is
estimated +25-35% on q0 - the largest single measured lever left.

## Rev 160: state-threaded EMIT-ONE (acc/nbits/pos as lexicals) - q0 +0.8..+3.1%

Implements the fix Rev 159 recorded: while W escapes to the non-inline
W-EMIT-RUN, every bit write reloaded the BWR struct slots (3 stack
loads + 3 untags per literal = ~29 instructions/literal vs C's 14).
EMIT-ONE now reads ACC/NBITS/POS from W ONCE, threads them as LEXICALS
through two macros (WR-PM / WR-RAW - exact transcriptions of
%WBITS-RAW-PM / %WBITS-RAW, same arithmetic, same flush), writes back
to W once at the end, and flush/reloads only around W-EMIT-RUN.

BUG FOUND AND FIXED DURING IT (lesson for this codebase): declaring the
running NBITS as (INTEGER 0 7) let SBCL delete the (LOGAND NBITS 7)
mask inside the macros - NBITS transiently exceeds 7 on every flush
(before the mask), so the unmasked value fed the next (ASH V NBITS)
and corrupted the bit stream ("dictionary copy length 2 out of
range", then a segfault).  The 0..7 bound holds only for the ENTRY
value; the running variable must stay a plain FIXNUM and the macros
assert (THE (INTEGER 0 7) pr) at the shift site instead.

MEASURED (controlled A/B, interleaved A B A B - drift would be
monotonic, not variant-correlated; each variant repeated exactly):

  spec        A=r158           B=threaded      delta
  binary q0   186.57 186.57    192.31 192.31   +3.1%
  html q0     195.31 198.41    198.41 198.41   +0.8%
  json q0     255.10 250.00    255.10 255.10   +1.0%
  html q1     152.44 147.06    148.81 154.32   +1.2% (noisy)

An earlier single-shot reading of binary q0 +11% was load noise; the
controlled number is +3.1%.  The Rev 159 prediction of +25-35% did NOT
materialize - the per-literal instruction count drops but the emit path
is not the whole q0 story (the scan loop's 45-55 vs C's 35-40
instructions/iteration remains, see Rev 157).

Verified: ALL 45 cell sizes BYTE-IDENTICAL; 241/241 tests; bt-min
8/8; repro-split clean; ratio45 0 failures (worst 1.100 html q7).

## Rev 161 (sweep): r160 state = 19/45 both gates, 0 ratio failures

Full 45-cell gate sweep (5 corpora x q0,1,2,5,6,7,9,10,11 @1MiB) after
r155 + r158 + r160 (all previously unswept).  vs r154b (18/45):

  SPEED FLIPS IN:  HTML q7   0.99 -> 1.01   (ratio 1.100, at cap)
                   TEXT q7   0.73 -> 1.38
  FLIPS OUT:       none
  q10/11 gates:    all pass (speed + ratio)
  ratio > 1.10:    0 cells (worst 1.100 HTML q7)

Per-level median speed (lisp/C), old -> new:
  q0 0.36 -> 0.40   q1 0.47 -> 0.50   q2 0.47 -> 0.45
  q5 0.68 -> 0.68   q6 0.59 -> 0.61   q7 0.99 -> 1.09
  q9 1.23 -> 1.26   q10 1.35 -> 1.34  q11 1.54 -> 1.54

Remaining 25 speed fails: q0 x3 (0.36-0.40), q1 x5 (0.40-0.95),
q2 x5 (0.36-0.65), q5 x5 (0.61-0.79), q6 x5 (0.60-0.64),
q7 x2 (binary 0.92, source 0.90).  q9/q10/q11 clean.

CAVEAT: TEXT q7's +0.65 swing is larger than r155/158/160's measured
effects on q7 (all ~flat) - likely load (r154b swept at 02:33, this at
08:40, load 0.19).  Treat both q7 flips as boundary cells; re-confirm
in the next sweep before building on them.

## Rev 162 (experiment, reverted): (declare (inline emit-one)) - REGRESSION

Post-r160 profile of html q0 said EMIT-ONE self = 53.3% (scan = 38.3%),
with EMIT-ONE visible as its own profile entry (i.e. not inlined) - so
the obvious next step was to inline it (r159 had only inlined it for
DISASSEMBLY, never timed it).

Declared (inline emit-one) in the fragment's labels declare.

Verified: compiles clean, EMIT-ONE vanishes from the profile (92.7%
self moves into %LZ77-FRAGMENT), ALL 45 BYTE-IDENTICAL.

MEASURED (controlled A/B, interleaved A B A B):
  spec        A=r160          B=inline       delta
  html q0     198.4 201.6     195.3 198.4    -1.5%
  binary q0   192.3 198.4     186.6 183.8    -5.2%
  json q0     260.4 260.4     231.5 235.9    -10.1%
  html q1     154.3 156.3     152.4 143.7    -5.5%

CONSISTENT REGRESSION on every spec.  Why: the body duplicates at its
4-5 call sites inside an already 3,449-instruction function (icache),
and merging EMIT-ONE's live ranges with the scan loop's forces spills.
The function boundary was HELPING, not hurting - it acts as a register
window.  Reverted; tree back to r160, 45/45 byte-identical.

Lesson: "profile entry above 3% means not inlined" tells you where a
CALL is, not that removing the call is free - inline only after timing,
and only when the body is small relative to the caller.

## Rev 163: command list -> flat fixnum vector (q7 +9.5%, q2 +17.6%, q5 +13%)

The profile of binary q7 (the cheapest open gate cell) showed the command
MACHINERY, not the matcher: EMIT-NORMAL 13% self (conses a 5-element
list per command), PLAN-COMMANDS 10% (walks it with 5 pointer chases),
LIST-NREVERSE 1.5%, plus the GC of ~100k live conses per compress call.
C keeps commands in a flat array; the fragment already used one
(PUSH-CMD/cv) - only %LZ77 still built lists.

REFACTOR (three return shapes unified to one protocol - a flat fixnum
vector, 5 entries per command: ins lit-start cpy dist dictp, DICTP 0/1):
  * %LZ77: (cmds '()) -> geometrically-growing fixnum vector + NCMD;
    PUSH-CMD label replaces the 3 (push (list ...)) sites; the tail
    shrinks to exact size (SUBSEQ) so consumers derive NCMD = length/5.
    (NREVERSE gone - the vector is already in order.)
  * TINY-INPUT early return (n < min-match): (list (list n 0 0 0 nil))
    -> an exact 5-fixnum vector (THIRD shape, found the hard way).
  * BT/ZOPFLI branch (q10/11): Z-ITERATE returns 5-element lists with
    boolean DICTP -> wrapped in BLOCK->CMDS at the %LZ77 boundary
    (ZOPFLI-SET-FROM-COMMANDS still gets Z-ITERATE's list internally).
  * Consumers: PLAN-COMMANDS + WRITE-TRIVIL-BLOCK-BODY (x2 loops) iterate
    the vector; dictp truthiness NOT/OR -> ZEROP/PLUSP (0 is truthy!);
    typed (SIMPLE-ARRAY FIXNUM (*)) declare on CMDS or every AREF fell
    back to the generic accessor (r152 lesson).
  * >16MiB multi-meta-block path only: CMDS->LIST / BLOCK->CMDS adapters
    keep PARTITION-COMMANDS + SPLIT-COMMAND-AT list-based (cold).

BUGS FOUND DURING IT (both would have been silent corruptors):
  1. dictp semantics: consumers test (not dictp)/(or dictp ...) which are
     wrong for 0/1 fixnums - converted at all 6 sites; zopfli's own
     accumulator already used booleans (comment at its push site).
  2. q10's bt=16 path and the n<min-match path returned LISTS while
     PLAN-COMMANDS (safety 0 + vector declare) read them as vectors ->
     aref on a cons = heap corruption -> 618 GB bogus allocation.  Both
     fixed by converting at the producer boundary.

Verified: ALL 45 BYTE-IDENTICAL; 241/241 tests (incl. multi-threaded);
bt-min 8/8; repro-split clean; ratio45 0 failures (worst 1.100).

MEASURED (controlled A/B, interleaved A B A B, each pair exact-repeat):
  spec        A=lists        B=vectors      delta
  binary q7   35.71 36.66    39.94 39.43    +9.6%
  source q7   76.69 77.64    84.46 85.03    +9.5%
  html q2     77.16 75.30    88.65 89.29   +17.6%
  html q5     41.95 42.23    47.53 46.99   +13.0%
  json q10     2.34  2.39     2.43  2.41    +2.8% (BLOCK->CMDS conversion)

Beats the recorded +4-8% scope.  Projection: binary q7 0.92 -> ~1.01
(gate flip), source q7 0.90 -> ~0.985 (boundary), q2/q5/q6 all gain
13-18% but remain short of 1.0.

## Rev 164: fix r163's upfront-allocation regression (n/8 -> n/32 initial)

The r163 sweep (99 cells; gate = the usual 45) showed the vector
refactor LOSING ground on command-SPARSE corpora while winning on
command-dense ones - and my controlled A/B had missed it because I only
tested html/binary/source/json:

  sweep r160 -> r163, lisp MiB/s:  TEXT q2 713 -> 468 (-34%),
  TEXT q5 400 -> 289, TEXT q7 423 -> 296, TEXT q9 445 -> 289;
  DICT/PATTERN/PERIODIC/UTF8/ZEROS q2 ~1.05x -> ~0.40x C.
  Gate fallout: HTML q7 (1.01 -> 0.99) and TEXT q7 (1.38 -> 0.96)
  flipped OUT -> 18/45 (see correction below).

CAUSE: the initial vector (max 1024 (ash n -3)) = n/8 commands =
655,360 fixnums = 5.2 MiB allocated on EVERY %LZ77 call.  For
command-dense corpora that is a wash (the old list consed MBs anyway,
so the A/B there was valid: +11-17%).  For command-sparse corpora
(TEXT: ~hundreds of commands) the old cost was kilobytes of conses and
the new cost is a fixed 5.2 MiB large-object alloc + free every call -
0.8 ms of pure fixed cost on a 1.4 ms call (+63% measured by swapping
only this constant).

FIX: mirror the fragment's proven PUSH-CMD policy - initial capacity
(max 4096 (ash n -5)) = n/32 commands (160 KiB at 1 MiB, floor 20 KiB),
growth doubles, exact-size SUBSEQ at return stays proportional to the
real command count.

MEASURED (controlled A/B, interleaved A B A B):
  spec        A=r160 lists   B=vectors n/32   delta
  TEXT q2     781 694        781 781          +5.8%
  TEXT q5     390.6 390.6    416.7 390.6      +3.3%
  HTML q5     43.6 44.5      49.4 48.6       +11.5%
  BINARY q7   34.1 34.3      38.8 38.2       +13.4%
B >= A on every pair.  Verified: ALL 45 BYTE-IDENTICAL; 241/241;
bt-min 8/8; repro-split; ratio45 0 failures.

CORRECTION to Rev 161: the r160 sweep was 20/45, not 19 (45 cells -
25 speed fails = 20; the entry miscounted).  r163 = 18/45.

## Rev 165: hoist hot DEFPARAMETER tables + fragment trawl check reorder

Three byte-identical changes, each from a measurement:

1. LENGTH-CODE GLOBAL HOIST (q2 +2.4%): LENGTH-CODE is inline, but its
   five table args (+INS-CODE+ etc.) are DEFPARAMETERS - every call
   re-reads them from global cells (the zopfli path already bound them
   once; plan-commands and write-trivial did not - 4 calls x 5 globals
   = 20 re-reads per command in the trivial writer).  Bound once into
   lexicals in PLAN-COMMANDS, WRITE-TRIVIL-BLOCK-BODY, and (for
   +LUT0+/+LUT1+, read per literal) in WRITE-COMPRESSED-BLOCK-BODY's
   per-command binding.

2. FRAGMENT TRAWL REORDER (q1 +3.4%, q0 +0.8%): C checks the copy
   distance ONCE, after a prefix-match succeeds; we tested the window
   on EVERY trawl iteration.  Reordered the pure predicates so the
   window check runs only on a match, and dropped two provably
   redundant guards: (< c2 p) (the table only ever holds positions <
   the current p: stores are at the current p or interior q<p, p is
   monotone, the #xFFFFFFFF sentinel is excluded first) and (>= ld 0)
   (last-dist was a distance at some earlier p' <= p, monotone p; the
   (> last-dist 0) guard excludes the -1 initial).  All predicates are
   pure, so the accept/reject set cannot change.

3. EMIT-ONE CPY-ONLY LITS REMOVED: clause 2 of the cond guarantees
   insert=0, so (LITS) ran a zero-iteration loop + two tests on 78% of
   html q0 emits (70,846/90,483).  Writes nothing either way.

Verified: ALL 45 BYTE-IDENTICAL; 241/241; bt-min 8/8; repro-split;
ratio45 0 failures.  Controlled A/Bs (interleaved):
  hoist vs r164:        html q2 84.5/86.2 -> 88.7/87.4  (+2.4%)
  full vs hoist-only:   html q1 150.6/150.6 -> 158.2/156.3 (+4.3%)
                        binary q1 142.1/143.7 -> 145.4/147.1 (+2.4%)
                        html q0 +0.8%, html q2 +0.4%

Context: the r164 sweep is 19/45 both gates, 0 gate ratio failures
(TEXT q7 back in at 1.25x; html q7 boundary at 0.97 - it read 1.01 at
r160 and r154b read 0.99, so this cell is ±load noise per the Rev 161
caveat).  Sparse corpora fully recovered by the r164 alloc fix
(DICT/PATTERN/PERIODIC/UTF8/ZEROS q2 +0.13..0.21 each).

## Rev 166 (experiment, reverted): state-threading WRITE-FAST-BLOCK-BODY - NEUTRAL

Applied the r160 EMIT-ONE pattern (acc/nbits/pos as lexicals across the
command loop, wr-pm/wr-raw instead of %WBITS-RAW-PM/%WBITS-RAW, flush+
reload around W-EMIT-RUN, flush before W-ENSURE which reads BWR-POS) to
q1's writer, targeting WRITE-FAST's 31.1% self-share of source q1
(profile: fragment scan 52.5% + write-fast 31.1%).

Prediction was +4-7% (7 struct-slot ops x ~550k writes).  MEASURED
(interleaved A/B, A=r165): source q1 320.7 -> 320.5 mean (0.0%),
html q1 +1.0%, binary q1 -0.5%, json q1 exact ties.

NEUTRAL - reverted per the Rev 156 rule.  Why it failed where r160
succeeded: EMIT-ONE's reads/writes sat on a CALL boundary (reload
every command, values dead across the call), while write-fast's
inlined %WBITS-RAW-PM struct ops are straight-line L1 hits that the
out-of-order engine already hides - removing them changes the
instruction count but not the critical path.  Lesson: the r160 pattern
pays only where the state crosses a real function boundary; count the
boundary, not the slot accesses.

Boundary-cell status after r165: source q1 0.94, html q7 0.97 (both
need +3-6%); binary q7 0.86 / source q7 0.88 (+14-16%).  The q1/q7
profiles show no remaining single item of that size outside the
structural work (fragment single-path split; find-match's chain shape
vs C's H6 contiguous-bucket scan + 10-entry distance cache).

## Rev 167 (experiment, reverted BOTH variants): find-match -> C's H6 bucket-ring layout

The full structural rewrite of %LZ77's candidate storage to C's
HashLongestMatch layout (hash_longest_match64_inc.h), implemented
twice, both measured dead.  Profiles below are html q7 (the tier where
FIND-MATCH is the wall).

VARIANT A - byte-identical ring at OUR hash width (hbits 17):
head/prev replaced by a per-key ring (buckets2^(17+RB) x u32 + a
per-key store counter), walk visits the last min(count, max-chain)
stores newest-first.  Same stores, same order, same depth, same
selection -> output provably unchanged (confirmed: ALL 45 IDENTICAL,
241/241, bt-min, repro-split, ratio45 0 failures).

  INTERLEAVED A/B (A = r166 head/prev):
    spec        A=r166        B=ring17      delta
    html q7     46.8 45.5     37.4 38.0     -19%
    binary q7   39.4 38.5     33.3 31.5     -17%
    source q7   88.0 88.0     73.1 74.0     -17%
    html q5     49.6 48.5     40.9 40.9     -17%
  Profile split explains it exactly:
    FIND-MATCH self  52.2% -> 36.8%   (the WALK wins -30%: contiguous
                                        reads vs the prev[] chase)
    EMIT-NORMAL self 12.4% -> 32.0%   (the INSERTS lose: StoreRange's
                                        interior stores become RANDOM
                                        writes into an 8MiB ring plus a
                                        read-modify-write on a 1MiB
                                        counter, where the old code did
                                        an L2 head write + a SEQUENTIAL
                                        prev[q] write - write-combining
                                        friendly)
  Net -17%: the insert penalty (random writes are costlier than the
  reads they saved) outweighs the walk win.

VARIANT B - C's exact BUCKET_BITS=15 (ratio-gated, output changes):
key = (logand h #x7FFF), ring2^(15+RB) (2MiB at q7) + counter 256KiB -
C's cache footprint.  Roundtrip tests pass (241/241, bt-min,
repro-split) and size drift is small (binary q7 +0.19%) BUT:
  ratio45: 2 cells over the cap, worst 1.108 at html q7
  (was exactly 1.100 - the cap).  Coarser keys waste ring slots on
  15-bit collisions that fail PROBE-OK, so fewer real candidates are
  found at the unchanged depth 16 -> worse matches -> ratio breach.
FAILED THE GATE - reverted.

THE DEPTH ESCAPE HATCH IS ALSO DEAD: C pairs bucket_bits 15 with
block_bits = quality-1 (64 slots at q7), which refills the candidate
pool and is how C gets its better ratio from coarse keys.  But at our
window sizes (1MiB inputs, 2MB+ window) the ring's early `break` on
distance NEVER fires, so the walk visits every slot: ~32-64 steps/call
vs our measured 16.56 today - 2-4x the walk iterations on the function
that is already 52% of q7.  Speed-dead, and it still might not land
under html q7's 1.100 cap.

CONCLUSION (do not re-derive): C's H6 layout is coupled to C's three
levers at once - 15-bit bucket keys, per-quality deep rings, and ratio
headroom we do not have (html q7 is pinned AT 1.100).  At our hash
width the byte-identical ring is -17%; at C's width it breaches the
ratio gate; with C's depths it walks 2-4x further.  The prev[] chase
stays.  Recorded so neither variant is rebuilt.

## Rev 168: split %LZ77-FRAGMENT into FAST + TWO-PASS (C's separate TUs)

C keeps BrotliCompressFragmentFast (q0, one-pass) and
BrotliCompressFragmentTwoPass (q1) in separate translation units; our
single %LZ77-FRAGMENT carried both via `if w` at nine sites (Rev 157
recorded this as part of the 2.3x code-size gap vs C's Impl15).
Split into two defuns generated from the same source, each dropping
its dead half:

  %LZ77-FAST (280 lines): w required (the writer).  Drops cv/nc
    (the two-pass command vector - a 512KiB allocation q0 never
    wrote), the PUSH-CMD label, and all three two-pass emit arms;
    (WHEN w ...) header/tree block becomes unconditional; returns NIL
    (the caller discards it).
  %LZ77-TWO-PASS (162 lines): no w.  Drops EMIT-ONE (~100 lines of
    q0 command/distance emission + slack/W-ENSURE), the one-pass
    etree slots, and the header block; returns (VALUES CV NC LITF
    CMDF DISTF) as before for WRITE-FAST-BLOCK-BODY.

The scan loop (trawl/skip/interior stores) is unchanged in both; the
three emit arms become straight-line (no branch on w in the hot loop).

Verified: ALL 45 BYTE-IDENTICAL (q0 exercises FAST, q1 exercises
TWO-PASS - both covered); 241/241; bt-min 8/8; repro-split; ratio45
0 failures; compiles with zero warnings.

MEASURED (interleaved A/B, A = r166 dual-path):
  spec        A=r166        B=split      delta
  html q0     201.6 201.6   204.9 204.9  +1.6%
  binary q0   195.3 192.3   195.3 192.3   0.0% (exact ties)
  html q1     152.4 152.4   152.4 158.2  +1.9%
  source q1   304.9 304.9   312.5 312.5  +2.5%
No regressions.  The gain is smaller than Rev 157's "part of it is
real" implied: removing dead code + the q0 cv allocation buys ~2%,
not 10%+ - the scan loop's per-operation cost (Rev 157/159) remains
the structural gap at q0/q1.

## Rev 169: pool the output writer (C's storage_ reuse) - and the
## pre-size experiment that found it

EXPERIMENT 1 (reverted): C pre-sizes its buffer once per call
(GetBrotliStorage(s, 2*bytes+503)) and never re-checks capacity per
command, so WRITE-FAST-BLOCK-BODY and EMIT-ONE's per-command slack
checks + 64KiB-chunk growth looked like the C-mismatch.  Implemented:
one-time (b:w-ensure (+ (* 5 n) 32768)) [proven bound: an input byte
contributes <= max(15 literal bits, 113/5 amortized command bits) =
22.6 bits] and both slack checks removed.

  MEASURED: REGRESSION on every spec - source q1 -10%, html q1 -7%,
  html q0 -7.6%, binary q1 -5%.  Cause: the 5.2MiB large-object
  allocation costs ~0.35ms EVERY call on this box (r164's lesson,
  again) - more than the ~0.3ms of slack checks + growth copies it
  saved.  C's pre-size is free because GetBrotliStorage returns the
  ENCODER CONTEXT's buffer: C allocates once per encoder, not per
  call.  We had the sizing half but not the reuse half.

EXPERIMENT 2 (kept): ACQUIRE-BWR - one BWR per MAKE-COMPRESSOR
closure from *SCRATCH-POOL* (key :BWR, same eviction rules as
ACQUIRE-SCRATCH), POS/ACC/NBITS reset on every acquisition, OUT kept
at the high-water mark.  Plain COMPRESS still gets a fresh writer, so
the unpooled path is byte-for-byte the old behavior.  This is the
missing reuse half: the 64KiB -> output-size growth (alloc + copy)
now happens once per compressor instead of once per compress.

  Verified: ALL 45 BYTE-IDENTICAL; 241/241 (incl. the three MT
  tests - one private compressor per thread is the documented
  contract, and MAKE-COMPRESSOR-IDENTICAL-TO-PLAIN covers
  pooled-vs-fresh output identity); bt-min; repro-split; ratio45 0
  failures.

  MEASURED (interleaved A/B, A = r168):
    spec        A=r168        B=pooled     delta
    html q0     201.6 204.9   204.9 211.9  +2.4%
    binary q1   137.4 138.9   137.4 142.0  +1.9%
    html q1     154.3 156.3   154.3 158.2  +0.6%
    source q1   312.5 320.5   304.9 320.5  -1.2% (noise: one exact tie)

Lesson for the file: a C pattern often couples TWO properties - this
one is (size the buffer) AND (own the buffer for the encoder's
lifetime).  Porting only the sizing ported the cost.  Check which
half is doing the work before porting either.

## Rev 170: pool HEAD/PREV (C's encoder-lifetime hasher ownership)

C allocates its hasher arrays ONCE per encoder (HashMemAllocInBytes
-> common->extra[0]); we allocated HEAD (512KiB) + PREV (Nx4 =
4.5MiB at 1MiB) FRESH ON EVERY %LZ77 CALL - the Rev 164 allocation
cost, paid by all18 q2-q9 cells (and the gc_alloc_large 5.7% seen in
the html q5 profile is largely this).

ACQUIRE-HEADPREV: pooled per compressor under key (- N) (negative, so
it cannot collide with the scratch pool's positive-N keys); HEAD is
re-filled with the #xFFFFFFFF sentinel on every acquisition (a stale
position from another input would otherwise be read as a candidate),
PREV needs no reset - it is only ever read at positions this input's
INS wrote (every chain link was written by this input's own stores:
HEAD stores and PREV links are written together in INS and the two
StoreRange sites).  BT mode walks neither - it binds empty arrays so
the type declares stay honest.  Plain COMPRESS still builds fresh
arrays, exactly as before.

FIRST ATTEMPT FAILED HARD (-19..-26%, byte-identical): binding
HEAD/PREV as (CAR HP)/(CDR HP) defeated their type declarations -
the (IF BT ... ACQUIRE-HEADPREV) initializer's type is unknown, so
SBCL compiled every aref as an OUTLINED ACCESSOR CALL: profile showed
VECTOR-HAIRY-DATA-VECTOR-REF/SET + OPTIMIZED-DATA-VECTOR-REF/SET at
26% of source q7 (find-match self fell 35.7% -> 23.9% as its work
moved into those calls).  Fix: THE at the bindings -
  (head (the (simple-array (unsigned-byte 32) (*)) (car hp)))
restores open-coded access; the profile's accessor entries vanish
(find-match back to 38.7% self).

LESSON: a LET-binding declaration does not survive an initializer of
unknown type - assert with THE where the value is bound, or the
declaration is silently outvoted at every use site.

Verified (final state): ALL 45 BYTE-IDENTICAL; 241/241; bt-min;
repro-split; ratio45 0 failures.

MEASURED (interleaved A/B, A = r169):
  spec        A=r169        B=pooled hp   delta
  html q2     86.8 86.8     89.3 89.3     +2.9%
  source q7   91.2 90.6     90.6 94.7     +1.5%
  html q5     50.8 49.8     51.4 49.8     +0.6%
  binary q7   39.4 38.7     39.4 37.7     -1.3% (one exact tie, one
                                              -2.7% pair: noise)
Note the512KiB sentinel fill on every acquisition eats part of the
allocation saving - the net is +1..3%, not the projected +2..5%.

## Session 6 Nov 2026 (uncommitted, on top of r170 + the port.lisp diff): correctness first, then decoder and cliff fixes

Host changed: Ryzen 7 PRO 4750U, system SBCL 2.6.7, C Brotli 1.2.0, no
Roswell; GPL-3 / rclone MANUAL.html are absent, so TEXT and HTML fall back
(TEXT = tiled 4 KiB README, a degenerate corpus; HTML = fish relnotes.html).
Numbers below are not comparable with the 3700X tables above.

### Correctness and portability (found by a safety-3 build + fuzzing)

Method: copy src/, `s/(safety 0)/(safety 3)/`, load that copy (a fresh
path, so ASDF cannot reuse fasls - `restrict-compiler-policy` silently did
nothing here for that reason), on SBCL native, SBCL `:cl-brotli-portable`,
CCL and ECL; then a differential fuzzer (random sizes around 64 KiB, 4 data
kinds, q0-q11; both decoders, compress-into, pooled identity, C streams) and
a mutation fuzzer (1-4 random byte edits of C and Lisp streams, outcome
compared with the C decoder).

Encoder:
1. `bigram-context-map` multiplied BOTH prev and cur class by 3: indices up
   to 12 in a 9-slot histogram (an out-of-bounds heap write at safety 0 on
   every q5+ input >= 64 bytes) and a wrong histogram, so the q5-q9
   literal-context decision did not follow C.  Now C's
   `histo[prev + lut[b>>6]]++, prev = lut[b>>6]*3`.
2. `%hash4-tail` / `%hashf-tail` read DATA[N] for the last position
   (5-byte hash, last = n-4): output depended on whatever followed the
   vector in memory (the CCL "pooled call differs" failures).  Past-end
   bytes now read as 0 (C's zero-filled ring-buffer slack).
3. `%hashf-tail` computed `(logand x (ash 1 64) (1- (ash 1 64)))` = 0
   always, and both tails omitted the `<< 24` of the SAP hashes, so tail
   positions were stored under different buckets than they were looked up
   in.  Both now equal the SAP hashes exactly (checked on 16k positions x 4
   table sizes).
4. The zopfli short-distance loop's hoisted `left` byte was read even when
   the loop could not run (DATA[N] near the end, q10/q11).
5. `clfreq` / `clcl-lengths` were plain T vectors declared
   `(simple-array fixnum)`: harmless on SBCL (same tagged layout), memory
   corruption on CCL (`WRITE-COMPRESSED-BLOCK-BODY` faulted).
6. NIL-for-fixnum / NIL-for-simple-vector declaration lies
   (`dict-match-at` best-idx, `lit-rcl/lit-lnl/lit-sng`).
7. ECL rejected a DECLARE after a LABELS docstring (`push-cmd`) - legal CL,
   rewritten as a comment.  CCL cannot see a DEFCONSTANT value in `#.` at
   compile time (`build-huff` subtable size) - literal used.

Decoder:
8. `decompress-into`'s non-SAP branch never set OUTBUF-ORIGIN: on CCL/ECL
   every distance with :START > 0 was classified against the wrong base
   (dictionary words in place of copies).  Both branches now share one body.
9. Hostile input: insert/copy lengths and dictionary words were written
   past the reserved meta-block (heap overflow at safety 0, into the
   caller's buffer for `decompress-into`); out-of-alphabet simple-code
   symbols indexed 704-entry tables up to 1023; over-subscribed and
   incomplete codes reached BUILD-HUFF.  Added C's checks
   (BLOCK_LENGTH_*, SIMPLE_HUFFMAN_ALPHABET/SAME, CL_SPACE, HUFFMAN_SPACE).
   With in-alphabet symbols, block types and context-map values are in
   range by construction, as in C.  Mutation fuzz: 75,000 streams, 0
   out-of-bounds accesses; we never reject a stream C accepts (we still
   accept ~1.8% of corrupt streams that C rejects - padding/trailer checks).
10. "end of input" was a plain ERROR, not BROTLI-ERROR.
11. The INVALID-DISTANCE test passed an adjustable vector to OUT-COPY
    (which takes an OUTBUF) and only "passed" through undefined behavior.

Also: r170 as committed crashes at q2+ (`NIL is not ZPQ`); the uncommitted
port.lisp diff already fixed that.  A load-time check now refuses Lisps
with < 60-bit fixnums (ZLEN packs bits up to 50).

Result: 241/241 on SBCL (native, safety 3, portable safety 3), CCL, ECL.

### Speed

Decoder (html relnotes, 1 MiB, C stream, lisp/C core, before -> after):
q0 0.37->0.41, q1 0.30->0.34, q2 0.35->0.39, q5 0.31->0.39, q11 0.29->0.41;
source q5 0.32->0.40, binary q2 0.58->0.70.
- dictionary references: DICT-WORD re-parsed the transform's SYMBOL-NAME
  with SEARCH + PARSE-INTEGER and built 5 temporaries per reference;
  DICT-WORD-INTO writes prefix/word/suffix straight into the output from a
  precompiled transform table (q5 +18%, q11 +34% on html alone).
- BLK struct slots untyped -> BLK-MAYBE-SWITCH was generic arithmetic per
  symbol on block-split streams; READ-HUFF had no result type -> every
  comparison on a decoded symbol was generic (155 efficiency notes in
  DECODE-COMPRESSED-META-BLOCK -> 0); BITS-AVAILABLE's (* 8 (- end pos))
  was GENERIC-+.
- BUILD-HUFF: fixnum count/next arrays, one pre-sized subtable vector
  instead of VECTOR-PUSH-EXTEND + COERCE (+5%).
- %DECODE-LIT-RUN-CTX: context-modeled literal runs with the reservoir and
  p1/p2 in locals, per-literal READ-HUFF fallback (+3%).
- WITH-LOCAL-BITS: command header and distance read groups with the
  reservoir in MACROLET-updated locals (not MV-returning functions, the
  approach that lost three times above): q1 +3..8%, q5 ~0.
What remains (~0.4x): struct traffic around every literal run and copy,
OUT-COPY-PREALLOCATED (13% incl. REPLACE), tree building on many-tree
streams (BUILD-HUFF + READ-COMPLEX-PREFIX ~12% at q5).

Encoder:
- q10/q11 cliff on repetitive data: %COMPRESS-BYTES re-ran the whole
  pipeline without the dictionary whenever the OUTPUT was < 4 KiB, i.e.
  exactly for the most compressible inputs (1 MiB zeros -> 13 bytes paid
  two zopfli runs).  Gate is now on the INPUT size (n < 4096).  Plus
  LENGTH-CODE-F's long-length fallback read T vectors untyped (generic >=
  and a full call to %SINGLE-FLOAT per evaluation - every long copy).
  zeros q10 0.18->0.41, q11 0.16->0.35; periodic q10 0.38->0.74, q11
  0.42->0.63 (lisp/C core; 1 MiB zeros q11 7.1 -> 16.7 MiB/s).
- %LZ77: NCMD untyped (generic * and + per pushed command), (* 135 ml)
  score terms and (ash best-dist 2) overflow-checked: all 72 notes with a
  forced generic/overflow op gone.  html q2 0.45->0.48, q5 0.65->0.70,
  source q5 0.73->0.78.

Not changed: sizes (all within +-0.01 of before on the 1 MiB matrix).

### Where parity stands (this host, 1 MiB, lisp/C core speed; size)

compress  | q0-q1        | q2-q5          | q7      | q9-q11
---       | ---          | ---            | ---     | ---
html/json | 0.48-0.83x   | 0.35-0.70x     | 0.7-0.9x | 1.0-1.9x
source/bin| 1.0-2.4x     | 0.36-0.78x     | 0.94-1.0x | 1.1-3.5x
size      | 0.42-1.02    | 1.00-1.09      | 1.01-1.06 | 1.01-1.10

decode of C streams: 0.31-0.70x on real corpora (all levels).

Next levers, in measured-impact order: (1) decoder - keep the reservoir in
locals across the WHOLE command (literal run + copy), i.e. fold
%DECODE-LIT-RUN(-CTX) and the copy into the command loop under one
WITH-LOCAL-BITS; (2) q2-q5 encoder speed (the H5/H6 bucket probe and the
emit pass); (3) q10/q11 binary/text ratio (1.07-1.12: block splitting and
context modeling at C's HQ settings); (4) periodic q5-q11 ratio 1.31-1.49.

### Session 6 Nov 2026, part 2

More correctness (each now has a regression test or fuzz coverage):
12. DECOMPRESS-INTO wrote past :END into the caller's buffer: the 16-byte
    unaligned short-copy checked (LENGTH DATA), not the output limit.
    294 of 400 random calls clobbered bytes after END.  The copy path now
    takes an explicit write limit (OUTBUF-LIMIT).  Test:
    DECOMPRESS-INTO-STAYS-IN-RANGE.
13. PARSE-AS-UTF8 accepted a 3/4-byte sequence when start+2 = end / start+3
    = end (C: size > 2 / > 3), reading IN[END] (feeds literal costs).
14. Test CORRUPT-STREAMS-SIGNAL-BROTLI-ERROR: 400 mutated C/Lisp streams
    must decode or signal BROTLI-ERROR only.
Suite: 243/243 on SBCL (native, safety 3, portable safety 3), CCL, ECL.

Benchmark harness: the SOURCE dataset silently fell back to cl-brotli's
own src/ when ~/cl-newzlib and ~/pesekey are absent, so its fingerprint
changed with every edit (BAC6B49C, 0A5BE001, 50B669E3, 430D60EC across
this session's runs) - SOURCE before/after numbers on such a host are
meaningless.  The description now says FALLBACK when that happens.

q2-q4 encoder: ported C's BrotliCreateBackwardReferences driver over the
HashLongestMatchQuickly family (%LZ77-QUICK; q2 = H2 16-bit/1-way,
q3 = H3 16-bit/2-way, q4 = H4 17-bit/4-way or H54 20-bit/4-way/7-byte
hash at >= 1 MiB, as ChooseHasher): last distance first,
BackwardReferenceScore selection, the lazy deferral (cost_diff_lazy 175,
<= 4 in a row), distance-cache rotation, StoreRange, sparse-search jumps;
no static dictionary yet (C's H2/H4 have it).  Short distance codes are
now on for q2-q4 (C always uses them).
  sizes lisp/C at q2: html 1.04 -> 1.00, json 1.06 -> 1.00, binary 1.05 ->
  1.01; q3 1.00-1.02, q4 1.00-1.04 (periodic 1.06).
  speed: frozen r170 source corpus, q2: chain3 204 MiB/s / 94,520 B ->
  H2 port 189-196 MiB/s / 86,499 B (C: 370 MiB/s / 86,756 B).
  Two traps found on the way: a variable-count ASH of a u64 is not
  modular (consed a bignum per hash), and declaring %MATCH-LEN-SAP's
  result narrower than FIXNUM makes SBCL drop the SSE2 VOP for a full
  call - bind it as FIXNUM and narrow with THE at the use.

Decoder, part 2 (html, lisp/C core): q5 0.39 -> 0.41, q11 0.41 -> 0.43.
- OUT-COPY-PREALLOCATED's INLINE declaim came after its DEFUN, so every
  copy was a full call; overlapping short copies used (MOD I DISTANCE)
  per byte.  Now inline, a forward word copy with the period widened to
  >= 8 bytes, word moves for 17-255-byte copies, doubling REPLACE for
  >= 256 bytes (periodic decode stays 2.9-3.2x C).
- READ-COMPLEX-PREFIX / READ-CLCL typed (21 notes -> 2); C's per-mode
  512-byte context LUT (one OR per literal, no CASE on the mode).
Instruction-level profile (sb-sprof annotated DISASSEMBLE of
DECODE-COMPRESSED-META-BLOCK): the "self" time sits on return points of
the copy, the context literal run, READ-PREFIX-CODE and DICT-WORD-INTO;
command parsing itself is small.  C q5 html streams carry one meta-block
with 130 literal trees, so tree setup (10-bit roots, 1024 stores each)
is ~15%; C's 8-bit roots would cut that 4x - the next decoder lever.

Matrix now (1 MiB, lisp/C core speed):
compress  q0-q1 0.2-2.2x | q2-q3 0.40-0.47x (real corpora) | q4 0.61-0.73x
          q5 0.51-0.79x | q7 0.78-1.02x | q9-q11 1.0-3.6x
size      q2-q11 1.00-1.10 except periodic q5-q11 1.31-1.49
decode    0.34-0.71x on html/json/binary at every level

### Session 6 Nov 2026, part 3

q9-q11 literal context modeling (C BrotliBuildMetaBlock's literal side,
without block splits): HQ-CONTEXT-MAP builds the 64 per-context literal
histograms of the actual parse under C's ChooseContextMode (signed for
non-UTF8, UTF8 otherwise; the UTF8 test now runs over the literals only),
then merges histograms greedily while the estimated cost (Shannon bits +
30 + 4 bits/used symbol; the sweep 2..8 / 20..40 was flat) drops.  Pair
gains are cached (a merge re-evaluates only its own pairs) and log2 comes
from the 2048-entry table plus an exponent split, so the cost is 1-4% of
q10.  Gates: q10/q11 always; q9 only for non-UTF8 (UTF8 gains ~0.5% for
~6%); never below 64 literals.  The writer emits context mode 3 when chosen.
  size lisp/C:        before -> after
  binary q9 / 10 / 11  1.065 / 1.099 / 1.071 -> 1.011 / 1.042 / 1.043
  libc   q10 / q11     1.095 / 1.061 -> 1.035 / 1.033
  source q10 / q11     1.053 / 1.040 -> 1.013 / 1.016  (frozen r170 src)
  html   q10 / q11     1.041 / 1.038 -> 1.027 / 1.029
  periodic q9 / q10+   1.31 / 1.49 -> 1.22 / 1.34
  (Measured but not enabled: at q5/q7 the same map gives binary 0.980 /
  1.011 of C's size, for +40-66% time.)
Trap: the first version ran MOSTLY-UTF8-P over the whole input per
meta-block; on repetitive input (zeros/periodic, ~1 ms compresses) that
fixed cost took q9 from 1.6-2.3x to 0.5-0.6x of C.

Decoder: second-level Huffman tables are now sized per tree (longest
code - root bits, as C) with 8-bit roots for 256-symbol trees, and both
fast readers (context literal run, command/distance LSYM) decode
second-level entries inline after a refill to 15 bits; literal runs are no
longer called for zero-length inserts.  html decode lisp/C: q0 0.43 ->
0.47, q10 0.44 -> 0.47; q1 +7% in isolation.  Root width itself (8/9/10)
measured within noise.
The html stream at q5 is 33K commands, 24K literals, mostly 17-255-byte
non-overlapping copies: the remaining gap is per-command (~65 ns vs ~35 ns
in C), not literals or tree building (READ-PREFIX-CODE 0.28 ms of 2.15).

### Session 6 Nov 2026, part 4: disassembly-driven decoder work

Goal changed (user): speed >= C at every level; ratio only has to match.

Method: compile the hot path in isolation (or the real function),
DISASSEMBLE, read it against what C would emit; sb-sprof's per-instruction
sample annotation for where time goes (samples on the instruction after a
CALL are the callee's).  What the disassembly showed and what fixed it:
- SBCL keeps no register across a full call.  A cold fallback that was an
  inline expansion of READ-HUFF, REPLACE/FILL in the copy, and error calls
  put the loop's position, counter, table and mask in stack slots.
  READ-HUFF-OOL (out-of-line cold path), %COPY-MATCH-INLINE (call-free
  word copies with period widening; REPLACE only for >= 4 KiB copies, where
  bandwidth rules), deferred error codes in the simple loop.  But an extra
  out-of-line RBITS lost 13% at q11 - measure each call site.
- +WIDE-MASKS+ and the command tables were DEFPARAMETERs: every read a
  thread-local symbol-value check.  DEFTABLE (SB-EXT:DEFINE-LOAD-TIME-GLOBAL
  on SBCL) for all 50 constant tables; refill masks computed by shift.
- The 26 KB meta-block function had ~40 live values for 14 registers.
  %DECODE-SIMPLE-META-BLOCK - the loop for C's q0-q4 stream shape (one
  block type and one tree per category) - fits: 7 KB, 207 stack refs vs
  ~900.  Plus one local reservoir for the whole meta-block in the general
  loop, u64 accumulator, 16-byte overrun copies bounded by the meta-block.
- DECOMPRESS grew its output 1.5x per meta-block from 4 KiB and copied the
  decoded data ~3x (28% of its time): presize hint (8x input, applied at
  the first growth), doubling, in-place trim (SB-KERNEL:%SHRINK-VECTOR).
Decode lisp/C core (harness, DECOMPRESS), html/json/binary:
  q1 0.42/0.44/0.55 -> 0.63/0.65/0.65   q2 0.49/0.40/0.65 -> 0.72/0.62/0.75
  q3 0.47/0.41/0.66 -> 0.61/0.62/0.76   q5 0.48/0.45/0.53 -> 0.50/0.48/0.57
  q11 0.49/0.47/0.59 -> 0.53/0.51/0.63  (decompress-into micro: q2 0.98)
Tried, no gain: 8/9/10-bit roots, (debug 0), hoisting tree fields, locals
for tables (more spills), out-of-line copy (call > spills), call-free
"fast mode" literal loop (q1 runs are ~1 literal).
Next: the general q4+ loop needs the same treatment (specialized variants
or fewer live values); encoder q0-q5 has not had a disassembly pass yet.

### Session 6 Nov 2026, part 5: same method on the general decoder and the q0-q4 encoder

Decoder, general (q4+ C streams, block-split):
- the loop is now %DECODE-GENERAL-META-BLOCK (own function, explicit
  arguments, errors as codes) with the single-tree hoists dropped and the
  block switch out of line (BLK-SWITCH-OOL: the inline BLK-MAYBE-SWITCH
  brought READ-HUFF with ~12 slow-path call sites to each switch point).
  26 KB / 891 stack refs -> 11 KB / 372.  Speed moved little (q5 html
  0.50 -> 0.51 harness): the annotated profile is now flat (hottest
  instruction 4%), i.e. the remaining gap is instruction count spread over
  the whole command path, plus tree setup (~13%) and copy-source latency.
Encoder:
- WRITE-TRIVIAL-BLOCK-BODY (q2-q4): bit writes through the BWR struct ->
  WR-PM/WR-RAW over local ACC/NBITS/POS (synced around W-ENSURE /
  W-EMIT-RUN); command fields bounded (the "signed word to integer
  coercion" bignum boxing is gone).  q2 +18%.
- %LZ77-QUICK specialized per C hasher (DEFINE-QUICK-MATCHER: H2/H3/H4/H54
  with bits/sweep/hash-len as constants): StoreRange went from reloading
  and branching on them per store to 13 instructions.  q3 +12%, q2 +7%.
- SPECIAL-DISTANCE-CODE = C ComputeDistanceCode (<= 6 tests instead of 15,
  twice per command in every writer).  q2 +9%.  Ties now resolve in C's
  order (2 bytes difference on html q2).
- q0/q1 fragment matchers: %HASHF-TAIL inline (7 call sites in the scan),
  pooled hash tables + q1 command vector (POOLED-U32; fresh 512 KiB tables
  per call were ~6% of q1).  q1 +10%.  Inlining EMIT-ONE again: no gain,
  more spills (522 -> 705 stack refs) - left as is.
- q9 context-modeling gate sampled the first 32 KiB of literals for the
  UTF8 test (a full parse cost JSON q9 several percent); q10/11 keep the
  full scan (the sample misjudged ELF binaries).
Matrix (harness, noisy host, load 2-3), compress lisp/C, html/json/binary:
  q0 0.86/0.51/1.11  q1 0.73/0.64/1.14  q2 0.69/0.66/0.69  q3 0.73/0.67/0.73
  q4 0.86/1.28/0.64  q5 0.74/0.65/0.57  q7 1.21/0.95/1.02  q9+ >= ~1.0
Decode lisp/C: q0-q3 0.60-0.78, q4+ 0.46-0.62.

### Session 6 Nov 2026, part 6: codegen lab, table format, StoreRange, H6

Codegen lab (scratchpad, 4M-symbol Huffman decode kernels, same output):
current shape 3.34 ns/sym; C's bit-window model 3.58; SAP table/output
4.05; all locals (unsigned-byte 64) 3.10 (bit count and len untagged, the
entry still tagged); entry forced past fixnum range (bit 63) 3.34 - the
chain is untagged but no faster.  Per symbol we are ~1.3x C's dependency
chain; SBCL tags anything whose TYPE is fixnum-range (the declared u64 is
narrowed back), and register moves are nearly free.  Not the main gap.

Ablation and synthetic shapes (decode lisp/C core): literal-only q1 0.80,
q5 0.64; short copies q1 0.76, q5 0.34 (!); long copies 9.3.  q0-q3 html:
copies are ~20% of decode, the rest alone equals C's whole decode.
The q5 short-copy case is the general loop's context-literal path: five
dependent loads per literal (two LUT bytes, LIT-TREES -> struct -> TABLE ->
entry) + a nil check for single trees + per-literal block bookkeeping.
- Table format: single-symbol trees are real tables of zero-length
  entries (MAKE-SINGLE-HUFF; READ-HUFF tells them by a NIL COUNT), the
  subtable marker moved to length field 15, every 256-symbol tree has an
  exact 8-bit root (shorter codes replicated) -> constant literal mask and
  width, no single-tree branch in any reader.  %DECODE-LIT-RUN(-CTX) were
  dead and are gone.
- General loop: context literals split at literal-block boundaries (one
  switch test per piece), tables read from a per-meta-block LIT-TABLES
  vector (one load less on the chain), call-free LSYM-FAST inner loops when
  the input holds 2 bytes per literal; same for the single-tree branch.
  short copies q5 0.34 -> 0.41; html q4-q11 +0..6%.
Encoder:
- StoreRange out of line for the quick matchers (one call per match; the
  loop had been reloading SAP/BUCKETS from the stack, 13 -> 15 insns with
  no stack traffic and a free-register loop): q2 +10%, q3 +9%, q4 +20%;
  same for %LZ77's chain StoreRange (%CHAIN-STORE-RANGE): q5 html +5%.
- C's H6 for q5 (DEFINE-H6-MATCHER: 2^15 x 2^(q-1) bucket ring, 4/10/16
  distance-cache candidates with C's penalty order, same driver as q2-q4,
  pooled tables, >= 64 KiB inputs): q5 size vs C html 1.025 -> 0.998,
  libc 1.015 -> 1.013; speed html ~same (0.77-0.79), libc 0.38 -> 0.56.
  q6-q9 stay on the chain matcher (faster than C there; H6 would not be).
  Out-of-line FindLongestMatch for H6 lost (call > spills).
Measured A/B, html/sbcl/libc compress lisp/C: q5 0.77/0.63/0.56,
q6 1.24/1.09/0.66, q7 1.47/1.51/0.85, q9 2.11/1.87/0.91.  The shared host
(load ~2) makes single harness cells +-20%: prefer interleaved A/B.

### Session 7 Nov 2026: VOP kernels (x86-64 SBCL)

All assembly is in src/dvops.lisp (decoder) and src/evops.lisp (encoder);
the Lisp code it replaces stays the code for CCL / ECL / other SBCL
platforms and for every case the assembly hands back.  Protocol: a u64
state vector (scalars, read on entry, written on exit) + a simple-vector
of the arrays (tagged pointers in registers: conservatively scanned, no
pinning needed); raw interior pointers only into explicitly pinned
vectors.  Every encoder routine is bit-identical to its Lisp loop
(66 corpus inputs x q0..q6, scratch cmpq0.lisp against a tree with the
assembly disabled).

Decoder
- Simple (q0-q3 shape) and general (block switches, context literals,
  distance contexts, dictionary words incl. transforms) meta-block loops.
  Bail-out protocol: exit 1 = re-decode the next command in Lisp (input
  near its end, invalid data), exit 2 = dictionary word (only the 64-byte-
  room fallback).  Copies: 16-byte chunks, 32-byte disjoint, period-grown
  overlap, distance < 16 as pattern stores, exact finish at meta-block
  ends (100 KB copies there had run bytewise).
- Huffman tables in C's layout (one array: root + per-prefix second-level
  tables sized by NextTableBitSize) - 2.5x smaller literal tables.
- Distance context from the command LUT (known before the extra bits),
  per-context table pointers, p1/p2 in registers.
- Fixed: DECOMPRESS-INTO took p1/p2 from the caller's bytes before START
  (wrong output for context-modelled streams) - regression test added.
- Output growth: extrapolate from output-per-input (overall or last
  block, +1/4, <= 8x), never below doubling.
Decode into a reused buffer (warm): html/libc 0.97-1.05x C, json q1 1.2x,
zeros/periodic 3-55x.  Through DECOMPRESS under the harness 0.73-1.05x:
it runs FULL-GC before every sample and SBCL then returns free pages to
the OS, so every allocated byte costs ~0.6 ns of page faults (a 1 MB
result ~600 us) while C decodes into a preallocated buffer.

Encoder
- q0: whole scan + emission (trawl, match, codes, hash re-insertion).
- q1: recording scan (histograms in place) + fast emitter.
- q2-q4: quick matchers H2/H3/H4/H54 (position in a register, insert =
  pos - lit-start, FindLongestMatch score in a register), trivial writer
  in two passes (codes computed once, packed into the command records).
- q5/q6: C's H6 (ring walk through a pinned raw pointer); q6 switched
  from the chain matcher to H6 (libc 0.51 -> 0.83x, ratio = C).
- Fixed per-call costs: interleaved histogram lanes (a run of one byte
  serialised every increment), stack bitset + early exit in
  INCOMPRESSIBLE-P, typed canonical/reversed code builders, SSE2 match
  length in all matchers.
Lessons: a driver DEFUN named like its VOP's function compiles its own
call as a self-call (heap corruption); x86 SIB scale <= 8; imm32
sign-extends (compare u32 slots with :dword -1).

#### Later the same day: allocation, prefetch, H6 at q7-q9, C's tree writer

Harness (bench17, 1 MiB, lisp/C core; before the tree-writer port, which
changes sizes only):

    compress  q0    q1    q2    q3    q4    q5    q6    q7    q9    q10   q11
    html      1.16  0.98  0.89  0.93  1.16  1.07  1.22  1.03  2.05  1.14  1.73
    json      0.69  0.88  0.82  0.84  1.18  1.02  1.15  0.93  1.47  0.99  1.47
    binary    1.61  1.69  0.89  0.91  1.39  0.84  1.09  0.98  1.39  2.08  3.14
    zeros     1.38  0.67  6.85  6.92  2.21  2.68  2.69  2.76  2.61  0.45  0.38
    periodic  0.58  0.63  5.92  5.88  1.58  1.98  2.00  1.99  3.82  0.81  0.72

- Per-call allocation is a first-order cost in SBCL: a fresh 1 MB vector
  costs ~200 us even warm (zeroing + GC), ~600 us after the harness's
  FULL-GC once touched.  Pooled now (MAKE-COMPRESSOR scratch): the
  PLAN-COMMANDS record array (4 MB/MiB of text at q5-q9), %LZ77's command
  vector (3 allocations, 6 MB at q7), SPLIT-BLOCK's 258 eager histograms
  (lazy now), BUILD-CODE-LENGTHS-A temporaries (stack).  json q5 5.5 MB ->
  0.74 MB per call: q5 0.91 -> 1.02-1.09x, q7 json 0.74 -> 0.93-1.2x.
- DECOMPRESS's first growth no longer jumps to 8x the input (4.8 MB for
  1 MB of binary q0): exact first block, then extrapolation.
- Prefetch in the H6 and quick VOPs: the next probe's ring/bucket line
  (CUR+1 while this position walks; CUR+LEN while StoreRange runs).  The
  H6 bucket table is 2-16 MB, so its first line per position was a DRAM
  miss in both C and here; q8 binary 0.77 -> 1.00x, q7 +22%.
- q7-q9 run C's H6 (bit-identical asm/Lisp): sizes now = C (were 1-6%
  over with the chain matcher) and speed 0.93-2.05x.
- Z-SKIP-RUN: the q10/q11 long-copy EvaluateNode loop out of the big
  closure: zeros q10 0.41 -> 0.56, periodic q10 0.70 -> 1.03 (cq).
- Tree headers: C's BrotliWriteHuffmanTree/StoreHuffmanTree (chained
  repeat codes, initial previous length 8, DecideOverRleUse, a single
  code-length symbol coded with 0 bits), C's simple-code depths (most
  frequent first, tree-select for 4), and BrotliOptimizeHuffmanCountsFor-
  Rle on q4+ literal/command/distance histograms.  periodic 1 MiB: q5
  1.33 -> 1.10, q9 1.22 -> 0.95, q11 1.34 -> 1.06.

Open (ratio): small inputs at q4-q9 (html 4 KiB q5 1.21, 16 KiB 1.13):
C's H5/H6 and H2/H4 consult the static dictionary when no match is found
(we only do at q10/q11) and use H5 below 1 MiB; q2/q3 binary 1.4-1.7%
(C writes one meta-block per 16 KiB at q<4); q4 binary 4% (matcher
difference, not the writer: through the full writer html/json reach
1.003/1.000, binary stays 1.04); context maps are written without
RLE/MTF.
Open (speed): q0 json (scan/emit VOP is latency-bound), q2/q3 json,
q10/q11 zeros (EvaluateNode per position), decode via DECOMPRESS
(allocation; decode into a buffer is 1.0-1.16x warm).
