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

The full `run-all.sh` matrix takes roughly 60–90 minutes on the machine used
here (C q11 on 17 MiB random data is the slowest case). It prints each dataset
to stderr as it starts; run individual sweeps if you need shorter feedback.

## Datasets

| name | source |
|---|---|
| `text` | `/usr/share/common-licenses/GPL-3`, tiled/truncated |
| `html` | `/usr/share/doc/rclone/MANUAL.html`, tiled/truncated |
| `json` | GHC `doc-index.json` if present, otherwise generated JSON records |
| `source` | `cl-newzlib/src/*.lisp` + `pesekey/pesekey/src/*.lisp` (stable external corpus) |
| `binary` | first bytes of Roswell SBCL 2.6.9, then `/usr/local/bin/sbcl`/bash |
| `zeros` | generated zeroes |
| `random` | generated xorshift32 bytes |
| `periodic` | 0..255 ramp repeated |
| `pattern` | 256-byte pseudo-random pattern repeated |
| `dict` | `tests/vectors/dict.raw`, tiled |
| `utf8` | multilingual UTF-8 sample, tiled |

For sizes larger than the source file, the dataset is tiled. This is why some
ratios are stable across 1 MiB, 4 MiB, and 16 MiB.

## Methodology

* Warm-up call, then median of 3 samples (quality sweep), 2 samples (window and
  mode sweeps), or 1 sample (large-size sweep), with a full GC before each
  sample.
* Each sample runs the operation repeatedly to reach `--target` seconds, with a
  cap of 1000 repetitions.
* C-core compression uses `BrotliEncoderMaxCompressedSize` output capacity;
  C-core decompression uses an output buffer of exactly the known uncompressed
  size.
* The C one-shot wrapper's decompressor doubles its output buffer from
  `4 * encoded-size`, so highly compressed streams can pay for several full C
  decodes. The C-core column is the fair library-only number; the one-shot
  column is what the existing test helper actually costs.
* `cl-brotli` has no quality, window, or mode parameter. Lisp rows therefore
  use its automatic choices; C rows vary those parameters.

## Current results

Environment: Roswell SBCL 2.6.9, C Brotli 1.0.9, Intel Xeon Skylake (Linux
x86-64). Raw CSV files are in `bench/results/`.

### 1 MiB, C quality 11, lgwin 22, generic mode

| dataset | lisp size | C q5 size | C q11 size | lisp/C q5 | lisp/C q11 | lisp comp MiB/s | C q11 core comp MiB/s | lisp dec MiB/s | C q11 core dec MiB/s | C q11 one-shot dec MiB/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| text | 11686 | 11568 | 9702 | 1.010 | 1.204 | 3.3 | 6.1 | 105.3 | 419.4 | 55.6 |
| html | 192903 | 193999 | 169361 | 0.994 | 1.139 | 0.3 | 0.3 | 10.4 | 260.4 | 60.0 |
| json | 57083 | 57439 | 47684 | 0.994 | 1.197 | 1.0 | 0.3 | 28.6 | 568.2 | 83.3 |
| source | 90741 | 91102 | 79992 | 0.996 | 1.134 | 0.8 | 0.6 | 20.8 | 300.0 | 66.7 |
| binary | 296645 | 283510 | 251377 | 1.046 | 1.180 | 1.0 | 0.2 | 6.4 | 160.2 | 41.7 |
| zeros | 13 | 13 | 14 | 1.000 | 0.929 | 10.0 | 15.6 | 428.5 | 457.8 | 25.0 |
| random | 1048581 | 1048581 | 1048581 | 1.000 | 1.000 | 19.2 | 0.8 | 223.2 | 4385.7 | 43.5 |
| periodic | 291 | 269 | 218 | 1.082 | 1.335 | 8.6 | 26.3 | 769.2 | 461.5 | 31.2 |
| pattern | 306 | 284 | 278 | 1.077 | 1.101 | 10.9 | 21.7 | 240.4 | 375.0 | 32.6 |
| dict | 57 | 47 | 31 | 1.213 | 1.839 | 7.6 | 21.7 | 954.1 | 390.6 | 35.7 |
| utf8 | 293 | 262 | 226 | 1.118 | 1.296 | 10.0 | 21.7 | 231.5 | 450.4 | 30.3 |

Geometric mean lisp/C size ratio at q11: **1.183** excluding `periodic`
(1.196 including it). The lisp encoder is now at or slightly better than C
q5 on text-like data, with a ~13–20% gap to q11.

### Quality sweep summary (geometric mean across datasets, excluding `periodic`)

| C q | size (lisp/C) | compress (lisp/C core) | decompress (lisp/C core) |
|---:|---:|---:|---:|
| 0 | 0.366 | 0.01x | 0.07x |
| 1 | 0.415 | 0.00x | 0.14x |
| 2 | 0.855 | 0.01x | 0.24x |
| 3 | 0.963 | 0.02x | 0.24x |
| 4 | 0.988 | 0.03x | 0.21x |
| 5 | 1.046 | 0.03x | 0.25x |
| 6 | 1.051 | 0.03x | 0.25x |
| 7 | 1.051 | 0.04x | 0.29x |
| 8 | 1.054 | 0.04x | 0.25x |
| 9 | 1.059 | 0.10x | 0.28x |
| 10 | 1.070 | 1.14x | 0.21x |
| 11 | 1.196 | 1.16x | 0.23x |

Lisp compression is about **25× slower than C q4–q5**, but often faster than C
q11 on literal-heavy data because C q11 spends much more time parsing. Lisp
decompression is about **4–5× slower than the C core** on typical data and
about **15–25× slower on literal-heavy binary/HTML/JSON**. The bit-reader and
Huffman-table changes improved lisp decode throughput by roughly 1.5–3× over
the original implementation.

### Size boundary

The encoder now emits multiple compressed meta-blocks above 16 MiB and no
longer treats the 0..255 ramp as incompressible. The remaining 17 MiB penalty
is from independently compressing each chunk, so matches cannot cross the
chunk boundary:

| dataset | size | C q11 size | lisp size | lisp/C |
|---|---:|---:|---:|---:|
| text | 16 MiB | 9715 | 11686 | 1.20 |
| text | 17 MiB | 9728 | 11699 | 1.20 |
| source | 16 MiB | 80005 | 90741 | 1.13 |
| source | 17 MiB | 80018 | 90754 | 1.13 |
| periodic | 1 KiB | 216 | 289 | 1.34 |
| periodic | 1 MiB | 218 | 291 | 1.33 |
| periodic | 16 MiB | 232 | 291 | 1.25 |
| periodic | 17 MiB | 244 | 303 | 1.24 |
| pattern | 16 MiB | 291 | 307 | 1.05 |
| pattern | 17 MiB | 304 | 319 | 1.05 |

### Window sweep

On 1 MiB text-like data, lisp chooses an automatic window of 21 bits. C q11
needs a larger window to match it; at `lgwin` 10–14 C is much worse than lisp:

| dataset | C q11 lgwin 14 | C q11 lgwin 16 | C q11 lgwin 22 | lisp |
|---|---:|---:|---:|---:|
| text | 278610 | 9790 | 9702 | 11686 |
| html | 229097 | 185376 | 169361 | 192903 |
| source | 208249 | 195375 | 79992 | 90741 |
| binary | 268554 | 261544 | 251377 | 296645 |

C `mode` 0/1/2 made no meaningful difference at q11 on text/HTML/JSON.

## Implementation status

The benchmark was used to drive these changes:

* multi-meta-block encoding above 16 MiB, with one whole-input LZ77 pass and
  commands partitioned at meta-block boundaries so matches cross the boundary;
* a stream-wide distance ring shared by all meta-blocks;
* a 4-byte-repeat check in `incompressible-p` so periodic high-diversity data is
  compressed instead of stored;
* a word-level bit reader and a two-level Huffman decoder (10-bit primary,
  32-entry secondary tables for long codes);
* fast single-tree literal and distance decode paths;
* unlimited dictionary matching for text-like data;
* length-preserving dictionary transforms (identity, upper-first, upper-all);
* one-step lazy matching in the LZ77 parser;
* implicit-distance command symbols and short distance-ring codes in the
  encoder;
* implementation tree and package renamed from `pure` to `lisp`;
* rejection of non-positive resolved distances;
* regression tests for the periodic ramp, multi-block input, and invalid
  distances.

A SIMD match-extender was evaluated through `sb-simd` and `sb-cpu-features`:
AVX2/SSE4.1 gave roughly 10% on HTML/JSON but regressed the source corpus, so it
was not retained. The portable scalar match finder remains the default.

Tests pass on Roswell SBCL 2.6.9 and CCL 1.13 (`70/70` checks). Benchmarks are
run only on SBCL 2.6.9.

## Remaining gaps

* Encoder ratio is at C q5 on text-like data; closing the q11 gap needs
  context modeling, block splitting, and length-changing dictionary transforms.
* Lisp decoding is still ~15–25× slower than the C core on literal-heavy
  binary/HTML/JSON; highly compressible streams are near parity or faster.
* C q11 on 17 MiB random data remains the slowest benchmark case (~0.6 MiB/s).

## Files

* `bench/bench.lisp` — harness.
* `bench/run.lisp`, `bench/run.sh` — entry point.
* `bench/run-all.sh` — regenerates the result set.
* `bench/results/*.csv` — raw rows.
* `bench/results/*.out` — rendered Markdown reports.
