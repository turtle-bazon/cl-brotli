# cl-brotli benchmark harness

Compares `cl-brotli` with the system C Brotli library through the existing
`cl-brotli-reference` CFFI bindings.

The harness measures three things for the same input:

* `cl-brotli:compress` / `cl-brotli:decompress` — the public pure-Lisp API.
* `BrotliEncoderCompress` / `BrotliDecoderDecompress` called directly with
  preallocated foreign buffers — C library cost without Lisp allocation or
  output copying.
* `cl-brotli.reference:compress` / `decompress` — the one-shot CFFI wrapper
  used by the test suite, including its allocation and output-copy overhead.

Every C stream is decoded by both decoders, and every pure stream is decoded
by both decoders, before it is timed. Throughput is MiB/s of uncompressed data.
`pure/C` speed > 1 means `cl-brotli` is faster; `pure/C` size > 1 means the
pure encoder produced a larger stream.

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
* `cl-brotli` has no quality, window, or mode parameter. Pure rows therefore
  use its automatic choices; C rows vary those parameters.

## Current results

Environment: Roswell SBCL 2.6.9, C Brotli 1.0.9, Intel Xeon Skylake (Linux
x86-64). Raw CSV files are in `bench/results/`.

### 1 MiB, C quality 11, lgwin 22, generic mode

| dataset | pure size | C q5 size | C q11 size | pure/C q5 | pure/C q11 | pure comp MiB/s | C q11 core comp MiB/s | pure dec MiB/s | C q11 core dec MiB/s | C q11 one-shot dec MiB/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| text | 12218 | 11568 | 9702 | 1.056 | 1.259 | 5.0 | 6.8 | 115.4 | 440.1 | 53.0 |
| html | 198383 | 193999 | 169361 | 1.023 | 1.171 | 0.6 | 0.3 | 15.6 | 298.4 | 70.3 |
| json | 57985 | 57439 | 47684 | 1.010 | 1.216 | 1.7 | 0.3 | 31.2 | 606.8 | 75.0 |
| source | 93132 | 91102 | 79992 | 1.022 | 1.164 | 1.4 | 0.6 | 25.6 | 336.9 | 65.2 |
| binary | 309582 | 283510 | 251377 | 1.092 | 1.232 | 1.2 | 0.2 | 8.9 | 150.0 | 46.9 |
| zeros | 13 | 13 | 14 | 1.000 | 0.929 | 11.9 | 17.9 | 961.5 | 370.0 | 23.4 |
| random | 1048581 | 1048581 | 1048581 | 1.000 | 1.000 | 20.3 | 0.9 | 330.3 | 4098.1 | 39.8 |
| periodic | 291 | 269 | 218 | 1.082 | 1.335 | 10.9 | 23.4 | 402.2 | 464.7 | 35.7 |
| pattern | 306 | 284 | 278 | 1.077 | 1.101 | 11.9 | 24.2 | 420.4 | 471.7 | 33.3 |
| dict | 57 | 47 | 31 | 1.213 | 1.839 | 10.9 | 23.4 | 486.8 | 502.0 | 30.0 |
| utf8 | 293 | 262 | 226 | 1.118 | 1.296 | 11.9 | 22.1 | 402.2 | 420.4 | 33.8 |

Geometric mean pure/C size ratio at q11: **1.201** excluding `periodic`
(1.213 including it). The pure encoder's ratio is roughly C quality
**q4–q5** on text-like data.

### Quality sweep summary (geometric mean across datasets, excluding `periodic`)

| C q | size (pure/C) | compress (pure/C core) | decompress (pure/C core) |
|---:|---:|---:|---:|
| 0 | 0.353 | 0.01x | 0.07x |
| 1 | 0.404 | 0.01x | 0.13x |
| 2 | 0.856 | 0.02x | 0.22x |
| 3 | 0.971 | 0.02x | 0.23x |
| 4 | 0.999 | 0.04x | 0.21x |
| 5 | 1.059 | 0.04x | 0.23x |
| 6 | 1.065 | 0.04x | 0.22x |
| 7 | 1.065 | 0.05x | 0.23x |
| 8 | 1.068 | 0.06x | 0.21x |
| 9 | 1.073 | 0.13x | 0.20x |
| 10 | 1.070 | 1.64x | 0.20x |
| 11 | 1.201 | 1.70x | 0.24x |

Pure compression is about **25× slower than C q4–q5**, but often faster than C
q11 on literal-heavy data because C q11 spends much more time parsing. Pure
decompression is about **4–5× slower than the C core** on typical data and
about **17–19× slower on literal-heavy binary/HTML/JSON**. The bit-reader and
Huffman-table changes improved pure decode throughput by roughly 1.5–3× over
the original implementation.

### Size boundary

The encoder now emits multiple compressed meta-blocks above 16 MiB and no
longer treats the 0..255 ramp as incompressible. The remaining 17 MiB penalty
is from independently compressing each chunk, so matches cannot cross the
chunk boundary:

| dataset | size | C q11 size | pure size | pure/C |
|---|---:|---:|---:|---:|
| text | 16 MiB | 9715 | 12218 | 1.26 |
| text | 17 MiB | 9728 | 24439 | 2.51 |
| source | 16 MiB | 80005 | 93133 | 1.16 |
| source | 17 MiB | 80018 | 186494 | 2.33 |
| periodic | 1 KiB | 216 | 289 | 1.34 |
| periodic | 1 MiB | 218 | 291 | 1.33 |
| periodic | 16 MiB | 232 | 291 | 1.25 |
| pattern | 16 MiB | 291 | 307 | 1.05 |
| pattern | 17 MiB | 304 | 611 | 2.01 |

### Window sweep

On 1 MiB text-like data, pure chooses an automatic window of 21 bits. C q11
needs a larger window to match it; at `lgwin` 10–14 C is much worse than pure:

| dataset | C q11 lgwin 14 | C q11 lgwin 16 | C q11 lgwin 22 | pure |
|---|---:|---:|---:|---:|
| text | 278610 | 9790 | 9702 | 12218 |
| html | 229097 | 185376 | 169361 | 198383 |
| source | 208249 | 195375 | 79992 | 93132 |
| binary | 268554 | 261544 | 251377 | 309582 |

C `mode` 0/1/2 made no meaningful difference at q11 on text/HTML/JSON.

## Implementation status

The benchmark was used to drive these changes:

* multi-meta-block encoding above 16 MiB, including a stream-wide distance ring;
* a 4-byte-repeat check in `incompressible-p` so periodic high-diversity data is
  compressed instead of stored;
* a word-level bit reader and a 10-bit Huffman lookup table in the decoder;
* implicit-distance command symbols and short distance-ring codes in the
  encoder;
* rejection of non-positive resolved distances;
* regression tests for the periodic ramp, multi-block input, and invalid
  distances.

Tests pass on Roswell SBCL 2.6.9 and CCL 1.13 (`70/70` checks). Benchmarks are
run only on SBCL 2.6.9.

## Files

* `bench/bench.lisp` — harness.
* `bench/run.lisp`, `bench/run.sh` — entry point.
* `bench/run-all.sh` — regenerates the result set.
* `bench/results/*.csv` — raw rows.
* `bench/results/*.out` — rendered Markdown reports.
