# musset-typeset

Musset's typesetter: the one place a Musset book (Markdown chapters and `Musset/Resources/Typst/musset.typ`)
becomes pages, with the [Typst](https://typst.app) library (Apache-2.0). Read mode, the iOS reader and the PDF
export all go through it, so they break pages in the same places.

For reading, each page gives a bitmap at any scale and a text map: every glyph's box, and the UTF-16 range of the
chapter's Markdown it shows. Marks, selection and anchors that survive reflow are built on that map. For the export,
the same pages are written as a PDF (`typst-pdf`), without the maps.

- `src/markup.rs`: Markdown → Typst, with a map from each byte of markup back to the Markdown.
- `src/document.rs`: the whole book (the style's call, the special pages, the parts, the chapters), and the JSON
  description (`Spec`) the C ABI takes.
- `src/engine.rs`: the Typst world, composition, the text map, rendering, the PDF.
- `src/ffi.rs`, `include/`: the C ABI and its module map (`MussetTypeset`).

Build the XCFramework used by `Packages/MussetPage` with `scripts/build-typeset.sh` (macOS arm64 + x86_64,
iOS device, iOS simulator arm64 + x86_64). `cargo test --release` runs the engine's own tests; the fixture test
skips itself when `fixtures/` is absent.
