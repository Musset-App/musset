// Musset's typesetter: a Musset book composed by the Typst library into pages, bitmaps, text maps and a PDF.
// Built from musset-typeset/ by scripts/build-typeset.sh. All functions may be called from any thread.
#ifndef MUSSET_TYPESET_H
#define MUSSET_TYPESET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A composed book. Immutable: it may be read from several threads at once.
typedef struct MTBook MTBook;

/// A glyph on a page and the characters of the chapter it shows.
typedef struct MTGlyph {
    /// Its box on the page, in points from the top left.
    float x, y, w, h;
    /// The baseline, in points from the top of the page.
    float baseline;
    /// The chapter's index in the book.
    int32_t chapter;
    /// UTF-16 range in the chapter's Markdown.
    int32_t start, end;
    /// For a footnote's number (in the text or at the foot): the footnote's index; else -1.
    int32_t footnote;
} MTGlyph;

/// Composes a book from its JSON description (see musset-typeset/src/document.rs, `Spec`). On failure returns
/// NULL and sets *error (if error is not NULL) to a message to free with mt_string_free.
MTBook *mt_book_compile(const char *spec_json, char **error);
void mt_book_free(MTBook *book);

uint32_t mt_book_page_count(const MTBook *book);
/// The page's size in points. False when there is no such page.
bool mt_book_page_size(const MTBook *book, uint32_t page, double *width, double *height);
/// Copies up to `capacity` glyphs of the page into `buffer` (may be NULL) and returns how many the page has.
size_t mt_book_page_glyphs(const MTBook *book, uint32_t page, MTGlyph *buffer, size_t capacity);
/// The page showing a character of a chapter (UTF-16 offset in its Markdown).
uint32_t mt_book_locate(const MTBook *book, int32_t chapter, int32_t offset);

/// The page as RGBA, premultiplied, 8 bits per channel, rows of width × 4 bytes, at `scale` pixels per point.
/// White becomes `paper` and black `ink` (0xRRGGBB). Free with mt_bitmap_free(pixels, width * height * 4).
uint8_t *mt_book_render(const MTBook *book, uint32_t page, float scale, uint32_t paper, uint32_t ink,
                        uint32_t *width, uint32_t *height);
void mt_bitmap_free(uint8_t *pixels, size_t length);

/// A book from its JSON description straight to its PDF (the export): the pages mt_book_compile would give, without
/// their text maps. Free with mt_bitmap_free(bytes, *length). On failure returns NULL and sets *error (if error is
/// not NULL) to a message to free with mt_string_free.
uint8_t *mt_pdf(const char *spec_json, size_t *length, char **error);

/// JSON: [{"chapter":0,"start":12,"end":40,"text":"…"}], in the order of MTGlyph.footnote.
char *mt_book_footnotes_json(const MTBook *book);
/// The Typst source the book was composed from.
char *mt_book_source(const MTBook *book);
/// Typst's warnings, as a JSON array of strings.
char *mt_book_warnings_json(const MTBook *book);
void mt_string_free(char *string);

/// Frees Typst's memoized layout older than `max_age` compositions (0 frees all of it).
void mt_evict(uint32_t max_age);

#ifdef __cplusplus
}
#endif

#endif
