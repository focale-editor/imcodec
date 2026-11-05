# JBIG2 algorithm provenance

The arithmetic, Huffman, MMR, generic-region, refinement, symbol-dictionary and
halftone algorithms under `lib/src/codecs/jbig2` were adapted from
[insinfo/jbig2](https://github.com/insinfo/jbig2), revision
`d76c359e66c92781e8c258f3d633ee50fc8b94c5`. Its decoder derives from
[Apache PDFBox JBIG2 ImageIO](https://github.com/apache/pdfbox-jbig2).

Those adapted files retain the Apache-2.0 terms in `LICENSE` and the upstream
attribution in `NOTICE`. They are distributed alongside Imcodec's MIT code;
the root MIT license does not replace these third-party terms.

Imcodec supplies its own codec API, options, format and registry integration,
container parser, bounded byte/bit readers, allocation accounting, page
composition and single-page writer. The algorithms use private library parts,
named constructors, typed locals, documented members and Imcodec exceptions.
No `package:jbig2` dependency or file-backed Java-style stream layer is used.

The current encoder writes arithmetic generic regions (template 0 with optional
typical prediction). It does not write symbol dictionaries, Huffman regions,
halftones, stripes or multi-page files. These are decoder features where covered
by the fixtures; this integration does not claim complete T.88 conformance.
