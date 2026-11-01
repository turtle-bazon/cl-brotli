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
