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
| 0-1 | fast-fragment, 15-bit hash, min match 5 | off | no |
| 2 | greedy chain depth 4 | off | no |
| 3 | greedy chain depth 8 | off | no |
| 4 | greedy chain depth 16 | off | no |
| 5 | lazy chain depth 32 | on | no |
| 6 | lazy chain depth 48 | on | no |
| 7 | lazy chain depth 64 | on | no |
| 8 | lazy chain depth 96 | on | no |
| 9 | lazy chain depth 128 | on | no |
| 10 | lazy chain depth 256 | on | text-like only |
| 11 | lazy chain depth 512 | on | text-like only |

The encoder is ratio-compliant: all levels stay within about 10% of C's
output except q11, which is 20% larger. q0/q1 use the C-style fast-fragment
path; q2-q9 use the chain/lazy parser. Speed-first variants that used stored
blocks or the fragment writer for q2-q9 reached 1.27-180x C size and were
reverted to respect the ratio limit.

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
| 0 | 1359.5 / 212.1 / 6.41x | 143.2 / 486.9 / 0.29x | 212.6 / 662.0 / 0.32x | 279.8 / 233.4 / 1.20x | 128.8 / 470.5 / 0.27x | 0.44x |
| 1 | 1349.1 / 1866.4 / 0.72x | 142.1 / 332.1 / 0.43x | 211.9 / 395.1 / 0.54x | 280.5 / 294.9 / 0.95x | 128.7 / 326.9 / 0.39x | 0.34x |
| 2 | 625.6 / 1079.6 / 0.58x | 68.8 / 182.8 / 0.38x | 87.8 / 278.5 / 0.32x | 143.7 / 350.1 / 0.41x | 56.0 / 188.0 / 0.30x | 0.62x |
| 3 | 587.5 / 1010.2 / 0.58x | 69.4 / 154.5 / 0.45x | 81.9 / 215.8 / 0.38x | 137.7 / 296.8 / 0.46x | 53.8 / 147.9 / 0.36x | 0.67x |
| 4 | 597.8 / 831.1 / 0.72x | 65.3 / 131.7 / 0.50x | 72.1 / 150.2 / 0.48x | 124.9 / 223.0 / 0.56x | 49.5 / 99.7 / 0.50x | 0.77x |
| 5 | 362.4 / 638.2 / 0.57x | 27.8 / 67.2 / 0.41x | 27.4 / 67.2 / 0.41x | 52.3 / 120.8 / 0.43x | 25.7 / 52.2 / 0.49x | 0.76x |
| 6 | 357.8 / 625.1 / 0.57x | 23.5 / 63.9 / 0.37x | 23.3 / 57.3 / 0.41x | 48.2 / 110.1 / 0.44x | 22.3 / 48.2 / 0.46x | 0.75x |
| 7 | 353.1 / 304.2 / 1.16x | 20.4 / 44.1 / 0.46x | 20.6 / 42.9 / 0.48x | 42.2 / 87.8 / 0.48x | 20.1 / 38.2 / 0.53x | 0.86x |
| 8 | 342.4 / 590.5 / 0.58x | 17.0 / 36.4 / 0.47x | 17.1 / 35.1 / 0.49x | 37.6 / 76.4 / 0.49x | 18.4 / 31.4 / 0.59x | 0.86x |
| 9 | 340.7 / 168.4 / 2.02x | 14.0 / 23.6 / 0.59x | 14.4 / 22.3 / 0.64x | 34.3 / 49.1 / 0.70x | 16.6 / 22.1 / 0.75x | 2.00x |

The encoder is back to a ratio-compliant configuration under the 10%
size cap. q0/q1 use the fast-fragment path (15-bit hash, 5-byte minimum
match); q2-q9 use the chain/lazy parser; q10/q11 keep the lazy chain plus
dictionary. q9/q10/q11 beat C on speed (2.00x/19.23x/16.83x) at 1.064x/
1.075x/1.201x C size; q0-q8 are 0.34-0.86x and remain codegen-bound. The
speed-first stored/fast-fragment variants reached 1.27-180x C size and were
reverted to respect the 10% ratio limit.

### q0/q1 decompression

Each cell is `lisp MiB/s / C MiB/s / lisp/C`; the geomean column covers
all **eleven** datasets.

| q | text | html | json | source | binary | geomean |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1210.9 / 2718.2 / 0.45x | 189.1 / 561.6 / 0.34x | 239.9 / 762.4 / 0.31x | 181.0 / 483.1 / 0.37x | 162.7 / 402.4 / 0.40x | 0.43x |
| 1 | 739.8 / 1729.1 / 0.43x | 167.0 / 564.7 / 0.30x | 186.7 / 639.4 / 0.29x | 164.5 / 517.3 / 0.32x | 164.9 / 403.4 / 0.41x | 0.42x |

q0/q1 decode is now 0.43x/0.42x across all eleven datasets (the aggregate
moves with C's timing on the easy corpora). A direct 704-entry command LUT
removes the per-command cell/sub-code arithmetic; the copy entry points are
typed and inlined; READ-HUFF consumes bits directly instead of calling RBITS
to discard them; and the primary-table mask is precomputed in the HUFF
object. The single-literal-block test is hoisted out of the literal loops
because C q0/q1 streams and the common q5-q11 context streams use one
literal block type. The Huffman tables now use 16-bit entries
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
| 10 | 1.075 | 19.23x | 1.74x |
| 11 | 1.201 | 16.83x | 1.73x |

q10/q11 are included for completeness. They are not representative of the
low-level behavior: the encoder spends much more time parsing, which is where
C q11 is slow, while C q0-q9 are much faster than the lisp encoder.

### Quality sweep summary (geometric mean across all 11 datasets, level-matched)

| C q | size (lisp/C) | compress (lisp/C core) | decompress (lisp/C core) |
|---:|---:|---:|---:|
| 0 | 0.532 | 0.44x | 0.43x |
| 1 | 0.615 | 0.34x | 0.42x |
| 2 | 0.954 | 0.62x | 1.62x |
| 3 | 1.055 | 0.67x | 1.84x |
| 4 | 1.076 | 0.77x | 1.63x |
| 5 | 1.057 | 0.76x | 1.61x |
| 6 | 1.060 | 0.75x | 1.59x |
| 7 | 1.059 | 0.86x | 1.73x |
| 8 | 1.059 | 0.86x | 1.73x |
| 9 | 1.064 | 2.00x | 1.70x |
| 10 | 1.075 | 19.23x | 1.74x |
| 11 | 1.201 | 16.83x | 1.73x |
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
cl-brotli's q11 geomeans against C Brotli on the same host are 16.83x
compression and 1.73x decompression in this run. The decompression geomean is
inflated by the easy synthetic corpora: literal-heavy HTML/JSON/source/binary
decode is 0.30-0.42x of C. q11 is not the useful comparison for the low-level
work: C q11 is deliberately slow. Under the speed-first policy, q2-q9 use the
fast-fragment path and beat C q2-q9 on throughput (1.16-6.73x) while
producing 1.27-1.56x C's size. q0/q1 still trade with C q0/q1: 6.62x faster
on text, 1.22x on source, but 0.28-0.32x on literal-heavy
HTML/JSON/binary. The cl-newzlib comparison is still useful evidence that
portable Lisp can reach C parity, but it applies to the low-level constant
factors (per-symbol decode, bit emission, match extension), not to the q11
headline.

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
* hoist the `single-lblock` test out of the decoder's literal loops. C q0/q1
  streams have one literal block, and the common q5-q11 context streams also
  have one literal block type, so the per-literal block-switch branch was
  pure overhead. q11 decode HTML 263->284 MiB/s, JSON 234->248, TEXT
  1265->1333; the q2/q11 decoder microbenchmarks gain 8-15%;
* inline the fragment matcher's two match-extension sites with two
  single-expansion copies of `%MATCH-LEN-SAP`. Inlining the same function at
  both sites previously miscompiled (`cv` unbound), which forced a non-inlined
  wrapper call per match. q0 TEXT 1218->1298 MiB/s, HTML 118->135, JSON
  176->204, SOURCE 253->274, BINARY 119->125; q0 geomean 0.43->0.48, q0
  source now 1.20x C;
* batch writer capacity checks: keep a local 64 KiB slack counter and call
  `W-ENSURE` only when the current command's upper bound would exceed it,
  instead of once per command. q0/q1 use 32 bytes of command overhead, the
  generic writer 24. q0 HTML 135->146 MiB/s, JSON 200->210, SOURCE 274->282,
  BINARY 125->129; q1 HTML 129->139, JSON 194->201, SOURCE 264->272; output
  sizes are unchanged;
* seed the chain matcher with the previous match distance before walking the
  chain, as C's distance cache does. A hit raises `best-len`, which makes the
  4-byte probe reject more candidates, and the chosen distance improves the
  next parse. Sizes shrink (BINARY q2 345482->341166, q5 298766->295846,
  SOURCE q2 115830->115640) at neutral speed; q11 compression reaches
  16.59x;
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
* Low-level encoder throughput: within the 10% size cap, q0 0.44x,
  q1 0.34x, q2 0.62x, q3 0.67x, q4 0.77x, q5 0.76x, q6 0.75x, q7 0.86x,
  q8 0.86x, and **q9 2.00x**; q10/q11 are 19.23x/16.83x. q9/q10/q11 beat C;
  q0-q8 remain codegen-bound. q0-q10 output is 0.53-1.08x C (q11 is 1.20x).
  The speed-first stored/fast-fragment variants were faster but produced
  1.27-180x C size, so they were reverted.
* q0/q1 decode is 0.43x/0.42x across all eleven datasets (C timing varies
  between runs). Literal-heavy HTML/JSON/source/binary is 0.30-0.42x. The
  decoder hoists the single command/distance tree pointers out of the command
  loop, which removed two per-command lookups. A 704-entry command LUT, typed/inlined copy path,
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
