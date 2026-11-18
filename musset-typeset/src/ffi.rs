//! The C ABI (`include/musset_typeset.h`). Every function is safe to call from any thread; a book is immutable once
//! composed, so one may be read from several threads at once.

use crate::document::Spec;
use crate::engine::{evict, pdf, Book, Glyph};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

pub struct MTBook(Book);

fn cstring(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', "")).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

/// Composes a book from its JSON description. On failure returns null and, if `error` is not null, sets it to a
/// message to free with `mt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn mt_book_compile(spec_json: *const c_char, error: *mut *mut c_char) -> *mut MTBook {
    let fail = |msg: &str| {
        if !error.is_null() {
            *error = cstring(msg);
        }
        ptr::null_mut()
    };
    if spec_json.is_null() {
        return fail("no book given");
    }
    let json = match CStr::from_ptr(spec_json).to_str() {
        Ok(s) => s,
        Err(_) => return fail("the book's description is not UTF-8"),
    };
    let spec: Spec = match serde_json::from_str(json) {
        Ok(s) => s,
        Err(e) => return fail(&format!("the book's description is not valid: {e}")),
    };
    match catch_unwind(AssertUnwindSafe(|| Book::compile(&spec))) {
        Ok(Ok(book)) => Box::into_raw(Box::new(MTBook(book))),
        Ok(Err(msg)) => fail(&msg),
        Err(_) => fail("Typst stopped unexpectedly while composing the book"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn mt_book_free(book: *mut MTBook) {
    if !book.is_null() {
        drop(Box::from_raw(book));
    }
}

#[no_mangle]
pub unsafe extern "C" fn mt_book_page_count(book: *const MTBook) -> u32 {
    book.as_ref().map(|b| b.0.pages.len() as u32).unwrap_or(0)
}

/// The page's size in points. False when there is no such page.
#[no_mangle]
pub unsafe extern "C" fn mt_book_page_size(book: *const MTBook, page: u32, width: *mut f64, height: *mut f64) -> bool {
    let Some(p) = book.as_ref().and_then(|b| b.0.pages.get(page as usize)) else { return false };
    if !width.is_null() {
        *width = p.width;
    }
    if !height.is_null() {
        *height = p.height;
    }
    true
}

/// Copies up to `capacity` of the page's glyphs into `buffer` (which may be null) and returns how many it has.
#[no_mangle]
pub unsafe extern "C" fn mt_book_page_glyphs(book: *const MTBook, page: u32, buffer: *mut Glyph, capacity: usize) -> usize {
    let Some(p) = book.as_ref().and_then(|b| b.0.pages.get(page as usize)) else { return 0 };
    if !buffer.is_null() {
        let n = capacity.min(p.glyphs.len());
        ptr::copy_nonoverlapping(p.glyphs.as_ptr(), buffer, n);
    }
    p.glyphs.len()
}

/// The page showing a character of a chapter (UTF-16 offset in its Markdown).
#[no_mangle]
pub unsafe extern "C" fn mt_book_locate(book: *const MTBook, chapter: i32, offset: i32) -> u32 {
    book.as_ref().map(|b| b.0.locate(chapter, offset) as u32).unwrap_or(0)
}

/// The page as RGBA (premultiplied, 8 bits per channel, rows of `width × 4` bytes) at `scale` pixels per point.
/// White becomes `paper` and black `ink` (0xRRGGBB). Free with `mt_bitmap_free(pixels, width * height * 4)`.
#[no_mangle]
pub unsafe extern "C" fn mt_book_render(
    book: *const MTBook,
    page: u32,
    scale: f32,
    paper: u32,
    ink: u32,
    width: *mut u32,
    height: *mut u32,
) -> *mut u8 {
    let Some(b) = book.as_ref() else { return ptr::null_mut() };
    let rgb = |c: u32| [(c >> 16) as u8, (c >> 8) as u8, c as u8];
    let rendered = catch_unwind(AssertUnwindSafe(|| b.0.render(page as usize, scale.max(0.01), rgb(paper), rgb(ink))));
    let Ok(Some((w, h, data))) = rendered else { return ptr::null_mut() };
    if !width.is_null() {
        *width = w;
    }
    if !height.is_null() {
        *height = h;
    }
    Box::into_raw(data.into_boxed_slice()) as *mut u8
}

/// A book from its JSON description straight to its PDF, for the export. Free with `mt_bitmap_free(bytes, length)`.
/// On failure returns null and, if `error` is not null, sets it to a message to free with `mt_string_free`.
#[no_mangle]
pub unsafe extern "C" fn mt_pdf(spec_json: *const c_char, length: *mut usize, error: *mut *mut c_char) -> *mut u8 {
    let fail = |msg: &str| {
        if !error.is_null() {
            *error = cstring(msg);
        }
        ptr::null_mut()
    };
    if spec_json.is_null() {
        return fail("no book given");
    }
    let json = match CStr::from_ptr(spec_json).to_str() {
        Ok(s) => s,
        Err(_) => return fail("the book's description is not UTF-8"),
    };
    let spec: Spec = match serde_json::from_str(json) {
        Ok(s) => s,
        Err(e) => return fail(&format!("the book's description is not valid: {e}")),
    };
    match catch_unwind(AssertUnwindSafe(|| pdf(&spec))) {
        Ok(Ok(data)) => {
            if !length.is_null() {
                *length = data.len();
            }
            Box::into_raw(data.into_boxed_slice()) as *mut u8
        }
        Ok(Err(msg)) => fail(&msg),
        Err(_) => fail("Typst stopped unexpectedly while writing the PDF"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn mt_bitmap_free(pixels: *mut u8, length: usize) {
    if !pixels.is_null() {
        drop(Box::from_raw(ptr::slice_from_raw_parts_mut(pixels, length)));
    }
}

/// The book's footnotes as JSON: `[{"chapter":0,"start":12,"end":40,"text":"…"}]`, in the order of the
/// `footnote` index the glyphs carry.
#[no_mangle]
pub unsafe extern "C" fn mt_book_footnotes_json(book: *const MTBook) -> *mut c_char {
    let Some(b) = book.as_ref() else { return ptr::null_mut() };
    let v: Vec<_> = b
        .0
        .footnotes
        .iter()
        .map(|n| serde_json::json!({"chapter": n.chapter, "start": n.start, "end": n.end, "text": n.text}))
        .collect();
    cstring(&serde_json::Value::Array(v).to_string())
}

/// The Typst source the book was composed from.
#[no_mangle]
pub unsafe extern "C" fn mt_book_source(book: *const MTBook) -> *mut c_char {
    book.as_ref().map(|b| cstring(&b.0.source)).unwrap_or(ptr::null_mut())
}

/// Typst's warnings, as a JSON array of strings.
#[no_mangle]
pub unsafe extern "C" fn mt_book_warnings_json(book: *const MTBook) -> *mut c_char {
    book.as_ref().map(|b| cstring(&serde_json::to_string(&b.0.warnings).unwrap_or_default())).unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn mt_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Frees Typst's memoized layout older than `max_age` compilations (0 frees all of it).
#[no_mangle]
pub extern "C" fn mt_evict(max_age: u32) {
    evict(max_age as usize);
}
