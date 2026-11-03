# Why We Cannot Beat C: Root-Cause Analysis (4 Nov 2026)

This is the honest structural answer, not a list of micro-optimizations.
Every measurement below is from this host (1 MiB, C Brotli 1.0.9,
SBCL 2.6.9), committed in bench/results/.

## The three structural gaps, ranked by measured impact

### Gap 1: The q0/q1 encoder is two-pass; C's is one-pass

C's `compress_fragment.c` (`BrotliCompressFragmentFast`) does everything
in a single scan: the LZ77 matcher hashes, matches, and *immediately
emits* the command + literals into the bit stream via `EmitInsertLen` /
`EmitLiterals` / `BrotliWriteBits`. There is no intermediate command
vector, no histogram pass, no tree build in the hot loop. The pre-LZ77
literal histogram (sampled every 29th byte for large inputs) is built
*before* the scan starts.

Our lisp `%lz77-fragment` does the same scan but writes every command
into a flat `(unsigned-byte 32)` vector (`cv`, 4 entries per command)
and accumulates exact literal/command/distance histograms. Then
`WRITE-FAST-BLOCK-BODY` walks `cv` a second time to emit. The profile
confirms: `%LZ77-FRAGMENT` 46.1% self, `WRITE-FAST-BLOCK-BODY` 39.7%
self — the emit pass is nearly half the time, and it is pure overhead
relative to C's single-pass structure.

**Measured:** matcher-only 301 MiB/s; full q0 161 MiB/s. If the emit
pass were eliminated (one-pass), the ceiling would be ~300 MiB/s
(0.6x of C's 500). The remaining 0.4x is the per-position instruction
count in the matcher itself (discussed in Gap 3).

**Why we have not done it yet:** the one-pass structure requires the
literal tree to be known *before* the scan (C samples the pre-LZ77
input). Our current writer builds exact trees from the actual emitted
stream, which gives better ratio (0.917 vs C's 1.0 on html) but costs a
second pass. Porting C's sampled histogram + fixed 64-symbol command
code is a known, bounded change (the plan is in GAP-ANALYSIS.md r86);
it trades ~8% ratio on html/json for ~2x speed.

### Gap 2: The decoder's per-symbol instruction count is ~2.3x C's

C's `decode.c` `ReadSymbol` is a single inlined function: speculative
`BrotliFillBitWindow` (loads ahead so the common path has no refill
branch), a 16-bit table lookup, and a shift. The bit reader state
(`val_`, `bit_pos_`) lives in registers across the whole command loop.

Our `read-huff` does the same table lookup but: (a) round-trips
`acc`/`nbits`/`pos` through the `BRD` struct on every call, (b) has
`bits-available` guards (which compile to generic-arith), (c) the
refill is a branchy `%fill-bits` call. The `%decode-lit-run` special
case (single-tree literal runs) already avoids the struct round-trip
for literals — and that is why q0 text decode reaches 4.5-5.0 GiB/s
while html decode is stuck at 0.43x: the literal run is fast, the
command loop is not.

**Measured:** decode of C html q0: 233-246 MiB/s (0.43x). The profile
shows 52% in the command loop, 20% copies, 14% literal run.

**What has been tried and lost:** three local-reservoir rewrites
(values-passing readers, `%decode-simple-meta-block`, the flet variant)
all measured 4-25% *slower* than the generic loop. The lesson: SBCL's
inline expansion of multi-value functions creates stack traffic that
exceeds the struct-access savings. The only thing that has helped is
reducing *ops* (u16 LUTs: +1.7-3%) or *cache footprint* (r89), not
moving state into registers.

### Gap 3: The q2-q9 chain matcher lacks C's candidate machinery

C's q2-q9 uses the H5/H6 bucket hasher with: a 4/10/16-entry distance
cache (`PrepareDistanceCache`), `BackwardReferenceScore` (the 135·len −
30·log2(dist) formula), a `kMinScore` gate, the ≥175 lazy rule, and the
sparse-search heuristic (skip hashing in long literal runs). Our chain
matcher has last-distance seeding and a simple best-len maximization.

**Measured:** q2 sizes 1.03-1.09 (inside cap but not beating C); q9
0.71-0.73x speed on html/json. The score-matcher port (r86 recipe) is
the recorded next step; it traded 5-15% speed for 2-7% size in the
earlier attempt, but the chain-hash full-spread (r83) bought back part
of that speed.

### Gap 4: q10/q11 lack C's high-level features

C's q10/q11 adds context modeling, block splitting, and the HQ zopfli
parser. Our q10/q11 is 17-20x faster but 13-21% larger. This is
algorithmic, not codegen: no amount of VOP work closes a 1.2x ratio gap
that comes from missing features.

## Why "fewer ops" wins but "more state" loses

The session's micro-experiments are consistent:

| change | result | lesson |
|---|---|---|
| u64 hash (r79, r83) | +10-15% matcher | fewer instructions per hash |
| pre-masked writer (r87) | +2-3% | fewer ops per literal |
| u16 LUTs (r89) | +1.7-3% decode | smaller cache footprint |
| values-passing readers | -4% | MVSQ stack traffic |
| packed lit-pc table | -2% | extra logand/ash |
| local literal-run decoder | -5-7% | larger inline loop hurts I-cache |
| two-literal batching | -3-8% | register pressure |

The pattern: SBCL's codegen is at its floor for *arithmetic* (the same
machine ops as C), but every attempt to restructure *control flow*
(branchier loops, multi-value returns, larger inline bodies) loses to
the generic version. The fix for the remaining gap is therefore not
"write it in Lisp differently" but "reduce the number of operations"
(precisely what r87/r89 did) or "move the whole loop into a VOP"
(the `%match-len-sap` template, which needs the results-tuple work).

## What would it take to beat C on every q

| cell | gap | fix | effort |
|---|---|---|---|
| q0/q1 compression | 0.29-0.48x | one-pass encoder (pre-LZ77 histogram + fixed command code) | 1-2 sessions |
| q0/q1 decode | 0.35-0.53x | ReadSymbol VOP (results-tuple work) | 1 session |
| q2-q6 size | 1.03-1.13 | score matcher (r86 recipe) | 1 session |
| q2-q9 speed | 0.36-0.95x | bucket hasher port or VOP per-candidate | 2 sessions |
| q10/q11 size | 1.13-1.21 | context modeling + block splitting | 3+ sessions |

The honest assessment: beating C on *every* q requires all five. The
realistic near-term target is parity (0.9-1.1x) on q0-q9 with wins on
text/source, achieved by the one-pass encoder + score matcher + VOP
pass. q10/q11 parity needs the feature port.
