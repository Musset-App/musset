//! The book composed by the Typst library: pages, a text map per page, bitmaps.

use crate::document::{compose, template_source, Composed, Spec};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Element, Selector};
use typst::model::{FootnoteElem, FootnoteEntry};
use typst::layout::{Frame, FrameItem, PagedDocument, Point, Transform};
use typst::syntax::{FileId, Source, Span, VirtualPath};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World, WorldExt};
use typst_kit::fonts::{FontSlot, FontSearcher};

/// A glyph on a page and the characters of the chapter it shows. Laid out as `MTGlyph` in the C header.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Glyph {
    /// Its box on the page, in points from the top left.
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// The baseline, in points from the top.
    pub baseline: f32,
    /// The chapter's index in the book.
    pub chapter: i32,
    /// UTF-16 range in the chapter's Markdown.
    pub start: i32,
    pub end: i32,
    /// For a footnote's number (in the text or at the foot): the footnote's index in the book; else -1.
    pub footnote: i32,
}

pub struct PageInfo {
    pub width: f64,
    pub height: f64,
    pub glyphs: Vec<Glyph>,
    /// What each glyph shows, as Typst shaped it (for checks: the map's characters may be typed differently).
    pub shown: Vec<String>,
}

pub struct Footnote {
    pub chapter: u32,
    pub start: u32,
    pub end: u32,
    pub text: String,
}

pub struct Book {
    pub doc: PagedDocument,
    pub pages: Vec<PageInfo>,
    pub footnotes: Vec<Footnote>,
    pub source: String,
    pub warnings: Vec<String>,
}

// MARK: Fonts, found once per set of folders

struct FontSet {
    book: LazyHash<FontBook>,
    slots: Vec<FontSlot>,
}

fn fonts(dirs: &[String], system: bool) -> Arc<FontSet> {
    static CACHE: OnceLock<Mutex<HashMap<(Vec<String>, bool), Arc<FontSet>>>> = OnceLock::new();
    let key = (dirs.to_vec(), system);
    let mut cache = CACHE.get_or_init(Default::default).lock().unwrap();
    if let Some(f) = cache.get(&key) {
        return f.clone();
    }
    let found = FontSearcher::new().include_system_fonts(system).include_embedded_fonts(true).search_with(dirs);
    let set = Arc::new(FontSet { book: LazyHash::new(found.book), slots: found.fonts });
    cache.insert(key, set.clone());
    set
}

// MARK: The world Typst compiles in

struct MussetWorld {
    library: LazyHash<Library>,
    fonts: Arc<FontSet>,
    main: Source,
    template: Source,
    resources: Option<PathBuf>,
    files: Mutex<HashMap<FileId, Bytes>>,
}

impl World for MussetWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }
    fn book(&self) -> &LazyHash<FontBook> {
        &self.fonts.book
    }
    fn main(&self) -> FileId {
        self.main.id()
    }
    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            Ok(self.main.clone())
        } else if id == self.template.id() {
            Ok(self.template.clone())
        } else {
            let bytes = self.file(id)?;
            let text = std::str::from_utf8(&bytes).map_err(|_| FileError::InvalidUtf8)?;
            Ok(Source::new(id, text.to_string()))
        }
    }
    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.template.id() {
            return Ok(Bytes::from_string(self.template.text().to_string()));
        }
        if let Some(b) = self.files.lock().unwrap().get(&id) {
            return Ok(b.clone());
        }
        let path = id.vpath().as_rootless_path().to_path_buf();
        let Some(root) = &self.resources else { return Err(FileError::NotFound(path)) };
        if id.package().is_some() {
            return Err(FileError::NotFound(path));
        }
        let full = id.vpath().resolve(root).ok_or_else(|| FileError::AccessDenied)?;
        let data = std::fs::read(&full).map_err(|e| FileError::from_io(e, &full))?;
        let b = Bytes::new(data);
        self.files.lock().unwrap().insert(id, b.clone());
        Ok(b)
    }
    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.slots.get(index)?.get()
    }
    fn today(&self, _offset: Option<i64>) -> Option<Datetime> {
        None
    }
}

// MARK: Composing

/// A book as Typst laid it out, before anything is read from its pages.
struct Typeset {
    world: MussetWorld,
    composed: Composed,
    doc: PagedDocument,
    warnings: Vec<String>,
}

impl Typeset {
    fn new(spec: &Spec) -> Result<Typeset, String> {
        let composed = compose(spec);
        let system = spec.system_fonts.unwrap_or(cfg!(target_os = "macos"));
        let main_id = FileId::new(None, VirtualPath::new("main.typ"));
        let template_id = FileId::new(None, VirtualPath::new("musset.typ"));
        let world = MussetWorld {
            library: LazyHash::new(Library::default()),
            fonts: fonts(&spec.font_dirs, system),
            main: Source::new(main_id, composed.source.clone()),
            template: Source::new(template_id, template_source(&spec.template)),
            resources: spec.resource_dir.as_ref().map(PathBuf::from),
            files: Mutex::new(HashMap::new()),
        };
        let warned = typst::compile::<PagedDocument>(&world);
        let warnings = warned.warnings.iter().map(|w| w.message.to_string()).collect();
        let doc = warned.output.map_err(|errs| {
            errs.iter()
                .map(|e| {
                    let at = world.range(e.span).map(|r| format!(" (main.typ {}..{})", r.start, r.end)).unwrap_or_default();
                    format!("{}{}", e.message, at)
                })
                .collect::<Vec<_>>()
                .join("\n")
        })?;
        Ok(Typeset { world, composed, doc, warnings })
    }
}

/// The book as a PDF, for the export: the pages reading shows, without the text maps reading needs.
pub fn pdf(spec: &Spec) -> Result<Vec<u8>, String> {
    let set = Typeset::new(spec)?;
    let options = typst_pdf::PdfOptions { timestamp: now().map(typst_pdf::Timestamp::new_utc), ..Default::default() };
    typst_pdf::pdf(&set.doc, &options).map_err(|errs| errs.iter().map(|e| e.message.to_string()).collect::<Vec<_>>().join("\n"))
}

impl Book {
    pub fn compile(spec: &Spec) -> Result<Book, String> {
        let Typeset { world, composed, doc, warnings } = Typeset::new(spec)?;
        // A footnote's number has no place in the source: where Typst put each footnote and its entry tells them.
        let mut marks = vec![];
        for elem in [Element::of::<FootnoteElem>(), Element::of::<FootnoteEntry>()] {
            for (k, c) in doc.introspector.query(&Selector::Elem(elem, None)).iter().enumerate() {
                if let Some(loc) = c.location() {
                    let at = doc.introspector.position(loc);
                    marks.push((at.page.get() - 1, at.point.x.to_pt(), at.point.y.to_pt(), k));
                }
            }
        }
        let pages = doc
            .pages
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let mut glyphs = vec![];
                let mut shown = vec![];
                let page_marks: Vec<_> = marks.iter().filter(|m| m.0 == i).map(|m| (m.1, m.2, m.3)).collect();
                let mapper = Mapper { world: &world, composed: &composed, marks: page_marks };
                mapper.walk(&p.frame, Transform::identity(), &mut glyphs, &mut shown);
                PageInfo { width: p.frame.width().to_pt(), height: p.frame.height().to_pt(), glyphs, shown }
            })
            .collect();
        let footnotes =
            composed.notes.iter().map(|n| Footnote { chapter: n.chapter, start: n.m, end: n.e, text: n.text.clone() }).collect();
        Ok(Book { doc, pages, footnotes, source: composed.source, warnings })
    }

    /// The page showing a character of a chapter: the first page whose text runs past it.
    pub fn locate(&self, chapter: i32, offset: i32) -> usize {
        let key = (chapter, offset);
        let mut last_with_text = 0;
        for (i, p) in self.pages.iter().enumerate() {
            let end = p.glyphs.iter().filter(|g| g.chapter >= 0 && g.footnote < 0).map(|g| (g.chapter, g.end)).max();
            if let Some(end) = end {
                last_with_text = i;
                if end > key {
                    return i;
                }
            }
        }
        last_with_text
    }

    /// The page as RGBA pixels (premultiplied, opaque), white turned into `paper` and black into `ink`.
    pub fn render(&self, page: usize, pixel_per_pt: f32, paper: [u8; 3], ink: [u8; 3]) -> Option<(u32, u32, Vec<u8>)> {
        let p = self.doc.pages.get(page)?;
        let pixmap = typst_render::render(p, pixel_per_pt);
        let (w, h) = (pixmap.width(), pixmap.height());
        let mut data = pixmap.take();
        if paper != [255, 255, 255] || ink != [0, 0, 0] {
            // Per channel, ink + (paper − ink) × value: keeps antialiasing, and colours stay readable at night.
            let mut lut = [[0u8; 256]; 3];
            for ch in 0..3 {
                for v in 0..256 {
                    let (i, pp) = (ink[ch] as f32, paper[ch] as f32);
                    lut[ch][v] = (i + (pp - i) * v as f32 / 255.0).round().clamp(0.0, 255.0) as u8;
                }
            }
            for px in data.chunks_exact_mut(4) {
                px[0] = lut[0][px[0] as usize];
                px[1] = lut[1][px[1] as usize];
                px[2] = lut[2][px[2] as usize];
            }
        }
        Some((w, h, data))
    }
}

/// From a glyph's source span back to the chapter.
struct Mapper<'a> {
    world: &'a MussetWorld,
    composed: &'a Composed,
    /// The footnotes placed on this page (in the text and at the foot): x, y, index.
    marks: Vec<(f64, f64, usize)>,
}

impl Mapper<'_> {
    fn walk(&self, frame: &Frame, ts: Transform, out: &mut Vec<Glyph>, shown: &mut Vec<String>) {
        for (pos, item) in frame.items() {
            match item {
                FrameItem::Group(g) => {
                    let ts = ts.pre_concat(Transform::translate(pos.x, pos.y)).pre_concat(g.transform);
                    self.walk(&g.frame, ts, out, shown);
                }
                FrameItem::Text(text) => {
                    let m = text.font.metrics();
                    let asc = m.ascender.at(text.size);
                    let desc = m.descender.at(text.size);
                    let mut x = typst::layout::Abs::zero();
                    for g in &text.glyphs {
                        let adv = g.x_advance.at(text.size);
                        let gx = pos.x + x + g.x_offset.at(text.size);
                        let gy = pos.y - g.y_offset.at(text.size);
                        x += adv;
                        // The hyphen Typst adds where it breaks a word shows no character of the text (it borrows the
                        // span of the letter after it): leave it out of the map.
                        if text.text.get(g.range.start as usize..g.range.end as usize) == Some("\u{ad}") {
                            continue;
                        }
                        let found = self.locate(g.span, text, g).or_else(|| {
                            // A footnote's number: right where the footnote (or its entry) was placed.
                            let p = Point::new(gx, gy).transform(ts);
                            let (px, py, size) = (p.x.to_pt(), p.y.to_pt(), text.size.to_pt());
                            let k = self
                                .marks
                                .iter()
                                .find(|m| px >= m.0 - 0.5 && px <= m.0 + size * 2.0 && (py - m.1).abs() <= size * 1.5)?
                                .2;
                            let n = self.composed.notes.get(k)?;
                            Some((n.chapter as i32, n.m as i32, n.e as i32, k as i32))
                        });
                        let Some((chapter, start, end, footnote)) = found else { continue };
                        let corners = [
                            Point::new(gx, gy - asc),
                            Point::new(gx + adv, gy - asc),
                            Point::new(gx, gy - desc),
                            Point::new(gx + adv, gy - desc),
                        ]
                        .map(|p| p.transform(ts));
                        let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
                        for c in corners {
                            x0 = x0.min(c.x.to_pt());
                            y0 = y0.min(c.y.to_pt());
                            x1 = x1.max(c.x.to_pt());
                            y1 = y1.max(c.y.to_pt());
                        }
                        let base = Point::new(gx, gy).transform(ts).y.to_pt();
                        shown.push(text.text.get(g.range.start as usize..g.range.end as usize).unwrap_or("").to_string());
                        out.push(Glyph {
                            x: x0 as f32,
                            y: y0 as f32,
                            w: (x1 - x0) as f32,
                            h: (y1 - y0) as f32,
                            baseline: base as f32,
                            chapter,
                            start,
                            end,
                            footnote,
                        });
                    }
                }
                _ => {}
            }
        }
    }

    fn locate(
        &self,
        span: (Span, u16),
        text: &typst::text::TextItem,
        g: &typst::text::Glyph,
    ) -> Option<(i32, i32, i32, i32)> {
        if span.0.id() != Some(self.world.main.id()) {
            return None;
        }
        let r = self.world.range(span.0)?;
        // Inline code: the offset counts in the code's text.
        if let Some(raw) = self.composed.raws.iter().find(|w| (r.start as u32) <= w.b && (r.end as u32) >= w.a) {
            let mut at = 0u32;
            for &(len, m, l) in &raw.items {
                if (span.1 as u32) < at + len {
                    return Some((raw.chapter as i32, m as i32, (m + l) as i32, -1));
                }
                at += len;
            }
            return None;
        }
        // The offset counts in the shaped text, which may be longer than the source: a French quote is one `"`
        // in the source and "« " on the page. Stay inside the node.
        let b = (r.start + (span.1 as usize).min(r.len().saturating_sub(1))) as u32;
        let es = &self.composed.entries;
        let i = es.partition_point(|e| e.b <= b);
        if i < es.len() && es[i].a <= b {
            let e = es[i];
            // A ligature shows several characters: the following runs, while they are in the same chapter.
            let glyph_text = text.text.get(g.range.start as usize..g.range.end as usize).unwrap_or("");
            // An ellipsis Typst made of "..." shows three characters.
            let shown = if glyph_text == "…" && self.composed.source.as_bytes().get(e.a as usize) == Some(&b'.') {
                3
            } else {
                glyph_text.chars().count()
            };
            let last = (i + shown.max(1) - 1).min(es.len() - 1);
            let last = if es[last].chapter == e.chapter && es[last].m >= e.m { es[last] } else { e };
            return Some((e.chapter as i32, e.m as i32, (last.m + last.l) as i32, -1));
        }
        // Not a character of the text: a footnote's number, if it is inside a `#footnote[…]`.
        let notes = &self.composed.notes;
        let k = notes.iter().enumerate().filter(|(_, n)| n.a <= b && b < n.b).min_by_key(|(_, n)| n.b - n.a)?.0;
        let n = &notes[k];
        Some((n.chapter as i32, n.m as i32, n.e as i32, k as i32))
    }
}

/// Now, in UTC, for the PDF's creation date.
fn now() -> Option<Datetime> {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Days since 1970 as a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u8;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u8;
    let year = (yoe + era * 400 + if month <= 2 { 1 } else { 0 }) as i32;
    Datetime::from_ymd_hms(year, month, day, (rest / 3_600) as u8, (rest % 3_600 / 60) as u8, (rest % 60) as u8)
}

/// Frees the memoized layout older than `max_age` compilations.
pub fn evict(max_age: usize) {
    comemo::evict(max_age);
}
