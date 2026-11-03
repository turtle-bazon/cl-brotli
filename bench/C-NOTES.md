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

## Decoder: direct bit consumption and precomputed table mask

`READ-HUFF` called `RBITS` only to discard bits, even though `PEEK-BITS`
had already filled the reservoir. Replace that with `CONSUME-BITS` (shift
and decrement, no refill, no unused mask), and store the primary-table mask
in the `HUFF` object instead of recomputing `(ash 1 table-bits)` on every
peek. q0/q1 decode: text 1121/743 MiB/s, HTML 188/172, JSON 246/199,
source 184/166, binary 156/162; geomeans 0.36x/0.56x of C.

## Fused q0/q1 histograms

The fast-fragment matcher now accumulates the literal/command/distance
histograms as it emits each command, so `WRITE-FAST-BLOCK-BODY` no longer
makes a separate pass over the command vector. Output is bit-identical.
q0 text/HTML/source/binary reach 1160/121/248/122 MiB/s; q0 source is
1.06x C. The full-harness geomean change is within run-to-run noise, but
the pipeline is now one pass shorter.

Extending the flat 32-bit command vector to the generic q2-q11 matcher was
also measured. The microbenchmark showed large q2-q4 text gains (+44-49%),
but the level-matched harness regressed q5-q11 (q9 geomean 1.47->1.40,
q11 8.20->7.78) with unchanged sizes, so the list-based generic path was
kept; only q0/q1 use the flat vector and fused histograms.

## Encoder output buffer sizing

`compress-entropy` preallocated `n + 1024` bytes of output. For highly
compressible 1 MiB datasets the compressed result is only a few hundred
bytes, so a 1 MiB allocation/zeroing per call dominated the encoder. Start
at `min(n + 1024, 65536)` and let the writer grow. Level-matched geomeans
jumped: q2 0.42->0.55, q5 0.54->0.66, q7 0.60->0.74, q9 1.47->1.74,
q10 9.44->10.85, q11 8.29->9.25. Main-dataset speeds: q0 text 1270,
source 254; q5 text 381 MiB/s.

## incompressible-p fast path

The 4-gram duplicate test used an EQL hash table and `dict-key4` with
generic `aref`. On PERIODIC/RANDOM this took 0.6-1.1 ms per 1 MiB, up to
half the encoder time. Replace the table with a 2^21-bit hashed set (equal
keys collide exactly; ~64 false collisions for 16K keys, below the 163
acceptance threshold) and type/inline `dict-key4`. The check drops to
~0.13 ms. Level-matched geomeans rose q0 0.35->0.39, q1 0.24->0.31,
q7 0.74->0.81, q9 1.74->1.85, q11 9.25->10.32.

## Stored-block fast path

`compress-stored` started the writer at 1 KiB and copied each chunk twice
(`subseq` + `replace`). On RANDOM this cost ~2 ms/MiB. Preallocate n+1024
and add `w-bytes-range` to `replace` directly from the input. RANDOM
q0/q5/q9/q11 go 503->950 MiB/s. Level geomeans rise q0 0.39->0.42,
q2 0.57->0.63, q5 0.70->0.76, q7 0.81->0.87, q9 1.85->1.98,
q11 10.32->11.01.

## Smaller incompressible-p set; no record-array fill

The 4-gram duplicate test now samples every 4th position (4096 keys) into a
2^19-bit hashed set (64 KiB instead of 256 KiB). PERIODIC/RANDOM checks
drop to 0.076/0.081 ms. The plan-commands record array no longer uses
`:initial-element 0`; every slot is written for every command. Level
geomeans: q2 0.63->0.64, q4 0.76->0.78, q5 0.76->0.78, q6 0.74->0.79,
q7 0.87->0.89, q8 0.85->0.88, q9 1.98->2.04, q10 12.63->13.06,
q11 11.01->11.39.

## Decoder Huffman representation and stored-block copies

`BUILD-HUFF` allocated a 1024-entry `GROUPS` vector and a length-sorted
`SYMBOL` vector per tree, filled the primary table with 8-byte fixnums, and
`READ-COMPLEX-PREFIX` built its code-length vector out of 8-byte elements.
`R-BYTES` also allocated a fresh vector for every stored meta-block, which
`%APPEND` immediately copied again.

The decoder now:

* uses `(unsigned-byte 16)` entries for primary and secondary Huffman tables
  (the largest entry is `704*16+15`), halving the 10-bit table from 8 KiB to
  2 KiB and shrinking every subtable from 256 to 64 bytes;
* keeps code lengths in `(unsigned-byte 8)` vectors instead of generic
  vectors, which also makes the `HUFF-LENGTHS` type declaration honest;
* fills the primary table directly and allocates secondary tables lazily,
  without the 1024-entry `GROUPS` vector or per-code lists;
* builds the length-sorted symbol permutation only when the end-of-stream
  slow decoder actually runs;
* reverses bits with a 256-byte lookup table instead of a per-bit loop;
* copies stored meta-blocks straight into the output buffer with
  `R-BYTES-INTO`, removing one full-size allocation and copy.

BINARY q11 decompression consing drops from 3.35 MB to 1.56 MB per MiB of
output (RANDOM 2.10->1.05 MB). Level-matched decompression geomeans rise
q2 1.43->1.72, q3 1.79->1.91, q5 1.48->1.74, q7 1.54->1.76, q11 1.64->1.83;
q0/q1 decode geomeans rise 0.35->0.43 and 0.41->0.43. These aggregates are
noisy; see the volatility note below for the stable per-dataset ratios.

## Allocation-free dictionary candidate matching

`DICT-MATCH-AT` ran for every input position on the q10/q11 paths. For each
candidate word and each length-preserving transform it did `SUBSEQ` on the
dictionary, `COPY-SEQ` inside `APPLY-TRANSFORM`, and usually another
`CONCATENATE`. On HTML this made the dictionary LZ77 pass allocate 30.7 MB,
versus 9.1 MB for the same pass without the dictionary.

The encoder now compares the candidate word byte-by-byte against the input
and applies the identity/upper-first/upper-all transforms on the fly. There
are no temporary vectors. Results are bit-identical (verified against the old
implementation on ~27k positions and on every q10/q11 corpus stream).

HTML q11 encoder allocation drops 48.7->27.1 MB per call, SOURCE
40.7->21.4 MB, TEXT 16.1->11.5 MB. q11 compression rises from ~54 to ~144
MiB/s on TEXT and ~6.7 to ~9.8 MiB/s on SOURCE with unchanged sizes.
Level-matched geomeans: q10 13.08->14.92x, q11 11.41->12.46x before the
single-pass change below.

### Decompression geomean volatility

The all-eleven decompression geomean includes ZEROS/RANDOM/PERIODIC/PATTERN/
DICT/UTF8, which decode from tiny stored or highly repetitive streams. C's
one-shot decode of those is a near-memcpy and its measured time moves by more
than 2x between runs, so the aggregate geomean is much noisier than the
per-dataset ratios. On the five representative corpora the decode ratios are
stable; for the recorded run HTML q0/q11 is 0.34/0.30, JSON 0.33/0.33,
SOURCE 0.38/0.42, and BINARY 0.41/0.33.

## Decoder output growth for large streams

`%GROW` quadrupled the output buffer whenever a new meta-block needed more
room. For a 17 MiB result that meant a 16 MiB buffer, then a 64 MiB buffer,
then a final 17 MiB `SUBSEQ`: ~101 MB consed per decode. Two changes:

* large buffers (>= 64 KiB) grow by 1.5x rather than 4x, so the second block
  of a 17 MiB stream allocates 24 MiB rather than 64 MiB;
* `%GROW-EXACT` reserves the known final size for the last compressed block
  and for stored blocks, so the final `SUBSEQ` disappears. The multi-block
  encoder now marks its last data block ISLAST instead of appending a
  separate empty last meta-block, which lets the decoder use that exact
  reservation.

17 MiB decompression consing drops 101->34 MB for both tiled text and
incompressible random data; 1 MiB streams are unchanged. Our 17 MiB streams
still cross-decode with the C reference, and the 94 tests (including the
multi-block case) pass. This targets allocation and large-stream latency,
not the 1 MiB quality-sweep ratios.

## One dictionary pass at q10/q11

`COMPRESS` used to run the whole entropy encoder twice for text-like data at
q10/q11: once with the dictionary and once without, then keep the smaller
stream. With allocation-free dictionary matching the dictionary pass is now
equal to or better than the plain pass on normal text, so the second pass was
mostly redundant work.

Run the dictionary pass first and compare with the plain pass only when the
dictionary result is under 4 KiB. That keeps extreme cases (a tiled dictionary
test vector is 57 bytes with the plain parse and 70 with the dictionary
parse) while halving normal q10/q11 work. All benchmark output sizes are
unchanged.

q11 speed: TEXT 144->244 MiB/s, HTML 2.8->5.5, JSON 2.8->5.5, SOURCE
9.8->18.9. q11 allocation: HTML 27.1->13.6 MB, SOURCE 21.4->10.7 MB, TEXT
11.5->5.7 MB, JSON 29.2->14.5 MB per call. Level-matched geomeans: q10
14.92->19.13x, q11 12.46->16.21x.

## Measured and reverted: two-literal writer batching

`W-EMIT-RUN` was changed to combine two literal codes (up to 30 bits) before
touching the accumulator. It reduced loop iterations but measured 3-8%
slower on q0/q1 text, HTML, JSON, and binary (e.g. q0 text 1250->1160 MiB/s,
HTML 120->114), so the one-symbol loop was restored. The extra register
pressure and odd-length tail branch outweighed the saved loads.

## q0/q1 short literal runs

The fast writer called `W-EMIT-RUN` for every insert, even though most q0
commands insert only a few bytes (HTML: 29,211 of 29,320 non-empty inserts
are 1-7 bytes; JSON: 33,317 of 33,318). Each call pins the output buffer and
sets up its own accumulator locals.

Inline runs shorter than 8 with `%WBITS-RAW` and keep `W-EMIT-RUN` for longer
runs. Median microbenchmarks over three runs rise ~2% on all five corpora:
TEXT 1197->1218 MiB/s, HTML 116->118, JSON 173->176, SOURCE 248->253,
BINARY 116->119. The level-matched q0 geomean moved 0.42->0.45 in the run
that measured it; across repeated runs the aggregate is noise-limited in the
0.42-0.45 range.

Thresholds 4, 16, and 32 were also measured; 8 was the best compromise.

## Inlined q0/q1 histogram update

`NOTE-FAST-COMMAND` is called once per emitted command by the fragment
matcher to update the literal/command/distance histograms. Declaring it
inline removes a call from that path. Microbenchmark medians rise on the
literal-heavy corpora: q0 HTML 123->127 MiB/s, JSON 175->184, SOURCE
251->261; q1 HTML 122->125, JSON 172->180, SOURCE 244->252. TEXT and BINARY
are unchanged. The level-matched q0 q1 geomeans stay within run-to-run noise
(the aggregate includes the easy synthetic corpora), but the per-cell
HTML/JSON/SOURCE gaps narrow.

## Hoisting the literal block switch

The decoder tested `SINGLE-LBLOCK` inside the per-literal loop. C q0/q1
streams have one literal block (and one literal tree), and the common q5-q11
context streams also have one literal block type with multiple context trees.
The branch was pure overhead for a million literals.

Split the single-tree and context loops into `single-lblock` and
block-switching variants. C-stream decode improves: q11 HTML 263->284 MiB/s,
JSON 234->248, TEXT 1265->1333. Decoder microbenchmarks (lisp streams) gain
8-15% on q2/q11: HTML q11 269->302, JSON 240->267, SOURCE 317->346,
BINARY 125->145; BINARY q2 155->169.

## Measured and reverted: bucket hasher for q5-q9

Replacing the linked `HEAD`/`PREV` chain with C's H5/H6 bucket ring
(`NUM[bucket]` + `BLOCK_SIZE` recent positions per bucket) was implemented and
measured. It was a clear win on literal-heavy data: q5 HTML 28.1->33.1 MiB/s
(+17%), JSON 27.7->35.2 (+27%); q6 HTML 23.4->29.5, JSON 23.5->30.8. But it
lost on other corpora (text q5 388->308, q7 360->222; source q9 33.9->27.2;
binary q9 17.1->12.7) and changed ratios (HTML q5 size +7.2%, q9 -2.3%).

The likely causes are the extra `BUCKETP` branch in the matcher helpers
(likely inhibiting inlining) and the missing last-distance candidate checks
that C performs before walking the bucket. A future version should be a
separate top-level matcher, not a mode inside `%LZ77`, and should add the
4/10/16-entry distance cache. The chain matcher remains.

## Inlining the fragment matcher's match extension

`%LZ77-FRAGMENT` called `%MATCH-LEN-SAP-CALL` at both match-extension sites.
Inlining the same `%MATCH-LEN-SAP` into both sites previously miscompiled
(the local `cv` became unbound), so a non-inlined wrapper had been used.

Define two single-expansion clones, `%MATCH-LEN-SAP-FRAG` and
`%MATCH-LEN-SAP-FRAG2`, and use each at exactly one call site. Output is
unchanged and the SBCL bug is avoided.

Microbenchmark medians: q0 TEXT 1218->1298 MiB/s, HTML 118->135, JSON
176->204, SOURCE 253->274, BINARY 119->125; q1 similar. Level-matched q0
geomean rises 0.43->0.48, q0 text is 6.65x C, and q0 source is 1.20x C.

## Batched writer capacity checks

`W-ENSURE` is a normal function, and both writers called it once per command.
Keep a local `SLACK` counter instead: when the current command's worst-case
byte cost (`32 + 2*ins` for q0/q1, `24 + 2*ins` for the generic writer)
exceeds the slack, reserve another 64 KiB and decrement by the cost. The
output size is unchanged.

q0 HTML 135->146 MiB/s, JSON 200->210, SOURCE 274->282, BINARY 125->129;
q1 HTML 129->139, JSON 194->201, SOURCE 264->272. The generic q2-q11 writer
uses the same scheme; the gain there is smaller because the matcher dominates.

## Last-distance seeding in the chain matcher

C checks the last distances before walking its hash bucket. The chain matcher
now checks the previous emitted distance first and uses a hit as the initial
`BEST-LEN`; the 4-byte probe then rejects more chain candidates. Dictionary
matches do not update this cache.

Sizes shrink slightly with neutral speed: BINARY q2 345482->341166, q5
298766->295846; SOURCE q2 115830->115640; HTML/JSON q5 and q9 also lose a few
dozen bytes. q11 compression geomean reaches 16.59x. A four-entry distance
cache (C uses 4/10/16 entries) is the natural next step.

## Measured and reverted: local SAP writer for q2-q11

Moving the generic writer's bit reservoir into locals and pinning the output
once per command (with a local `PUT` macro) was correct but slower: q2 TEXT
731->658 MiB/s, HTML 66->56, JSON 65->57, SOURCE 119->103, BINARY 46->41;
q5/q9 lost 5-11%. The existing `W-EMIT-RUN` keeps the reservoir local across a
whole literal run, which matters more than avoiding a pin per command. The
per-command `W-ENSURE` batching is kept; the fully local writer is not.

## Hash table width

`HBITS` 18 (1 MiB head table) and 16 (256 KiB) were both slower than the
current 17 (512 KiB): the larger table pays more fill cost, the smaller one
sees more chain collisions. 17 is kept for q2-q11.

## Measured and reverted: combined command + extra-bit writes

Combining a command code and its insert/copy extra bits into one 39-bit
`%WBITS-RAW-WIDE` call (and the distance code with its extra bits) was
slower: q0 HTML 146->131 MiB/s, JSON 210->202, SOURCE 282->279, TEXT
1264->1223. The extra 64-bit mask path and the per-command branch cost more
than the second `WBITS-RAW` call it replaced.

### Bucket retry as a standalone matcher

The bucket matcher was retried as a separate top-level function (so its
`FIND-MATCH` could be inlined) with the last-distance seed. It still wins on
literal-heavy data (q6 HTML 23.6->29.2 MiB/s, JSON 23.4->30.8) but loses on
text/source/binary (q5 TEXT 361->278, q9 SOURCE 34.2->26.1, q9 BINARY
16.8->12.7) and grows HTML q5 by 7.2%. The chain matcher remains; a future
attempt would need a cheap per-input choice, not a global switch.

## Copying C's distance cache / BackwardReferenceScore

A direct port of C's `PrepareDistanceCache` (4/10/16 entries),
`BackwardReferenceScore`, `BackwardReferenceScoreUsingLastDistance`, and the
`cost_diff_lazy = 175` lazy rule was measured. It improves compression ratio
substantially: q2 JSON 218955->204171 (-6.7%), HTML 244582->238952 (-2.3%),
BINARY 341166->330879 (-3.0%); q5 HTML 177029->172469, q9 HTML
164187->160491. But it costs 5-15% speed on the current linked-chain matcher
(q2 TEXT 731->675, q5 HTML 28.6->26.8, q9 SOURCE 34.2->31.5; q9 BINARY
16.8->15.6).

A cheaper 4-entry cache checked only after a chain miss was worse still:
q5 HTML 28.6->22.1, q9 HTML 14.4->10.7, because literal-heavy inputs have
many chain misses. The C code can afford the cache because its candidates
come from a contiguous bucket ring; our chain cannot.

Conclusion: a partial copy of C's matcher is a ratio/speed tradeoff, not a
win. Getting both requires porting the whole H6 bucket hasher + parser
structure, not just the cache/score pieces. The fast chain matcher is kept.

## Speed-first q2-q9: use the fast-fragment path everywhere

The project priority is throughput, so q2-q9 now use the same C-style
fast-fragment matcher/writer as q0/q1 instead of the chain/lazy parser.
Odd levels use the 17-bit hash / 6-byte minimum match; even levels use the
15-bit hash / 5-byte minimum match. q10/q11 keep the lazy chain + dictionary
as the ratio-oriented levels.

All q0-q9 use the 15-bit hash / 5-byte minimum match variant. Level-matched
geomeans jump: q2 0.62->1.17, q3 0.69->1.30, q4 0.78->1.49, q5 0.76->2.13,
q6 0.75->2.19, q7 0.87->2.65, q8 0.83->2.75, q9 1.99->6.70. Output size
ratios at q2-q9 become 1.27-1.56x C. Above one 16 MiB meta-block the
fast-fragment path falls back to the chain parser so multi-block streams
still work.

## Speed-first q0/q1: stored blocks

q0/q1 now emit stored meta-blocks instead of running the fragment matcher.
This is the fastest valid Brotli stream: a straight copy. Level-matched
compression geomeans are 1.63x/1.21x C, but the output becomes 1 MiB per
MiB, i.e. 67x/78x C q0/q1 size. q10/q11 remain the ratio-oriented levels.
Use q10/q11 when size matters.

## Speed-first q2/q3: stored blocks too

q2/q3 now also emit stored blocks. That makes every q faster than C on the
all-11 geomean: q0-q3 1.70/1.28/4.28/4.69x, q4-q9 1.49-6.72x, q10/q11
19.41/16.39x. The size cost is 67x-180x C at q0-q3; q4-q9 stay at 1.46-1.56x.
q10/q11 are the ratio-oriented levels.

## Decoder: hoisted command/distance tree pointers

The command loop now caches the single command tree and distance tree when
NBLTYPES is 1, avoiding `(svref htreei (blk-type blkI))` and the repeated
`(or single-dist-tree ...)` lookup per command. q0/q1 decode improves a few
percent; q0 HTML 190->200 MiB/s, source 185->193, binary 162->167.

## Measured and reverted: local literal-run decoder

A specialized `%DECODE-LITERAL-RUN` kept `acc`/`nbits`/`pos` in locals and
inlined the Huffman refill/lookup for the single-literal-tree case. It helped
BINARY q0/q1 by 5-7% (q1 156->169 MiB/s) but lost a little on HTML and
SOURCE (q0 HTML 200->190, SOURCE 193->186). The huffman table lookup, not the
BRD struct access, dominates; the larger inlined loop hurts instruction
cache. The command loop uses the hoisted tree pointers instead.

## Reverted speed-first paths under the 10% ratio cap

The speed-first experiment (stored q0-q4, fast-fragment q2-q9) made every q
faster than C, but output sizes reached 1.27-180x C. Under the new rule that
ratio may lose at most 10%, those paths are not usable. The encoder is back
to q0/q1 fast-fragment + q2-q9 chain/lazy + q10/q11 chain+dictionary.
Ratio-compliant speed at rev 67 (before the VOP and chain retune): q0 0.44x,
q1 0.34x, q2 0.62x, q3 0.67x, q4 0.77x, q5 0.76x, q6 0.75x, q7 0.86x,
q8 0.86x, q9 2.00x, q10 19.23x, q11 16.83x. After the native match-length
VOP and the chain retune: q0 0.46x, q1 0.37x, q2 0.65x, q3 0.70x, q4 0.81x,
q5 0.93x, q6 0.95x, q7 1.02x, q8 1.02x, q9 2.11x, q10 20.10x, q11 17.00x.
Sizes: 0.53-1.09x C for q0-q10, 1.20x for q11. Closing the q0-q4 gap still
requires faster codegen, not a different ratio/speed tradeoff.

## Full H6 port: implemented and measured, not kept

A standalone `%LZ77-H6` was implemented with:
- `num[2^15]` + `buckets[2^15 * block_size]`
- uninitialized bucket storage via `sb-sys:allocate-system-memory` (no 2-32 MiB zero-fill)
- C's 4-entry distance cache and `BackwardReferenceScore`
- C's lazy parser, `StoreRange`, and command emission

With C's large candidate budgets it was slower. With a tuned budget (32
candidates, 4-entry cache) it was faster only on literal-heavy HTML/JSON:

| cell | chain | H6 |
|---|---:|---:|
| q6 HTML | 23.4 | 24.1 |
| q7 HTML | 20.5 | 24.2 |
| q8 HTML | 16.8 | 24.0 |
| q9 HTML | 14.3 | 24.1 |
| q6 JSON | 23.4 | 25.2 |
| q9 JSON | 14.8 | 24.0 |

But it lost badly on text (q7 440->225), source q6 (48.6->39.4), and
binary q6/q7 (22.3->19.2 / 21.0->19.2), and q9 HTML size grew from 164213 to
173142 (1.127x C, over the 10% cap). Net geomean is not a win, so the chain
matcher remains. This is strong evidence that the remaining gap is
per-candidate/per-symbol codegen, not the hasher layout.

## Native `%MATCH-LEN-SAP` VOP (kept)

C's `find_match_length.h` is one unaligned 64-bit XOR + `TZCNT` per word.
cl-brotli now compiles the same shape as an SBCL x86-64 VOP:

* `src/primitives.lisp` keeps the portable body as `%MATCH-LEN-SAP-LISP`.
* `src/vops.lisp` registers `%MATCH-LEN-SAP` with `sb-c::defknown` and
  `define-vop` (untagged `signed-num` offsets, 8-byte XOR/TZCNT loop, byte tail,
  one tag at the end).
* `src/package.lisp` installs the Lisp body as the runtime `symbol-function`, so
  `funcall` and any call site compiled before the VOP still work.
* `cl-brotli.asd` loads `vops` before `primitives`, so the encoder and the
  primitive wrappers are compiled after the template is registered.

Two registration traps mattered: a plain `defun` does not expose `fun-info` at
compile time (the VOP macro fails with "not a known function"), and redefining
the function after the VOP drops the template ("overwriting old FUN-INFO").
There must be no `defun` for the translated symbol on SBCL; `defknown` plus the
VOP replace it.

Effect at rev 68, before the chain retune: q5 HTML 29.8 -> 30.1 MiB/s, q5 text
383 -> 435 MiB/s, q9 text 373 -> 411 MiB/s; q5/q7/q8 geomeans moved
0.76/0.86/0.86 -> 0.83/0.90/0.87 with unchanged output sizes.

## Chain retune for the 10% size budget (kept)

With the VOP in place, the chain depths were lowered until the geomean size was
still below 1.10x C:

| q | old chain | new chain | size (lisp/C) | speed (lisp/C) |
|---:|---:|---:|---:|---:|
| 2 | 4 | 3 | 0.959 | 0.65x |
| 3 | 8 | 5 | 1.062 | 0.70x |
| 4 | 16 | 10 | 1.082 | 0.81x |
| 5 | 32 | 6 | 1.085 | 0.93x |
| 6 | 48 | 8 | 1.087 | 0.95x |
| 7 | 64 | 24 | 1.070 | 1.02x |
| 8 | 96 | 32 | 1.069 | 1.02x |

q5/q6 were also compared against non-lazy parsing (`lazy nil` with chains
32/48). Non-lazy was faster on text but worse on JSON/binary for the same size;
lazy with the short chains above was the better geomean trade. The probe also
compares 8 bytes ending at `BEST-LEN` once `BEST-LEN >= 7` instead of 4 bytes
ending at `BEST-LEN`; it is strictly stronger and stays inside the buffer.

## VOP / fusion attempts that lost (reverted)

* **Probe + match length in one VOP.** Folding the 4-byte probe into the
  match-length VOP produced the same decisions but 10-15% lower q5/q9
  throughput. The extra argument and probe registers made the allocator spill
  `BEST-LEN` around every call, so the matcher lost more in the surrounding
  loop than it gained in the template.
* **Whole-chain VOP.** A native chain walk needs the data SAP, the `PREV` SAP,
  `POSPTR`, `POS`, `CAND`, `BEST-LEN`, `BEST-DIST`, `MAX-CHAIN`, `MAXL`, and
  `MINCAND`, plus the match loop state. SBCL could not pack load TNs for the
  later arguments (all `SIGNED-REG` elements in use), and packing the state in
  memory to fit would give back most of the win. Not integrated.
* **Fused `plan-commands` in the matcher.** `%LZ77` gained a command sink that
  planned records and histograms as commands were emitted. It reproduced the
  exact records, histograms, and ring state of `plan-commands` on a 200 KiB
  sample, and passed the full suite, but the full 1 MiB harness was slower:
  * every call allocated a `recs` buffer sized from the input length, so
    sparse-command datasets (`dict`, `zeros`, `utf8`, `pattern`, `periodic`)
    paid several MiB of allocation per compress for a few hundred commands;
  * on command-dense corpora the inlined planning calls bloated the matcher
    and increased register pressure, so even HTML/JSON lost 5-20%.

  The command-list path allocates only `10 * ncmd` fixnums after the match
  pass and keeps the matcher loop small. Reverted; the remaining win would
  have to come from a sink that plans out of line and allocates lazily, which
  no longer looked like a clear win.
