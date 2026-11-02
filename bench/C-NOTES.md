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

Ported into cl-brotli: the matcher (`%LZ77-FRAGMENT`) and q0's sampled
literal histogram (`FAST-LITERAL-HISTOGRAM`). q1 text went from 354 to
926 MiB/s, q0 text from 707 to 954 MiB/s, and q0 output is now 0.34-0.95x
the size of C q0 because the sampled pre-LZ77 histogram replaces the exact
post-LZ77 one.

Not yet ported: q0's one-pass emission with the fixed command alphabet.
`BuildAndStoreCommandPrefixCode` maps the 64 fast codes onto the full
704-symbol command alphabet (`0..7 -> 0..7`, `8..15 -> 64..71`,
`16..23 -> 128..135`, `24..31 -> 192..199`, `32..39 -> 384..391`,
`40..47 -> 128+8i`, `48..55 -> 256+8i`, `56..63 -> 448+8i`; distance codes
64..127 map to distance symbols 0..63). A faithful port needs that mapping,
the default depth/bit tables, and emission during the scan instead of the
flat command records.
