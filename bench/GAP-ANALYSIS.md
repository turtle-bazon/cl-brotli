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
