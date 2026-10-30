# cl-brotli

Common Lisp bindings and convenience API for Brotli compression.

Version: `0.0.1.0`

License: GPL-3.0

## Features
- One-shot `compress` and `decompress`
- Direct CFFI bindings to `libbrotlienc` and `libbrotlidec`
- Round-trip tested for empty, small, and large inputs

## Usage
```lisp
(cl-brotli:compress "hello brotli")
(cl-brotli:decompress *data*)
```

## Notes
This subproject currently wraps the system Brotli C implementation for
correctness and performance. A future extraction may replace or extend
the binding layer.
