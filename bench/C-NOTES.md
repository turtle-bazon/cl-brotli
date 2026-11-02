# Notes from the C Brotli implementation

Reference: `google/brotli` HEAD `d89c4b1c` (`c/enc` and `c/dec`). This file
records what was measured, what was ported, and what remains.

## Encoder: why q0–q9 are fast in C

Quality dispatch (`c/enc/encode.c`):

| quality | C path |
|---:|---|
| 0 | `BrotliCompressFragmentFast` (`c/enc/compress_fragment.c`) |
| 1 | `BrotliCompressFragmentTwoPass` (`c/enc/compress_fragment_two_pass.c`) |
| 2–9 | `BrotliCompressMetaBlock` (`c/enc/encode.c`) with block splitting / context modeling |
| 10–11 | Zopfli-style optimal parsing |

The q0 one-pass fragment path is the important one for our largest gap:

* Minimum match length is **5**, not 4.
* Hash table of positions, **one candidate**.
* **Match-skip heuristic**: when no match is found, it advances by
  `skip++ >> 5` bytes instead of one; after 32 skipped bytes it looks every
  2nd byte, then every 3rd, etc. This is a huge win on literal-heavy
  HTML/JSON/binary.
* The literal prefix code is built from a **histogram of the pre-LZ77 input**
  (sampled every 29th byte for large inputs), not from the actual literal
  stream. This allows one-pass emission.
* Command and distance codes are a **fixed 64-symbol code** (seeded / carried
  from the previous block), so there is no command-planning pass and no
  704-symbol tree build per block.
* `BrotliWriteBits` writes up to 56 bits with one unaligned 64-bit load/store
  (`c/enc/write_bits.h`).
* Match extension uses unaligned 64-bit XOR + trailing-zero count
  (`c/enc/find_match_length.h`).

Ported into cl-brotli:

* match-skip for q0–q4 (`skip++ >> 5`);
* SAP-based 64-bit match extension with SBCL's `count-trailing-zeros`
  (`tzcnt`/`bsf` VOP) finding the first differing byte in one step, matching
  C's `FindMatchLengthWithLimit`;
* flat command records, precomputed length/symbol tables, one hash per
  position, 64-bit. This took q1–q4 from ~0.02–0.11x to 0.08–0.29x C speed.

Not yet ported (the structural remainder):

* the fixed 64-symbol fast command/distance alphabet;
* one-pass literal emission from the pre-LZ77 histogram;
* 56-bit single-store bit writer;
* block merging with a command-code update for the next block.

## Decoder: why q0/q1 are slower in our implementation

C decoder hot path:

* `HUFFMAN_TABLE_BITS = 8` (`c/dec/decode.c`), with multi-level secondary
  tables built by `BrotliBuildHuffmanTable`.
* `brotli_reg_t` 64-bit `val_` and `bit_pos_`; `BrotliFillBitWindow` loads
  56/48/32/24/16 bits at once with unaligned 64-bit loads, and
  `BrotliDropBits` shifts the register (`c/dec/bit_reader.h`).
* `ReadSymbol` is inlined and speculatively drops the root bits.
* Match copies use unaligned 64-bit stores (`BrotliCopy` in `c/dec/decode.c`).

Ported:

* 64-bit reservoir (originally 4-byte refills);
* 56-bit refill from a pinned input SAP;
* a byte-aligned fast path in `r-bytes` so stored blocks do not fall back to
  a per-byte copy when the wide refill leaves whole bytes in the accumulator;
* typed Huffman/literal-tree arrays and precomputed context→tree maps;
* preallocated match copies and 4× output growth.

Not yet ported:

* the per-literal inlined `ReadSymbol` with loop-local `val_`/`bit_pos_`;
* 64-bit output stores in the copy path;
* 8-bit root table tuning (ours is 10-bit).

The remaining q0/q1 decode deficit is per-literal work, not refill or copying:
profiles put ~60% in the literal decode loop, with copies around 15%.

## sb-cpu-features and cl-newzlib

`cl-newzlib` uses `sb-cpu-features` for more than one path:

* `util.lisp` requires the bundled `sb-simd` at compile/load time, pushes
  implementation-availability features, and pushes an AVX2-build feature only
  when the build host itself supports AVX2 (to prevent SBCL from
  constant-folding and executing AVX2 during compilation).
* `simd.lisp` defines AVX2, SSE4.1, and scalar kernels and selects one through
  `sb-cpu-features:define-cpu-dispatch`; selection happens once per operation,
  not per inner-loop call.
* `cpu-init.lisp` re-probes features and re-selects implementations at image
  startup, so an image moved to another machine uses the new machine's ISA.
* `pclmul-crc.lisp` uses the PCLMULQDQ flag plus a load-time self-test; CRC is
  not applicable to Brotli (the format has no checksum).
* `simd-adler.lisp` uses AVX2 for Adler-32 weighted sums.

For Brotli the only comparable SIMD candidate is match extension. I tried an
AVX2 kernel with `sb-simd` + `sb-cpu-features`: text q1–q4 regressed by
10–25%, while HTML/JSON changed only a few percent. The scalar 64-bit + tzcnt
path (`count-trailing-zeros`) was faster, and it is also what C Brotli uses
(`BROTLI_TZCNT64`). The AVX2 path was therefore not retained. `sb-cpu-features`
remains a reasonable optional dependency if a future SIMD copy or histogram
kernel proves worthwhile, but the q0–q9 gap is dominated by per-symbol
emission and command planning, not match extension.

## Is "beat C at every q0-q9 cell" reachable?

Measured on the 8-core/16-thread Ryzen 7 3700X with chunk-parallel
compression (each chunk compressed independently; `cl-brotli:compress`, level-
matched):

| case | 1 thread | 4 chunks | 8 chunks | 16 chunks | C |
|---|---:|---:|---:|---:|---:|
| HTML q0, MiB/s | 30.8 | 80.6 | 94.3 | 82.0 | ~493 |
| JSON q0, MiB/s | 52.7 | 35.1 | 149.9 | 101.9 | ~663 |
| HTML q1, MiB/s | 34.7 | 57.3 | 92.1 | 87.9 | ~335 |
| text q1, MiB/s | 253.1 | 235.0 | 125.1 | 109.3 | ~1858 |

Scaling saturates around 3x, not 16x (SMT, allocation/GC contention, thread
spawn). Even an ideal 16x on HTML q0 would only reach C's single-thread
throughput before overhead. The ratio cost is also disqualifying for text:
summing independently compressed chunks was 4.01x the single-stream size at
4 chunks, 8.00x at 8, and 16.00x at 16 because cross-chunk matches vanish.

Conclusion: beating C at every q0-q9 cell is not achievable here with
single-threaded portable Lisp, and chunk parallelism does not rescue it
without destroying text ratio. The realistic wins remain the default q11
path, q11 round-trip, highly compressible decode, and API-level one-shot
(where the CFFI wrapper's allocation dominates).

## Disassembly-guided encoder work (q0-q9)

Profiling q0 HTML/JSON showed the time split across `plan-commands` (~30%),
the emitter (`write-compressed-block-body` + `wbits`, ~35%), and `%lz77` (~30%).
The generated code, not the algorithm, exposed four concrete problems:

1. `wbits` computed `(1- (ash 1 n))` at runtime and used generic arithmetic.
   Replacing it with a precomputed mask table, an `(unsigned-byte 64)` scratch
   accumulator, and a typed `prev` bit count removed the `ASH`/`TWO-ARG-AND`
   calls; the writer improved 15-20%.
2. The writer flushed bytes in a `loop while (>= nbits 8)`. C Brotli stores the
   accumulator once and advances by `nbits/8`. We now keep eight bytes of
   slack, do one unaligned 64-bit store (`sap-ref-64` on little-endian SBCL),
   and advance by `nbits >> 3`. A batched literal-run writer keeps `acc`,
   `nbits`, and `pos` in locals and pins the output SAP once per run.
3. The emitter declared tree arrays as `(or null (simple-array fixnum (*)))`.
   That forced 13 out-of-line `SB-KERNEL:VECTOR-HAIRY-DATA-VECTOR-REF` calls
   in the per-command loop, 8% of q0 HTML. Binding non-null arrays (with a
   shared empty vector) removed every generic array call.
4. `%MATCH-LEN-SAP` and `%HASH4-SAP` were called once per scanned position.
   Declaring them inline removed those calls and lifted q5-q9 by 25-40%
   (text q5 82 -> 115 MiB/s in the microbenchmark).

The flat command record was also reduced from 12 to 10 fixnums: `cpy` was
unused by the emitter, and a negative `dcode` now means "no distance bits".

Measured effect on the level-matched 1 MiB benchmark (geomean lisp/C,
compression): q0 0.20x -> 0.26x, q1 0.08x -> 0.11x, q2 0.26x -> 0.30x,
q3 0.27x -> 0.33x, q4 0.31x -> 0.36x, q5 0.14x -> 0.18x, q6 0.14x -> 0.17x,
q7 0.16x -> 0.19x, q8 0.16x -> 0.19x, q9 0.38x -> 0.44x. q0 text is now
3.90x C, q0 source 0.64x C. q11 compression/decompression improved to
2.71x / 1.33x.

The literal-heavy cells still need C's one-pass fragment strategy (fixed
64-symbol command/distance alphabet, sampled pre-LZ77 literal histogram,
emission during the scan) rather than another constant-factor pass; that is a
different encoder, not a table or writer tweak.

## Porting the C fast-fragment paths (q0/q1)

The q0/q1 gap was not table tuning. `c/enc/compress_fragment.c` and
`compress_fragment_two_pass.c` use:

* a single-entry hash table: 32K entries for q0 (`table_bits` 15) and 128K
  for q1 (17);
* minimum match 5 for q0 and 6 for q1;
* a 4-byte load plus a 5th/6th-byte check before `FindMatchLengthWithLimit`;
* the previous-distance candidate checked before the hash table;
* one 8-byte load to insert hashes for positions inside the emitted copy;
* q0's literal code from a pre-LZ77 histogram (exact below 32 KiB, every
  29th byte otherwise, +1 per symbol, the first 11 observations weighted by
  3), with a maximum literal code length of 8 bits;
* q0's precomputed 64-symbol command/distance prefix code
  (`kDefaultCommandDepths`, `kDefaultCommandBits`, `kDefaultCommandCode`).

Ported into cl-brotli: the matcher (`%LZ77-FRAGMENT`), the fast
insert/copy/distance alphabet mapped onto the full 704-symbol command
alphabet, and a two-phase fast writer (`WRITE-FAST-BLOCK-BODY`) that builds
the command and distance trees from the actual histograms and the literal
tree from the exact emitted literals. The sampled pre-LZ77 histogram was
evaluated first; the exact emitted-literal histogram gives a better ratio at
similar speed.

Not ported: C's per-block literal/command-code adaptation
(`ShouldMergeBlock` plus rebuilding `cmd_code` from the previous block).
`BuildAndStoreCommandPrefixCode` maps the 64 fast codes onto the full
704-symbol command alphabet (`0..7 -> 0..7`, `8..15 -> 64..71`,
`16..23 -> 128..135`, `24..31 -> 192..199`, `32..39 -> 384..391`,
`40..47 -> 128+8i`, `48..55 -> 256+8i`, `56..63 -> 448+8i`; distance codes
64..127 map to distance symbols 0..63). A faithful port needs that mapping,
the default depth/bit tables, and emission during the scan instead of the
flat command records.

## Fast command/distance entropy coding (final q0/q1 writer)

`WRITE-FAST-BLOCK-BODY` uses the fragment matcher's command list and C's
fast alphabet:

* fast insert/copy/distance codes (`q0-insert-len`, `q0-copy-len`,
  `q0-copy-last-len`, `q0-distance`) mapped to full command symbols by
  `q0-cmd-symbol`;
* command and distance trees built from the actual histograms, seeded with
  `kCmdHistoSeed` so every emittable code has a nonzero depth and the tree
  is never single-symbol;
* the literal tree from the exact emitted-literal histogram (max 15 bits);
* explicit-distance copy-last commands (copy length >= 72) are followed by
  a distance-0 symbol, matching `EmitCopyLenLastDistance`;
* the distance tree is dynamic, so the full lgwin window is used. C's fast
  path caps backward distances at 18 bits; removing that cap is what keeps
  source/text ratio at 0.35-0.46x of C instead of ~0.9x.

Measured q0: text 1169 MiB/s, source 205, JSON 164, HTML 103, binary 103;
q0 output is 0.35-0.99x C size. q1: text 1062, source 213, JSON 144,
HTML 108. The remaining gap is SBCL codegen versus the hand-written C
emitter and C's per-block code adaptation.

## Decoder: typing the hot command loop

Profiling C q0 streams showed 10% in generic `TWO-ARG-<=` plus generic
`ASH`/`+`/`-`, all from undeclared scalars in the command loop. Declaring
the command/cell/insert/copy codes, lengths, distance values, literal
context, and max distance as fixnums removed those calls. The NPOSTFIX=0
distance case now uses constant shifts instead of variable `ASH` by
`npostfix`.

Measured improvement (1 MiB, C q0/q1 streams): text 903/667 MiB/s,
HTML 146/136, JSON 186/154, source 145/135, binary 127/135. Geomeans rose
from 0.28x/0.35x to 0.32x/0.44x of C.

C q0/q1 per-block code adaptation was also measured: 128 KiB meta-blocks
with fresh literal/command/distance trees cost 20-35% speed and did not
improve ratio on the 1 MiB corpus (the single-block trees already adapt
well), so the fast writer keeps one meta-block.

A second decoder pass typed the copy entry points (`out-copy`,
`out-copy-preallocated`) and removed a distance check that the command loop
already performed. That removed the remaining generic `<=`/`-` from the
match path. q0/q1 decode now reaches 995/707 MiB/s on text, 165/152 on HTML,
209/172 on JSON, 157/146 on source, and 139/145 on binary; geomeans are
0.34x/0.48x of C. A 64-bit short-copy experiment and a reader mask table
were both measured and reverted (slightly slower than the unrolled byte copy
and inline `ash 1 n`, respectively).

A third decoder change precomputes a direct 704-entry command LUT
(`+cmd-ilen-base+/bits`, `+cmd-clen-base+/bits`), replacing the RFC
cell/sub-code arithmetic in the hot loop, and inlines `%copy-match-bytes`
into the typed copy entry point. q0/q1 decode reaches text 1063/724 MiB/s,
HTML 176/163, JSON 229/189, source 169/156, binary 145/151; geomeans rise
to 0.35x/0.55x of C.

A register-resident bulk literal decoder (accumulator, bit count, and input
position in locals, refilling from the input SAP, like C's
`BrotliCopyPreloadedSymbolsToU8`) was implemented and measured. After
guarding the primary-table width it was correct, but 5-7% slower than the
inlined per-symbol reader in SBCL, so it was reverted.

## Chain matcher (q2-q11)

Profiling q5 showed `INS` at 39% on text and `FIND-MATCH` at 64% on HTML
(with `MLEN` already inlined). Changes:

* inline `hash`, `ins`, and `mlen` inside `%LZ77`;
* add C's 4-byte `best_len` probe before `FindMatchLengthWithLimit`: a
  candidate that cannot beat the current best length is rejected with one
  32-bit compare. The chosen match is unchanged, so the ratio is unchanged;
* tried C's last-distance checks (4 entries): <1.5% ratio gain for 3-5%
  speed loss, so they were not kept.

Effect: q5 HTML 18.4->25.5, q6 14.7->21.2, q7 12.9->18.3, q8 10.2->14.4,
q9 8.7->12.0 MiB/s; q10/q11 also improve (q11 compression 3.24x). q9's
geomean rose from 0.44x to 0.54x.

## Chain table representation and StoreRange

The generic q2-q11 matcher allocated an 8-byte fixnum `prev` table (8 MiB
for a 1 MiB input), filled it with -1 on every call, and a 1 MiB fixnum
`head`. Both are now `(unsigned-byte 32)`, and `prev` needs no initial fill
because only positions that were inserted are ever followed. This alone
lifted text q4 from 259 to 656 MiB/s and q5-q9 by 10-20%.

C's `StoreRange` short-distance rule was then ported: for a match with
`distance < length/4`, insert only the last `distance*4` positions of the
match instead of all interior positions (avoids chain poisoning on RLE-like
data). This lifted text q5-q9 from ~110 to 330-370 MiB/s with unchanged
output size. q9 now beats C overall (1.46x geomean, text 1.99x), and
q7/q9/q10/q11 beat it on text; q10/q11 compression are 9.44x/8.07x.

## Flat fast-fragment command vector

q0/q1 stored commands as five-element lists and then walked them twice
(histogram pass, emission pass). They now use a growable
`(unsigned-byte 32)` vector of `(insert, lit-start, copy, distance)`
records shared by both passes. Output sizes are identical. q0 HTML
100->121, JSON 162->181, source 202->239, binary 104->121 MiB/s; q0
source now beats C (1.03x). Initial capacity is `n/32` commands: a larger
preallocation (`n/8`) made text slower by zeroing more memory.
