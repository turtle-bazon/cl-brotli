# cl-brotli

Pure Common Lisp Brotli codec (RFC 7932), no FFI.

Version: `0.0.1.0`

License: GPL-3.0

## Features
- Full decoder: stream framing, meta-blocks, compressed blocks, Huffman
  codes, context maps, distance ring buffer, static dictionary, and word
  transforms
- Entropy-coded encoder: LZ77 + length-limited Huffman, with stored
  meta-block fallback
- Standard Brotli streams, interoperable with the reference implementation
- Differential tests against the CFFI reference bindings

## Usage
```lisp
(cl-brotli:compress "hello brotli")   ; => octets
(cl-brotli:decompress *data*)         ; => octets
```

## Reference bindings

`cl-brotli-reference` is a test-only system that wraps the system Brotli C
library through CFFI. It is used as an oracle for differential testing; the
`cl-brotli` system itself is pure Common Lisp.

## Attribution

The pure implementation is based on the MIT-licensed `brotli-pure` project by
ynniv, adapted and extended for this tree under GPL-3.0. The original MIT
notice is preserved in `NOTICE`.
