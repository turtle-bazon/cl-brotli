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
