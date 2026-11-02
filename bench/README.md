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
| 0 | 1272.1 / 207.8 / 6.12x | 127.0 / 486.7 / 0.26x | 184.0 / 653.9 / 0.28x | 260.9 / 234.2 / 1.11x | 118.1 / 457.8 / 0.26x | 0.42x |
| 1 | 1149.8 / 1882.6 / 0.61x | 124.6 / 331.9 / 0.38x | 180.2 / 388.3 / 0.46x | 251.5 / 298.1 / 0.84x | 110.8 / 322.6 / 0.34x | 0.31x |
| 2 | 605.9 / 1071.7 / 0.57x | 71.5 / 173.6 / 0.41x | 89.2 / 266.3 / 0.34x | 148.4 / 345.3 / 0.43x | 55.9 / 180.7 / 0.31x | 0.64x |
| 3 | 575.3 / 1003.1 / 0.57x | 72.2 / 151.4 / 0.48x | 80.6 / 199.3 / 0.40x | 142.5 / 294.2 / 0.48x | 53.9 / 143.9 / 0.37x | 0.70x |
| 4 | 576.6 / 831.4 / 0.69x | 62.5 / 129.5 / 0.48x | 71.0 / 153.4 / 0.46x | 126.8 / 236.7 / 0.54x | 48.7 / 90.5 / 0.54x | 0.79x |
| 5 | 382.1 / 646.2 / 0.59x | 27.8 / 63.3 / 0.44x | 27.3 / 65.8 / 0.42x | 52.8 / 120.5 / 0.44x | 26.7 / 51.3 / 0.52x | 0.79x |
| 6 | 387.3 / 639.2 / 0.61x | 23.3 / 62.9 / 0.37x | 23.1 / 51.0 / 0.45x | 48.0 / 109.6 / 0.44x | 22.3 / 46.6 / 0.48x | 0.78x |
| 7 | 366.9 / 309.1 / 1.19x | 20.7 / 44.9 / 0.46x | 20.4 / 40.8 / 0.50x | 43.8 / 88.4 / 0.50x | 21.3 / 38.1 / 0.56x | 0.88x |
| 8 | 353.2 / 578.1 / 0.61x | 16.7 / 36.1 / 0.46x | 17.0 / 33.6 / 0.51x | 37.7 / 74.9 / 0.50x | 18.7 / 31.3 / 0.60x | 0.86x |
| 9 | 361.4 / 173.8 / 2.08x | 14.0 / 23.8 / 0.59x | 14.5 / 22.5 / 0.65x | 34.2 / 48.1 / 0.71x | 17.0 / 22.4 / 0.76x | 2.04x |

The chain/fast-fragment work, the 64 KiB output buffer, the fast
`incompressible-p` check, the stored-block fast path, and the q0/q1 writer
changes (short-run literal inlining plus an inlined histogram update) changed
all levels. q0 is 6.12x faster than C on text and **1.11x on source**
(faster), but 0.26-0.28x on literal-heavy HTML/JSON/binary. q1 is 0.31x
(0.61x text, 0.84x source), q2-q4 are 0.64-0.79x, q5-q8 are 0.78-0.88x,
and **q9 is 2.04x** (text 2.08x, binary 0.76x); q10 is 19.01x and q11 is
16.23x. q7/q9/q10/q11 beat C on text, and q9/q0-source beat it overall.
`incompressible-p` samples every 4th 4-gram into a 2^19-bit hashed set and
uses an inlined/typed `dict-key4`; the stored fallback preallocates and
copies directly from the input. q0/q1 fuse the histogram pass into the
matcher and use a flat 32-bit command vector; the chain matcher uses
32-bit head/prev tables, skips the prev fill, applies C's short-distance
StoreRange tail, and probes 4 bytes at best-len.

### q0/q1 decompression

Each cell is `lisp MiB/s / C MiB/s / lisp/C`; the geomean column covers
all **eleven** datasets.

| q | text | html | json | source | binary | geomean |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1218.2 / 2674.9 / 0.46x | 192.8 / 562.7 / 0.34x | 249.7 / 753.0 / 0.33x | 187.8 / 489.4 / 0.38x | 164.4 / 395.4 / 0.42x | 0.44x |
| 1 | 682.3 / 1701.1 / 0.40x | 170.4 / 565.4 / 0.30x | 192.5 / 630.0 / 0.31x | 169.1 / 526.4 / 0.32x | 166.1 / 393.7 / 0.42x | 0.54x |

q0/q1 decode is now 0.44x/0.54x across all eleven datasets (the aggregate
moves with C's timing on the easy corpora). A direct 704-entry command LUT
removes the per-command cell/sub-code arithmetic; the copy entry points are
typed and inlined; READ-HUFF consumes bits directly instead of calling RBITS
to discard them; and the primary-table mask is precomputed in the HUFF
object. The Huffman tables now use 16-bit entries
(2 KiB per 10-bit primary table instead of 8 KiB), keep code lengths in an
octet vector, and build the sorted symbol permutation only if the
end-of-stream slow path runs; bit reversal uses a 256-byte lookup table.
Stored meta-blocks copy straight into the output buffer. Text is 0.45x/0.42x;
literal-heavy HTML/JSON/source/binary is 0.30-0.42x. The all-dataset geomeans
for q2 and above are above parity because the synthetic easy datasets decode
much faster than C, not because literal-heavy decode has caught up. A
register-resident bulk literal decoder was measured and reverted (5-7% slower
in SBCL); the remaining gap is per-literal Huffman decode.

### Higher levels

| q | size (lisp/C) | compression (lisp/C) | decompression (lisp/C) |
|---:|---:|---:|---:|
| 10 | 1.075 | 19.01x | 1.75x |
| 11 | 1.202 | 16.23x | 1.81x |

q10/q11 are included for completeness. They are not representative of the
low-level behavior: the encoder spends much more time parsing, which is where
C q11 is slow, while C q0-q9 are much faster than the lisp encoder.

### Quality sweep summary (geometric mean across all 11 datasets, level-matched)

| C q | size (lisp/C) | compress (lisp/C core) | decompress (lisp/C core) |
|---:|---:|---:|---:|
| 0 | 0.532 | 0.42x | 0.44x |
| 1 | 0.611 | 0.31x | 0.54x |
| 2 | 0.956 | 0.64x | 1.76x |
| 3 | 1.057 | 0.70x | 2.00x |
| 4 | 1.077 | 0.79x | 1.71x |
| 5 | 1.058 | 0.79x | 1.64x |
| 6 | 1.061 | 0.78x | 1.69x |
| 7 | 1.060 | 0.88x | 1.74x |
| 8 | 1.060 | 0.86x | 1.74x |
| 9 | 1.064 | 2.04x | 1.75x |
| 10 | 1.075 | 19.01x | 1.75x |
| 11 | 1.202 | 16.23x | 1.81x |
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
| source | 16 MiB | 79646 | 89839 | 1.128 |
| source | 17 MiB | 79658 | 89851 | 1.128 |
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
| source | 208782 | 195792 | 79632 | 79632 | 89839 |
| binary | 268554 | 261544 | 251377 | 251377 | 296122 |

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
cl-brotli's q11 geomeans against C Brotli on the same host are 16.23x
compression and 1.81x decompression in this run. The decompression geomean is
inflated by the easy synthetic corpora: literal-heavy HTML/JSON/source/binary
decode is 0.30-0.42x of C. q11 is not the useful comparison for the low-level
work: C q11 is deliberately slow, while C q0-q9 are still 1.1-5x faster on
the literal-heavy cells (cl-brotli is 6.05x faster on q0 text). The
cl-newzlib comparison is still useful evidence that portable Lisp can reach C
parity, but it applies to the low-level constant factors (per-symbol decode,
bit emission, match extension), not to the q11 headline.

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
* inlined `%LZ77`'s hash/insert/match-length helpers and added C's 4-byte
  best-len probe before extending a candidate, so most chain candidates are
  rejected with one 32-bit compare; q5-q9 gained another 25-45% (HTML q5
  18.4 -> 25.5 MiB/s, q9 8.7 -> 12.0) with unchanged ratio;
* 32-bit `head`/`prev` chain tables with no `prev` fill (only inserted
  positions are read), plus C's `StoreRange` short-distance tail rule; this
  lifted text q5-q9 from ~110 to 330-370 MiB/s and made q9 1.46x C overall;
* a flat 32-bit command vector for the q0/q1 fast-fragment writer, shared by
  the histogram and emission passes instead of a five-element list per
  command; this lifted q0 HTML 100->121, JSON 162->181, source 202->239,
  and made q0 source faster than C;
* a 64 KiB initial output buffer instead of preallocating n+1 KiB; for
  highly compressible 1 MiB inputs the compressed result is small, so the
  old 1 MiB allocation/zeroing dominated. This lifted the level-matched
  geomeans: q2 0.42->0.55, q5 0.54->0.66, q7 0.60->0.74, q9 1.47->1.74,
  q10 9.44->10.85, q11 8.29->9.25;
* replaced `incompressible-p`'s EQL hash table with a 2^21-bit hashed set and
  typed/inlined `dict-key4`; the PERIODIC/RANDOM check dropped from
  0.6-1.1 ms to ~0.13 ms, lifting q0 0.35->0.39, q1 0.24->0.31,
  q7 0.74->0.81, q9 1.74->1.85, q11 9.25->10.32;
* preallocate the stored-block writer and copy directly from the input with
  `w-bytes-range` instead of `subseq` + `replace`; RANDOM rises 503->950
  MiB/s and lifts q0 0.39->0.42, q2 0.57->0.63, q5 0.70->0.76,
  q7 0.81->0.87, q9 1.85->1.98, q11 10.32->11.01;
* sample `incompressible-p`'s 4-gram test every 4th position into a
  2^19-bit set (64 KiB instead of 256 KiB), and stop zero-filling the
  plan-commands record array (every slot is written); PERIODIC/RANDOM checks
  drop to 0.076/0.081 ms and q9 reaches 2.04x, q11 11.39x;
* shrink the decoder's Huffman representation: 16-bit primary/subtable
  entries (2 KiB instead of 8 KiB per 10-bit table), octet code-length
  arrays, lazy length-sorted symbol permutations, and a 256-byte bit-reversal
  table; stored meta-blocks copy directly into the output buffer. BINARY
  q11 decompression consing drops 3.35->1.56 MB per MiB, and level-matched
  decompression geomeans rise q2 1.43->1.75, q5 1.48->1.62, q11 1.64->1.81
  (the all-eleven geomean is noisy; see the per-dataset ratios);
* grow large decoder output buffers by 1.5x instead of 4x, reserve the last
  compressed block and large stored blocks exactly, and have the multi-block
  encoder mark its final data block ISLAST instead of appending an empty
  block. A 17 MiB decode now allocates 34 MB instead of 101 MB (text and
  incompressible random); 1 MiB results are unchanged;
* compare dictionary candidates byte-by-byte (with the UTF-8 case transforms
  applied on the fly) instead of allocating `subseq`/`apply-transform`
  temporaries for every candidate and transform; q11-encoder allocation for
  HTML drops 48.7->27.1 MB and SOURCE 40.7->21.4 MB per call, while output
  sizes are bit-identical. q10/q11 compression geomeans rise to 14.92x/12.46x;
* run only the dictionary parse at q10/q11, and fall back to comparing with
  the plain parse only when the dictionary result is under 4 KiB (where a
  tiled dictionary test vector can still win with the plain parse). This
  halves q10/q11 work on normal text: q11 TEXT 144->244 MiB/s, HTML 2.8->5.5,
  JSON 2.8->5.5, SOURCE 9.8->18.9, and q11 allocation HTML 27.1->13.6 MB,
  SOURCE 21.4->10.7 MB, TEXT 11.5->5.7 MB. Benchmark output sizes are
  unchanged. q10/q11 compression geomeans are now 19.07x/16.38x;
* inline literal runs shorter than 8 in the q0/q1 fast writer instead of
  calling `W-EMIT-RUN` for every insert; most q0 commands insert only 1-7
  bytes. Median q0/q1 throughput rises ~2% across all five corpora; the
  level-matched q0 geomean moves 0.42->0.45 in one run and is noise-limited
  in the 0.42-0.45 range;
* declare `NOTE-FAST-COMMAND` inline: the fragment matcher calls it once per
  command to update the histograms, and the call boundary was visible. q0
  HTML 123->127 MiB/s, JSON 175->184, SOURCE 251->261; q1 HTML 122->125,
  JSON 172->180, SOURCE 244->252. Text and binary are unchanged;
* fused the q0/q1 literal/command/distance histograms into the fragment
  matcher, so the fast writer makes a single pass over the command vector;
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
* typed the hot decoder scalars, typed and inlined the copy entry points,
  removed a redundant distance check, specialized the NPOSTFIX=0 distance
  path, and replaced the RFC cell/sub-code arithmetic with a direct 704-entry
  insert/copy LUT; this improved q0/q1 decode by ~70-80%;
* made READ-HUFF consume bits directly (no RBITS refill/unused mask) and
  precomputed the primary-table mask in the HUFF object; another ~10% on
  q0/q1 decode;
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
* Low-level encoder throughput: q0 is 0.42x, q1 0.31x, q2-q4 0.64-0.79x,
  q5-q8 0.78-0.88x, and **q9 2.04x**. q9/q10/q11 beat C on text (q9 2.08x,
  q10 19.01x, q11 16.23x), q7 is 1.19x on text in this run (C q7 timing is
  noisy), **q0 source beats C (1.11x)**, and q9 beats it overall. q0 is
  6.12x faster than C q0 on text but 0.26-0.28x on literal-heavy
  HTML/JSON/binary. q0 output is 0.35-0.99x the size of C q0. The remaining
  literal-heavy gap is mainly SBCL codegen versus the hand-written C emitter
  plus C's block splitting/command-code adaptation.
* q0/q1 decode is 0.36x/0.56x across all eleven datasets (C timing varies
  between runs). Text is 0.42x/0.44x; literal-heavy HTML/JSON/source/binary
  is 0.30-0.41x. A 704-entry command LUT, typed/inlined copy path,
  NPOSTFIX=0 distance path, direct bit consumption, and a precomputed
  primary-table mask gave ~90% over the older decoder. Fast per-literal
  Huffman decode is the remaining gap.
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
