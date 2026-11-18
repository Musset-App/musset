//! Musset's reading engine: a Musset book (Markdown chapters and the `musset.typ` template) composed by the Typst
//! library into pages, each with a bitmap at any scale and a map from its glyphs back to the chapter's Markdown.
//!
//! The Swift package `Packages/MussetPage` uses it through the C ABI in `ffi.rs` (`include/musset_typeset.h`).

pub mod document;
pub mod engine;
pub mod ffi;
pub mod markup;

pub use document::Spec;
pub use engine::{Book, Glyph};
