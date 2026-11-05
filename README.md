# cl-brotli

Common Lisp Brotli codec (RFC 7932), no FFI.

Version: `0.0.1.0`

License: GPL-3.0

## Features
- Full decoder: stream framing, meta-blocks, compressed blocks, Huffman
  codes, context maps, distance ring buffer, static dictionary, and word
  transforms
- Entropy-coded encoder: LZ77 + length-limited Huffman, with stored
  meta-block fallback, multi-meta-block support for inputs larger than
  16 MiB, and quality levels 0-11 (`:quality`, default 11)
- Standard Brotli streams, interoperable with the reference implementation
- Differential tests against the CFFI reference bindings
- Benchmark harness comparing ratio and throughput against the system C Brotli
  library at matching quality levels, across eleven dataset classes
  (see `bench/README.md`)

## Tests

```lisp
(asdf:test-system "cl-brotli")
```

The suite passes on Roswell SBCL 2.6.9 (150/150 checks). Benchmarks are run on
Roswell SBCL 2.6.9 via `bench/run.sh`.

## Usage
```lisp
(cl-brotli:compress "hello brotli")              ; => octets, quality 11
(cl-brotli:compress *data* :quality 5)           ; faster, lower ratio
(cl-brotli:decompress (cl-brotli:compress *data*))
```

`quality` ranges from 0 (fast greedy matching) to 11 (lazy matching, a
512-deep hash chain, and dictionary-assisted matches). The stored fallback is
still selected automatically when entropy coding would expand the input.

## Reusable compressor (GC-free steady state)

```lisp
(defvar *compressor* (cl-brotli:make-compressor))
(funcall *compressor* *data* :quality 11)           ; => octets, as compress
```

`make-compressor` returns a function with `compress`'s call shape that keeps a
private pool of the encoder's large working arrays, so steady-state
compression allocates almost nothing and triggers no GC. Plain `compress`
re-allocates ~72 bytes per input byte on every call (one GC per call at
quality 11 on 1 MiB). Output is byte-identical to `compress`.

### Threading

The library creates no threads, takes no locks, and uses no
implementation-specific primitives; all shared state is published as single
words or passed down as arguments.

- `compress` / `decompress` are stateless: any number of threads may call them
  concurrently.
- Each `make-compressor` closure owns its pool, bound dynamically only for the
  duration of a call (dynamic bindings are thread-local in every Common Lisp),
  so distinct compressors share nothing. Like a zlib stream or a
  `BrotliEncoderState`, one compressor must not be driven by two threads at
  once — use one per thread or per connection.
- The static dictionary index is built on first use and published as one word;
  concurrent first use is safe (racing builders each keep a self-consistent
  copy).

Memory note: quality 10/11 keeps ~72 bytes per input byte of working set
(~75 MB at 1 MiB, the same as C brotli), so budget roughly that per
concurrently-running compressor.

## Allocation-free API

```lisp
(cl-brotli:compress-into *data* *out* :quality 5) ; => end offset in *out*
(cl-brotli:decompress-into *stream* *out*)        ; => end offset in *out*
(cl-brotli:max-compressed-size (length *data*))  ; size *out* for compress-into
```

`compress-into` / `decompress-into` write into a caller-owned
`(simple-array (unsigned-byte 8) (*))` at `:start`, return the end offset, and
signal `cl-brotli:brotli-output-overflow` when the range is too small, so
long-lived buffers can be reused across calls. Results are byte-identical to
the one-shot API. Incompressible inputs (stored blocks) encode straight into
the caller's buffer with no temporary; on 1 MiB of `/dev/urandom` output,
`compress-into` halves time and conses nothing (one-shot: ~2 ms / 2 MB),
and `decompress-into` conses nothing (one-shot: ~1 MB of growth overshoot).
Entropy-coded inputs still use a bounded temporary for candidate selection.

## Reference bindings

`cl-brotli-reference` is a test-only system that wraps the system Brotli C
library through CFFI. It is used as an oracle for differential testing; the
`cl-brotli` system itself is Common Lisp.

## Attribution

The Lisp implementation is based on the MIT-licensed `brotli-pure` project by
ynniv, adapted and extended for this tree under GPL-3.0. The original MIT
notice is preserved in `NOTICE`.
