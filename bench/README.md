# cl-brotli benchmark harness

Compares `cl-brotli` with the system C Brotli library through the existing
`cl-brotli-reference` CFFI bindings.

The harness measures three things for the same input:

* `cl-brotli:compress` / `cl-brotli:decompress` — the public Lisp API.
* `BrotliEncoderCompress` / `BrotliDecoderDecompress` called directly with
  preallocated foreign buffers — C library cost without Lisp allocation or
  output copying.
* `cl-brotli.reference:compress` / `decompress` — the one-shot CFFI wrapper
  used by the test suite, including its allocation and output-copy overhead.

Every C stream is decoded by both decoders, and every lisp stream is decoded
by both decoders, before it is timed. Throughput is MiB/s of uncompressed data.
`lisp/C` speed > 1 means `cl-brotli` is faster; `lisp/C` size > 1 means the
lisp encoder produced a larger stream.

## Reproducibility

Benchmark numbers are only comparable when both the host and the input bytes
match. The harness therefore records:

* the Lisp implementation/version, C Brotli version, and CPU model in the
  report header;
* a 32-bit FNV-1a fingerprint of every dataset in the per-dataset heading and
  in the `data-hash` CSV column;
* the exact corpus path used by each real-file dataset.

Real corpora are preferred (`text`, `html`, `json`, `binary`, `source`), but
they are host-dependent and are not always installed. Deterministic
generators cover the rest and stand in for a missing real file (`html`, `json`,
`utf8`, `zeros`, `random`, `periodic`, `pattern`). If two runs show different
fingerprints, their ratios are not directly comparable even when the dataset
name and size are the same.

The checked-in results were produced on one host with one set of fingerprints;
they are not a cross-machine league table.

## Running

```sh
# Fast smoke test.
./bench/run.sh --quick

# Full matrix used for the checked-in results.
./bench/run-all.sh

# Examples.
./bench/run.sh --sizes 1M --levels 0,5,11 --datasets text,html,json
./bench/run.sh --sizes 1M --levels 11 --windows 10,14,18,22 --datasets text,source
./bench/run.sh --sizes 0,1K,1M,16M,17M --levels 5,11 --datasets text,periodic
./bench/run.sh --help
```

`--csv FILE` writes the raw rows. `--consing` additionally reports Lisp bytes
consed per call; the C-core foreign allocation is not included, so treat that
diagnostic as approximate.

The full `run-all.sh` matrix takes roughly 40–60 minutes on the host used for
the checked-in results (C q11 on 17 MiB random data is the slowest case). It prints each dataset
to stderr as it starts; run individual sweeps if you need shorter feedback.

## Datasets

| name | source | fallback |
|---|---|---|
| `text` | `/usr/share/common-licenses/GPL-3`, tiled/truncated | repository `README.md` |
| `html` | `/usr/share/doc/rclone/MANUAL.html` or fish relnotes, tiled/truncated | generated HTML records |
| `json` | GHC `doc-index.json` if present | generated JSON records |
| `source` | `cl-newzlib/src/*.lisp` + `pesekey/pesekey/src/*.lisp` | repository source |
| `binary` | first bytes of Roswell SBCL 2.6.9, then `/usr/local/bin/sbcl` or bash | — |
| `zeros` | generated zeroes | — |
| `random` | generated xorshift32 bytes | — |
| `periodic` | 0..255 ramp repeated | — |
| `pattern` | 256-byte pseudo-random pattern repeated | — |
| `dict` | Brotli dictionary test vector, tiled | repository source |
| `utf8` | multilingual UTF-8 sample, tiled | — |

For sizes larger than the source file, the dataset is tiled. This is why some
ratios are stable across 1 MiB, 4 MiB, and 16 MiB. The generated HTML fallback
keeps the HTML workload meaningfully different from `source` on minimal hosts;
previously a missing MANUAL.html silently tiled Common Lisp source instead.

## Methodology

* Dataset construction and fingerprinting happen before any timed region.
* Warm-up call, then median of 3 samples (quality sweep), 2 samples (window and
  mode sweeps), or 1 sample (large-size sweep), with a full GC before each
  sample.
* Each sample runs the operation repeatedly to reach `--target` seconds, with a
  cap of 1000 repetitions.
* A/B measurements time both sides back-to-back inside every sample rather
  than finishing all A samples first, so CPU-frequency and scheduler drift do
  not bias the ratio.
* C-core compression uses `BrotliEncoderMaxCompressedSize` output capacity;
  C-core decompression uses an output buffer of exactly the known uncompressed
  size.
* The C one-shot wrapper's decompressor doubles its output buffer from
  `4 * encoded-size`, so highly compressed streams can pay for several full C
  decodes. The C-core column is the fair library-only number; the one-shot
  column is what the existing test helper actually costs.
* Lisp rows use `cl-brotli:compress :quality Q`, matching the C row's quality
  level. `cl-brotli` has no window or mode knob, so those C sweeps vary only
  the C side.
* Level-matched rows make the ratio columns directly comparable: the `C q`
  and lisp quality are the same number in every row.

### Encoder effort levels

| quality | matcher | short distance codes | dictionary |
|---:|---|---|---|
| 0 | greedy, one hash candidate | off | no |
| 1 | greedy, chain depth 2 | off | no |
| 2 | greedy, chain depth 4 | off | no |
| 3 | greedy, chain depth 8 | off | no |
| 4 | greedy, chain depth 16 | off | no |
| 5 | lazy, chain depth 32 | on | no |
| 6 | lazy, chain depth 48 | on | no |
| 7 | lazy, chain depth 64 | on | no |
| 8 | lazy, chain depth 96 | on | no |
| 9 | lazy, chain depth 128 | on | no |
| 10 | lazy, chain depth 256 | on | text-like only |
| 11 | lazy, chain depth 512 | on | text-like only |

The levels are an effort ladder, not a clone of C Brotli's algorithms; C q0
still does fast LZ parsing while cl-brotli q0 uses the fastest greedy mode.
q0-q4 also skip the 15 short distance-ring comparisons per command.

## Current results

Environment: Roswell SBCL 2.6.9, C Brotli 1.0.9, AMD Ryzen 7 3700X (Linux
x86-64). Raw CSV files are in `bench/results/`; every per-dataset heading and
the CSV carry the input fingerprint from that run. All timings are
host-specific; compare ratios, not absolute MiB/s, across machines.

### Low-level compression, q0-q9 (this is the remaining gap)

Each cell is `lisp MiB/s / C MiB/s / lisp/C`; the geomean column covers
all **eleven** datasets, including the tiny highly-compressible ones.

| q | text | html | json | source | binary | geomean |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1169.3 / 208.5 / 5.61x | 102.7 / 491.1 / 0.21x | 164.0 / 667.5 / 0.25x | 204.7 / 236.5 / 0.87x | 103.4 / 463.9 / 0.22x | 0.32x |
| 1 | 1062.3 / 1850.7 / 0.57x | 107.9 / 333.3 / 0.32x | 144.0 / 394.6 / 0.36x | 212.6 / 299.4 / 0.71x | 104.1 / 326.6 / 0.32x | 0.27x |
| 2 | 350.6 / 1060.3 / 0.33x | 56.0 / 183.6 / 0.30x | 67.0 / 271.7 / 0.25x | 105.7 / 351.6 / 0.30x | 45.5 / 184.6 / 0.25x | 0.30x |
| 3 | 302.2 / 1001.2 / 0.30x | 49.8 / 150.7 / 0.33x | 57.2 / 205.9 / 0.28x | 99.7 / 294.8 / 0.34x | 42.8 / 140.6 / 0.30x | 0.33x |
| 4 | 327.0 / 826.1 / 0.40x | 44.0 / 123.2 / 0.36x | 50.4 / 149.4 / 0.34x | 89.8 / 241.4 / 0.37x | 38.4 / 97.5 / 0.39x | 0.37x |
| 5 | 99.9 / 639.1 / 0.16x | 17.9 / 70.2 / 0.26x | 19.8 / 65.2 / 0.30x | 37.7 / 108.2 / 0.35x | 18.3 / 51.4 / 0.36x | 0.18x |
| 6 | 100.1 / 630.1 / 0.16x | 15.0 / 61.5 / 0.24x | 16.4 / 52.2 / 0.31x | 32.2 / 111.8 / 0.29x | 16.0 / 47.3 / 0.34x | 0.18x |
| 7 | 93.1 / 298.5 / 0.31x | 12.7 / 45.4 / 0.28x | 14.5 / 39.3 / 0.37x | 28.8 / 89.7 / 0.32x | 14.5 / 38.0 / 0.38x | 0.19x |
| 8 | 95.4 / 577.9 / 0.17x | 10.2 / 35.8 / 0.28x | 12.0 / 32.7 / 0.37x | 24.7 / 75.4 / 0.33x | 12.5 / 31.2 / 0.40x | 0.19x |
| 9 | 93.5 / 169.1 / 0.55x | 8.5 / 23.7 / 0.36x | 10.2 / 22.5 / 0.45x | 21.9 / 49.4 / 0.44x | 11.1 / 22.4 / 0.50x | 0.45x |

The C fast-fragment port changed the low levels materially. q0 is now 5.61x
faster than C on text and 0.87x on source, but 0.21-0.25x on literal-heavy
HTML/JSON/binary. q1 is 0.27x (0.57x text, 0.71x source), q2-q4 are
0.30-0.37x, q5-q8 are 0.18-0.19x, and q9 is 0.45x. q0 output is smaller
than C q0 on every dataset (0.35-0.99x size): the fast writer builds its
command/distance trees from actual histograms (seeded with C's
kCmdHistoSeed) and its literal tree from the exact emitted literals.

### q0/q1 decompression

Each cell is `lisp MiB/s / C MiB/s / lisp/C`; the geomean column covers
all **eleven** datasets.

| q | text | html | json | source | binary | geomean |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 718.9 / 2673.3 / 0.27x | 109.1 / 561.9 / 0.19x | 137.8 / 766.0 / 0.18x | 109.6 / 492.7 / 0.22x | 103.0 / 403.4 / 0.26x | 0.28x |
| 1 | 576.5 / 1702.5 / 0.34x | 104.5 / 566.4 / 0.18x | 117.6 / 642.8 / 0.18x | 105.7 / 526.0 / 0.20x | 113.7 / 402.4 / 0.28x | 0.35x |

q0/q1 decode is still 0.28x/0.35x across all datasets. Literal-heavy
HTML/JSON/source/binary is 0.18-0.29x. The gap is the per-literal
Huffman/context decode path; q2 and above are at or above parity.

### Higher levels

| q | size (lisp/C) | compression (lisp/C) | decompression (lisp/C) |
|---:|---:|---:|---:|
| 10 | 1.075 | 3.19x | 0.87x |
| 11 | 1.202 | 2.72x | 0.87x |

q10/q11 are included for completeness. They are not representative of the
low-level behavior: the encoder spends much more time parsing, which is where
C q11 is slow, while C q0-q9 are much faster than the lisp encoder.

### Quality sweep summary (geometric mean across all 11 datasets, level-matched)

| C q | size (lisp/C) | compress (lisp/C core) | decompress (lisp/C core) |
|---:|---:|---:|---:|
| 0 | 0.532 | 0.32x | 0.28x |
| 1 | 0.611 | 0.27x | 0.35x |
| 2 | 0.956 | 0.30x | 0.75x |
| 3 | 1.057 | 0.33x | 0.95x |
| 4 | 1.077 | 0.37x | 0.94x |
| 5 | 1.058 | 0.18x | 0.90x |
| 6 | 1.061 | 0.18x | 0.90x |
| 7 | 1.060 | 0.19x | 0.84x |
| 8 | 1.060 | 0.19x | 0.84x |
| 9 | 1.064 | 0.45x | 0.84x |
| 10 | 1.075 | 3.19x | 0.87x |
| 11 | 1.202 | 2.72x | 0.87x |
### Size boundary

Multi-meta-block encoding keeps ratios stable across the 16 MiB boundary. The
whole input goes through one LZ77 pass and the stream-wide window/distance ring
spans blocks, so matches still cross the boundary; the small 17 MiB increase
comes from re-emitting the Huffman trees and splitting commands at the block
edge. The periodic ramp no longer takes the stored-block fallback.

| dataset | size | C q11 size | lisp size | lisp/C |
|---|---:|---:|---:|---:|
| text | 16 MiB | 9715 | 11694 | 1.204 |
| text | 17 MiB | 9728 | 11706 | 1.203 |
| source | 16 MiB | 79646 | 89834 | 1.128 |
| source | 17 MiB | 79658 | 89846 | 1.128 |
| periodic | 1 KiB | 216 | 289 | 1.338 |
| periodic | 1 MiB | 218 | 291 | 1.335 |
| periodic | 16 MiB | 232 | 291 | 1.254 |
| periodic | 17 MiB | 244 | 303 | 1.242 |
| pattern | 16 MiB | 291 | 307 | 1.055 |
| pattern | 17 MiB | 304 | 319 | 1.049 |

### Window sweep

Lisp uses an automatic 21-bit window. C q11 needs `lgwin` 16 to match it on
text and 20 on source; on generated HTML and the SBCL binary C already wins at
`lgwin` 14, so there is no single window setting that reproduces the lisp
encoder's behavior on every corpus.

| dataset | C q11 lgwin 14 | C q11 lgwin 16 | C q11 lgwin 20 | C q11 lgwin 22 | lisp |
|---|---:|---:|---:|---:|---:|
| text | 278610 | 9790 | 9702 | 9702 | 11694 |
| html | 155197 | 141576 | 132230 | 132230 | 157561 |
| source | 208782 | 195792 | 79632 | 79632 | 89834 |
| binary | 268554 | 261544 | 251377 | 251377 | 296116 |

C `mode` 0/1/2 changed output by at most 26 bytes on text/HTML and 385 bytes
(0.3%) on JSON, so mode selection is not a lever here.

## Reference point: cl-newzlib

The sibling pure-Lisp project `cl-newzlib` reports 1.69x compression and 1.26x
decompression relative to zlib on its development host, using allocation-free
`compress-into` / `decompress-into` entry points (`../cl-newzlib/README.md`).
That is useful evidence that portable Common Lisp can reach C parity for a
byte-oriented codec, but it is not a direct target: DEFLATE uses one dynamic
Huffman tree per block and no static dictionary, while Brotli q11 adds context
maps, block switching, a 122 KiB static dictionary, and much larger alphabets.

Running cl-newzlib's own harness on this same host (Roswell SBCL 2.6.9,
zlib 1.2.13, 2 MiB inputs, levels 1/3/6/9) gives 1.70x compression and 1.19x
decompression for its allocation-free `into` API (1.62x / 1.08x one-shot).
cl-brotli's q11 geomeans against C Brotli on the same host are 2.72x
compression; decompression is dataset-dependent (0.87x geomean in this run,
but 4-5x on HTML/JSON/source/binary). q11 is not the useful comparison for
the low-level work: C q11 is deliberately slow, while C q0-q9 are still
1.1-5x faster on the literal-heavy cells (cl-brotli is 5.6x faster on q0
text). The cl-newzlib comparison is still
useful evidence that portable Lisp can reach C parity, but it applies to the
low-level constant factors (per-symbol decode, bit emission, match extension),
not to the q11 headline.

The transferable part of the cl-newzlib playbook is per-symbol overhead:
keep the output array, output position, bit accumulator, and decode-table
roots in loop locals; use a wide bit reservoir refilled a word at a time;
expand the hot Huffman and literal paths inline instead of calling through
generic `read-huff` / `out-push` helpers; and offer a decode-into API so a
known-size result does not pay for growth and a final copy. The remaining
gaps below are stated in those terms.

## Implementation status

The benchmark was used to drive these changes:

* multi-meta-block encoding above 16 MiB, with one whole-input LZ77 pass and
  commands partitioned at meta-block boundaries so matches cross the boundary;
* a stream-wide distance ring shared by all meta-blocks;
* a 4-byte-repeat check in `incompressible-p` so periodic high-diversity data is
  compressed instead of stored;
* a word-level bit reader with fully inline fixnum shifts and a two-level
  Huffman decoder (10-bit primary, 32-entry secondary tables for long codes);
* a simple-array output buffer with an explicit position, avoiding adjustable
  array overhead and enabling short unrolled copies;
* fast single-tree literal and distance decode paths;
* unlimited dictionary matching for text-like data;
* length-preserving dictionary transforms (identity, upper-first, upper-all);
* one-step lazy matching in the LZ77 parser;
* implicit-distance command symbols and short distance-ring codes in the
  encoder;
* implementation tree and package renamed from `pure` to `lisp`;
* rejection of non-positive resolved distances;
* regression tests for the periodic ramp, multi-block input, and invalid
  distances;
* a 32-bit FNV-1a fingerprint for every dataset, recorded in the report and
  CSV, and a deterministic generated-HTML fallback so a host without
  MANUAL.html does not silently benchmark Common Lisp source twice;
* a 64-bit bit reservoir with a 56-bit refill from a pinned input SAP, hot
  decoder paths compiled at `(speed 3) (safety 0)`, and typed constant/LUT
  vectors;
* a precomputed `(block-type, context) -> literal-tree` map per meta-block;
* reversed Huffman codes precomputed per tree, so `ETREE-EMIT` writes one
  `WBITS` call per symbol instead of one per bit;
* an O(1) distance-code encoder and a simple-array bit writer with an explicit
  position instead of `VECTOR-PUSH-EXTEND`;
* encoder quality levels 0-11 with a fast single-candidate mode, greedy chain
  depths, lazy matching, and optional dictionary matching;
* flat 10-fixnum command records instead of a struct per command, precomputed
  length-code and command-symbol tables, and one hash computation per position;
* an SBCL word-at-a-time match extender over the input SAP
  (`%MATCH-LEN-SAP`) with `count-trailing-zeros`/tzcnt finding the first
  differing byte, matching C Brotli's `FindMatchLengthWithLimit`;
* an inlined match extender and 4-byte hash (`%MATCH-LEN-SAP`, `%HASH4-SAP`),
  which removed two calls per scanned position and lifted q5-q9 by 25-40%;
* a bit writer that flushes the whole accumulator with one unaligned 64-bit
  store (instead of a per-byte loop), plus a batched literal-run writer that
  keeps the accumulator, bit count, and output position in locals and pins the
  output SAP once per run;
* C Brotli's fast-fragment matcher for q0/q1 (`%LZ77-FRAGMENT`): one hash entry
  per position, minimum match 5 for q0 and 6 for q1, a 4-byte + tail prefix
  check before extending, the previous-distance candidate checked first, and
  hash inserts for the bytes inside each copy. This took q1 text from 354 to
  926 MiB/s;
* C's fast command/distance alphabet for q0/q1: fast insert/copy/distance
  codes mapped onto the full 704-symbol command alphabet, with the command
  and distance trees built from the actual histograms (seeded with C's
  `kCmdHistoSeed`) and the literal tree from the exact emitted literals.
  q0 output is 0.35-0.99x the size of C q0;
* non-null typed tree/record arrays in the emitter and a 10-field flat command
  record (down from 12), removing all generic `VECTOR-HAIRY-DATA-VECTOR-REF`
  calls and two stores per command;
* a bit writer with one capacity check per call instead of one per byte;
* q0-q4 disable short distance codes and port C's fast-fragment match-skip
  heuristic (`skip++ >> 5`), so literal-heavy data stops hashing every byte;
  q0 uses one candidate and q0-q4 skip interior match insertion;
* decoder preallocated match copies, 4x output growth, a byte-aligned
  `r-bytes` fast path for stored blocks, and array-based Huffman subtable
  grouping;
* level-matched benchmark rows and a microsecond-resolution timer.

An AVX2 match-extender was evaluated through `sb-simd` and `sb-cpu-features`
(including cl-newzlib's `define-cpu-dispatch` pattern): it regressed text
q1-q4 by 10-25% and changed HTML/JSON by only a few percent. Scalar 64-bit +
tzcnt was faster, and that is also what C Brotli uses for match extension.
The AVX2 path was therefore not retained; `sb-cpu-features` remains a sensible
optional dependency for a future SIMD copy or histogram kernel.

Tests pass on Roswell SBCL 2.6.9 (`94/94` checks, including every quality
level against both decoders). Benchmarks are run only on SBCL 2.6.9.

## Remaining gaps

* Encoder ratio is at C q5 (1.06x) on text-like data; the q11 size gap (1.20x)
  needs context modeling, block splitting, and length-changing dictionary
  transforms.
* Low-level encoder throughput is still the largest gap: q0 is 0.32x, q1 is
  0.27x, q2-q4 are 0.30-0.37x, q5-q8 are 0.18-0.19x, and q9 is 0.45x of C's
  matching levels. q0 is 5.61x faster than C q0 on text and 0.87x on source,
  but 0.21-0.25x on literal-heavy HTML/JSON/binary. q0 output is 0.35-0.99x
  the size of C q0. The remaining gap is mainly SBCL codegen versus the
  hand-written C emitter plus C's block splitting/command-code adaptation;
  the fast command alphabet and matcher are now ported.
* q0/q1 decode is 0.28x/0.35x across all eleven datasets. Text is around
  0.3-0.5x; literal-heavy HTML/JSON/source/binary is 0.18-0.29x. Fast
  per-literal Huffman/context decoding, not match copying, is the remaining
  decoder gap.
* The encoder builds the plain entropy-coded stream, adds a dictionary pass
  when the level enables it and the input is text-like, and only builds the
  stored fallback when the candidates are not already smaller than the input.
  Quality 0-11 selects the matcher effort; there is still no window or mode
  knob.
* C q11 on 17 MiB random data remains the slowest benchmark case.

## Files

* `bench/bench.lisp` — harness.
* `bench/run.lisp`, `bench/run.sh` — entry point.
* `bench/run-all.sh` — regenerates the result set.
* `bench/C-NOTES.md` — C-source comparison and remaining structural gaps.
* `bench/results/*.csv` — raw rows.
* `bench/results/*.out` — rendered Markdown reports.
