# cl-brotli

Common Lisp Brotli codec (RFC 7932), no FFI.

Version: `0.0.1.0`

License: GPL-3.0

## Features
- Full decoder: stream framing, meta-blocks, compressed blocks, Huffman
  codes, context maps, distance ring buffer, static dictionary, and word
  transforms
- Entropy-coded encoder: LZ77 + length-limited Huffman, with stored
  meta-block fallback and multi-meta-block support for inputs larger than
  16 MiB
- Standard Brotli streams, interoperable with the reference implementation
- Differential tests against the CFFI reference bindings
- Benchmark harness comparing ratio and throughput against the system C Brotli
  library (see `bench/README.md`)

## Tests

```lisp
(asdf:test-system "cl-brotli")
```

The suite passes on Roswell SBCL 2.6.9 and CCL 1.13. Benchmarks are run on
Roswell SBCL 2.6.9 via `bench/run.sh`.

## Usage
```lisp
(cl-brotli:compress "hello brotli")   ; => octets
(cl-brotli:decompress *data*)         ; => octets
```

## Reference bindings

`cl-brotli-reference` is a test-only system that wraps the system Brotli C
library through CFFI. It is used as an oracle for differential testing; the
`cl-brotli` system itself is Common Lisp.

## Attribution

The Lisp implementation is based on the MIT-licensed `brotli-pure` project by
ynniv, adapted and extended for this tree under GPL-3.0. The original MIT
notice is preserved in `NOTICE`.
