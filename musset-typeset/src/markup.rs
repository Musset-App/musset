//! A Musset chapter's Markdown as Typst markup, with a map from every byte of markup that shows a character of
//! the chapter back to that character's place in the Markdown.
//!
//! The one place Musset's Markdown becomes Typst: reading and the PDF export compose the same source, and so break
//! lines and pages in the same places.
//!
//! Offsets into the Markdown are UTF-16 code units, like `NSString` and `NSRange` on the Swift side.

use regex::Regex;
use std::sync::OnceLock;
use unicode_segmentation::UnicodeSegmentation;

/// One character of the chapter, with where it came from in the Markdown (UTF-16).
#[derive(Clone, Copy, Debug)]
pub struct MChar {
    pub c: char,
    pub off: u32,
    pub len: u32,
}

/// A grapheme cluster (Swift's `Character`), with its place in the Markdown.
#[derive(Clone, Debug)]
struct G {
    s: String,
    off: u32,
    len: u32,
}

impl G {
    fn first(&self) -> char {
        self.s.chars().next().unwrap_or('\0')
    }
    fn is(&self, s: &str) -> bool {
        self.s == s
    }
    fn is_whitespace(&self) -> bool {
        self.first().is_whitespace()
    }
    fn is_letter(&self) -> bool {
        self.first().is_alphabetic()
    }
}

/// A piece of markup and, for each run of it that shows a character of the chapter, where that character is.
#[derive(Default, Debug, Clone)]
pub struct Frag {
    pub s: String,
    /// (byte start, byte end) in `s` → (UTF-16 start, UTF-16 length) in the Markdown.
    pub map: Vec<(u32, u32, u32, u32)>,
    /// Footnotes: (byte start, byte end) of `#footnote[…]` in `s`, the Markdown range of `^[…]`, the note's text.
    pub notes: Vec<(u32, u32, u32, u32, String)>,
    /// The characters shown, as text (for a footnote's popup).
    pub plain: String,
    /// Inline code: (byte start, byte end) of its string literal, and each character's length in the code's text
    /// (UTF-8) with its Markdown range. Typst places code glyphs by their offset in that text, not in the source.
    pub raws: Vec<(u32, u32, Vec<(u32, u32, u32)>)>,
}

impl Frag {
    fn raw(&mut self, t: &str) {
        self.s.push_str(t);
    }
    fn mapped(&mut self, t: &str, g: &G) {
        let a = self.s.len() as u32;
        self.s.push_str(t);
        self.map.push((a, self.s.len() as u32, g.off, g.len));
        self.plain.push_str(&g.s);
    }
    /// A string literal's content, each character mapped (inline code).
    fn mapped_literal(&mut self, gs: &[G]) {
        let a = self.s.len() as u32;
        for g in gs {
            self.mapped(&escape_string(&g.s), g);
        }
        let items = gs.iter().map(|g| (g.s.len() as u32, g.off, g.len)).collect();
        self.raws.push((a, self.s.len() as u32, items));
    }
    fn append(&mut self, o: Frag) {
        let shift = self.s.len() as u32;
        self.s.push_str(&o.s);
        self.map.extend(o.map.into_iter().map(|(a, b, m, l)| (a + shift, b + shift, m, l)));
        self.notes.extend(o.notes.into_iter().map(|(a, b, m, e, t)| (a + shift, b + shift, m, e, t)));
        self.raws.extend(o.raws.into_iter().map(|(a, b, items)| (a + shift, b + shift, items)));
        self.plain.push_str(&o.plain);
    }
    fn is_empty(&self) -> bool {
        self.s.is_empty()
    }
    /// Inserts markup at a byte position: a mapped run starting there grows to cover it.
    fn insert_raw(&mut self, at: usize, t: &str) {
        let n = t.len() as u32;
        let at32 = at as u32;
        self.s.insert_str(at, t);
        for e in &mut self.map {
            if e.0 > at32 {
                e.0 += n;
                e.1 += n;
            } else if e.0 == at32 || e.1 > at32 {
                e.1 += n;
            }
        }
        for e in &mut self.raws {
            if e.0 >= at32 {
                e.0 += n;
                e.1 += n;
            }
        }
        for e in &mut self.notes {
            if e.0 >= at32 {
                e.0 += n;
                e.1 += n;
            } else if e.1 > at32 {
                e.1 += n;
            }
        }
    }
}

/// How a break between two scenes shows (`m.sceneBreak` in the book's manifest).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum SceneBreak {
    #[default]
    None,
    Blank,
    Asterism,
}

/// The lists a book recognises (`ListOptions` in the app). Bullets always were; numbered lists are the book's
/// to ask for, since in prose « 1943. Barcelone. » is a sentence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Lists {
    pub bullets: bool,
    pub numbered: bool,
}

impl Default for Lists {
    fn default() -> Self {
        Lists { bullets: true, numbered: false }
    }
}

pub fn mtext(s: &str) -> Vec<MChar> {
    let mut out = Vec::with_capacity(s.len());
    let mut off = 0u32;
    for c in s.chars() {
        let len = c.len_utf16() as u32;
        out.push(MChar { c, off, len });
        off += len;
    }
    out
}

fn string(t: &[MChar]) -> String {
    t.iter().map(|m| m.c).collect()
}

/// Byte offset in `string(t)` → index in `t`.
fn byte_index(t: &[MChar]) -> Vec<usize> {
    let mut v = Vec::with_capacity(t.len() + 1);
    let mut b = 0;
    for m in t {
        v.push(b);
        b += m.c.len_utf8();
    }
    v.push(b);
    v
}

fn char_at(bytes: &[usize], b: usize) -> usize {
    bytes.binary_search(&b).unwrap_or_else(|i| i)
}

// MARK: CriticMarkup (`Revisions` in the app)

fn revisions() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| {
        Regex::new(r"(?s)(?:\{\+\+(.*?)\+\+\}|\{--(.*?)--\}|\{~~(.*?)~>(.*?)~~\}|\{==(.*?)==\}(?:\{>>(.*?)<<\})?|\{>>(.*?)<<\})(?:\{@([^}\n]*)\})?").unwrap()
    })
}

/// The marks decided as refused: what was there before the corrections (insertions dropped, deletions and
/// replaced text kept, comments dropped). With `only_multiline`, only the marks holding a line feed.
fn refuse_marks(t: &[MChar], only_multiline: bool) -> Vec<MChar> {
    let s = string(t);
    if !s.contains('{') {
        return t.to_vec();
    }
    let bytes = byte_index(t);
    let mut out = Vec::with_capacity(t.len());
    let mut cursor = 0usize;
    for c in revisions().captures_iter(&s) {
        let whole = c.get(0).unwrap();
        if only_multiline && !whole.as_str().contains('\n') {
            continue;
        }
        let a = char_at(&bytes, whole.start());
        out.extend_from_slice(&t[cursor..a]);
        let keep = if c.get(1).is_some() {
            None
        } else if let Some(g) = c.get(2) {
            Some(g)
        } else if let Some(g) = c.get(3) {
            Some(g)
        } else if let Some(g) = c.get(5) {
            Some(g)
        } else {
            None
        };
        if let Some(g) = keep {
            out.extend_from_slice(&t[char_at(&bytes, g.start())..char_at(&bytes, g.end())]);
        }
        cursor = char_at(&bytes, whole.end());
    }
    out.extend_from_slice(&t[cursor..]);
    out
}

fn scenes() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?im)^[ \t]*<!--[ \t]*sc[eè]ne[ \t]*:[ \t]*(.*?)[ \t]*-->[ \t]*$").unwrap())
}

// MARK: Lines and trimming, as Foundation does them

fn is_line_end(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `NSString.lineRange`: each line with its terminator.
fn lines(t: &[MChar]) -> Vec<&[MChar]> {
    let mut out = vec![];
    let mut start = 0;
    let mut i = 0;
    while i < t.len() {
        if is_line_end(t[i].c) {
            let mut end = i + 1;
            if t[i].c == '\r' && i + 1 < t.len() && t[i + 1].c == '\n' {
                end += 1;
            }
            out.push(&t[start..end]);
            start = end;
            i = end;
        } else {
            i += 1;
        }
    }
    if start < t.len() {
        out.push(&t[start..]);
    }
    out
}

/// `CharacterSet.newlines`.
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}
/// `CharacterSet.whitespaces`: tab and the space separators.
fn is_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !is_newline(c))
}

fn trim(t: &[MChar], f: impl Fn(char) -> bool) -> &[MChar] {
    let a = t.iter().position(|m| !f(m.c)).unwrap_or(t.len());
    let b = t.iter().rposition(|m| !f(m.c)).map(|i| i + 1).unwrap_or(a);
    &t[a..b.max(a)]
}

fn has_suffix(t: &[MChar], s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    t.len() >= cs.len() && t[t.len() - cs.len()..].iter().zip(&cs).all(|(m, c)| m.c == *c)
}

fn has_prefix(t: &[MChar], s: &str) -> bool {
    let cs: Vec<char> = s.chars().collect();
    t.len() >= cs.len() && t[..cs.len()].iter().zip(&cs).all(|(m, c)| m.c == *c)
}

fn strip_comments(t: &[MChar], in_comment: &mut bool) -> Vec<MChar> {
    let mut out = vec![];
    let mut rest = t;
    let find = |r: &[MChar], pat: &str| -> Option<usize> {
        let p: Vec<char> = pat.chars().collect();
        (0..r.len()).find(|&i| i + p.len() <= r.len() && r[i..i + p.len()].iter().zip(&p).all(|(m, c)| m.c == *c))
    };
    while !rest.is_empty() {
        if *in_comment {
            match find(rest, "-->") {
                None => return out,
                Some(i) => {
                    rest = &rest[i + 3..];
                    *in_comment = false;
                }
            }
        } else if let Some(i) = find(rest, "<!--") {
            out.extend_from_slice(&rest[..i]);
            rest = &rest[i + 4..];
            *in_comment = true;
        } else {
            out.extend_from_slice(rest);
            break;
        }
    }
    out
}

fn graphemes(t: &[MChar]) -> Vec<G> {
    let s = string(t);
    let bytes = byte_index(t);
    s.grapheme_indices(true)
        .map(|(b, g)| {
            let a = char_at(&bytes, b);
            let z = char_at(&bytes, b + g.len());
            let off = t[a].off;
            let end = t[z - 1].off + t[z - 1].len;
            G { s: g.to_string(), off, len: end.saturating_sub(off).max(t[a].len) }
        })
        .collect()
}

// MARK: The chapter

/// A chapter's Markdown as Typst markup (`TypstMarkup.chapter`). With `markers`, every paragraph starts with
/// `#mk(chapter, offset)` as in reading mode.
pub fn chapter(md: &str, id: &str, markers: bool, scene_break: SceneBreak, lists: Lists) -> Frag {
    let all = refuse_marks(&mtext(md), true);
    // The list being written: whether the line before (blank lines aside) was an item, its depth, and at each
    // depth whether a numbered list is under way (its first item says the number, the others count on).
    let mut in_list = false;
    let mut depth = 0usize;
    let mut counting = [false; 3];
    let mut out = Frag::default();
    let mut quote: Vec<(Vec<MChar>, bool)> = vec![];
    let mut quote_offset = 0u32;
    let mut in_comment = false;
    let mut saw_prose = false;
    let marker = |offset: u32| -> String {
        if markers {
            format!("#mk(\"{}\", {})", escape_string(id), offset)
        } else {
            String::new()
        }
    };
    let flush_quote = |out: &mut Frag, quote: &mut Vec<(Vec<MChar>, bool)>, saw: &mut bool, qoff: u32| {
        if quote.is_empty() {
            return;
        }
        *saw = true;
        out.raw("#quote(block: true)[");
        out.raw(&marker(qoff));
        let n = quote.len();
        for (i, (text, hard)) in quote.iter().enumerate() {
            out.append(inline(&graphemes(text)));
            if i != n - 1 {
                out.raw(if *hard { " \\\n" } else { " " });
            }
        }
        out.raw("]\n\n");
        quote.clear();
    };
    for r in lines(&all) {
        let location = r.first().map(|m| m.off).unwrap_or(0);
        let text = refuse_marks(r, false);
        let bare = trim(&text, is_newline);
        if !in_comment && scenes().is_match(&string(bare)) {
            flush_quote(&mut out, &mut quote, &mut saw_prose, quote_offset);
            if saw_prose {
                match scene_break {
                    SceneBreak::None => {}
                    SceneBreak::Blank => out.raw("#scenegap()\n\n"),
                    SceneBreak::Asterism => out.raw("#asterism()\n\n"),
                }
            }
            continue;
        }
        let breaks_inside = has_suffix(&text, "\u{2028}");
        let text = strip_comments(&text, &mut in_comment);
        let line = trim(&text, char::is_whitespace);
        if line.is_empty() {
            flush_quote(&mut out, &mut quote, &mut saw_prose, quote_offset);
            continue;
        }
        if has_prefix(line, ">") {
            in_list = false;
            if quote.is_empty() {
                quote_offset = location;
            }
            let body = trim(&line[1..], is_space);
            let backslash = has_suffix(body, "\\");
            let body = if backslash { &body[..body.len() - 1] } else { body };
            quote.push((body.to_vec(), breaks_inside || backslash || has_suffix(&text, "  \n")));
            continue;
        }
        flush_quote(&mut out, &mut quote, &mut saw_prose, quote_offset);
        let was_in_list = in_list;
        in_list = false;
        let ls = string(line);
        if ls.starts_with('\\') {
            if let Some(block) = latex_block(&ls) {
                out.raw(&block);
                continue;
            }
        }
        if ls.chars().all(|c| "*-_ ".contains(c)) && ls.chars().filter(|c| !c.is_whitespace()).count() >= 3 {
            out.raw("#scenebreak()\n\n");
        } else if let Some((level, h)) = heading(line) {
            saw_prose = false;
            out.raw(&"=".repeat(level));
            out.raw(" ");
            out.raw(&marker(location));
            out.append(inline(&graphemes(h)));
            out.raw("\n\n");
        } else if let Some(item) = list_item(line, lists, was_in_list) {
            // An item nests under the one before it, one level at a time; alone, or first, it is not nested.
            let level = if was_in_list { indent_level(&text).min(depth + 1) } else { 0 };
            if !was_in_list {
                counting = [false; 3];
            }
            for deeper in counting.iter_mut().skip(level + 1) {
                *deeper = false;
            }
            out.raw(&"  ".repeat(level));
            match item.number {
                None => {
                    counting[level] = false;
                    out.raw("- ");
                }
                // The numbers are the list's own: it starts where its first item says and counts from there.
                Some(n) if !counting[level] => {
                    counting[level] = true;
                    out.raw(&format!("{n}. "));
                }
                Some(_) => out.raw("+ "),
            }
            out.append(inline(&graphemes(item.body)));
            out.raw("\n");
            in_list = true;
            depth = level;
        } else {
            saw_prose = true;
            let hard = breaks_inside || has_suffix(&text, "  \n") || has_suffix(line, "\\");
            let body = if hard && has_suffix(line, "\\") { &line[..line.len() - 1] } else { line };
            out.raw(&marker(location));
            out.append(inline(&graphemes(body)));
            out.raw(if hard { " \\\n" } else { "\n\n" });
        }
    }
    flush_quote(&mut out, &mut quote, &mut saw_prose, quote_offset);
    out
}

fn heading(line: &[MChar]) -> Option<(usize, &[MChar])> {
    let hashes = line.iter().take_while(|m| m.c == '#').count();
    if !(1..=6).contains(&hashes) || line.get(hashes).map(|m| m.c) != Some(' ') {
        return None;
    }
    Some((hashes, trim(&line[hashes..], is_space)))
}

struct Item<'a> {
    /// None for a bullet.
    number: Option<u32>,
    body: &'a [MChar],
}

/// A line that is a list item (`ListLines.item` in the app, the same rule).
///
/// Bullets, in a book that has bullet lists: « - », « + » or « * » and a space. A scene break (`* * *`) was taken
/// before this is asked, `*mot*` has no space, and a dialogue dash (« — ») is not an ASCII hyphen.
///
/// Numbered items, only in a book that asks for numbered lists: one to three digits, « . » or « ) », a space, on
/// a line that starts a list at 1 or follows another item (`in_list`; blank lines do not count). So a paragraph
/// « 1943. Barcelone. » is never an item (four digits), and « 36. Guerre. » alone, or after prose, is not one
/// either: a list has to start at 1.
fn list_item(line: &[MChar], lists: Lists, in_list: bool) -> Option<Item<'_>> {
    if lists.bullets {
        if has_prefix(line, "- ") || has_prefix(line, "+ ") {
            return Some(Item { number: None, body: &line[2..] });
        }
        if has_prefix(line, "* ") && trim(&line[2..], is_space).first().is_some_and(|m| m.c != '*') {
            return Some(Item { number: None, body: &line[2..] });
        }
    }
    if lists.numbered {
        let digits = line.iter().take_while(|m| m.c.is_ascii_digit()).count();
        if (1..=3).contains(&digits)
            && line.get(digits).is_some_and(|m| m.c == '.' || m.c == ')')
            && line.get(digits + 1).is_some_and(|m| m.c == ' ' || m.c == '\t')
        {
            let n: u32 = line[..digits].iter().map(|m| m.c).collect::<String>().parse().unwrap_or(0);
            let body = trim(&line[digits + 2..], is_space);
            if !body.is_empty() && (n == 1 || in_list) {
                return Some(Item { number: Some(n), body });
            }
        }
    }
    None
}

/// How deep a line's white space nests its item: two to five columns once, six or more twice (a tab is four).
fn indent_level(text: &[MChar]) -> usize {
    let columns: usize = text.iter().take_while(|m| m.c == ' ' || m.c == '\t').map(|m| if m.c == '\t' { 4 } else { 1 }).sum();
    ((columns + 2) / 4).min(2)
}

// MARK: Raw LaTeX the books used with pandoc (exergues, dedications)

fn latex_block(line: &str) -> Option<String> {
    static R: OnceLock<Regex> = OnceLock::new();
    let re = R.get_or_init(|| Regex::new(r"^\\([a-zA-Z]+)(\*?)(?:\{([^}]*)\})?\s*$").unwrap());
    let m = re.captures(line)?;
    let name = m.get(1).unwrap().as_str();
    let arg = m.get(3).map(|a| a.as_str());
    Some(match name {
        "begin" => match arg {
            Some("center") => "#align(center)[\n".into(),
            Some("flushright") => "#align(right)[\n".into(),
            Some("flushleft") => "#align(left)[\n".into(),
            Some("quote") | Some("quotation") => "#quote(block: true)[\n".into(),
            _ => "#block[\n".into(),
        },
        "end" => "]\n\n".into(),
        "clearpage" | "newpage" | "cleardoublepage" | "pagebreak" => "#pagebreak()\n\n".into(),
        "thispagestyle" => {
            if arg == Some("empty") {
                "#nofolio()\n".into()
            } else {
                String::new()
            }
        }
        "vspace" | "vskip" => format!("#v({})\n", latex_length(arg.unwrap_or("1em"))),
        "vfill" => "#v(1fr)\n".into(),
        "noindent" | "centering" | "raggedright" | "raggedleft" | "bigskip" | "medskip" | "smallskip" => {
            if name.ends_with("skip") {
                let v = match name {
                    "bigskip" => "1em",
                    "medskip" => "0.5em",
                    _ => "0.25em",
                };
                format!("#v({v})\n")
            } else {
                String::new()
            }
        }
        _ => return None,
    })
}

/// "0.42\textheight" → "42%", "0.75\baselineskip" → "0.75em", "\fill" → "1fr", "12mm" stays.
fn latex_length(s: &str) -> String {
    let t = s.trim_matches(|c: char| is_space(c));
    if t == "\\fill" || t == "\\vfill" {
        return "1fr".into();
    }
    let num: String = t.chars().take_while(|c| c.is_numeric() || *c == '.').collect();
    let number: f64 = num.parse().unwrap_or(1.0);
    if t.ends_with("\\textheight") {
        return format!("{}%", (number * 100.0).round() as i64);
    }
    if t.ends_with("\\baselineskip") {
        return format!("{}em", swift_double(number));
    }
    static R: OnceLock<Regex> = OnceLock::new();
    if R.get_or_init(|| Regex::new(r"^[0-9.]+(mm|cm|pt|em|in)$").unwrap()).is_match(t) {
        return t.into();
    }
    "1em".into()
}

/// A Double as Swift interpolates it: "0.75", "1.0".
fn swift_double(x: f64) -> String {
    if x.fract() == 0.0 && x.abs() < 1e16 {
        format!("{x:.1}")
    } else {
        format!("{x}")
    }
}

// MARK: Inline Markdown

/// Inline Markdown → Typst: emphasis, strong, code, links, footnotes; everything else escaped.
fn inline(chars: &[G]) -> Frag {
    let mut result = inline_body(chars);
    // "1943. …" at the start of a line would be a Typst numbered list.
    static R: OnceLock<Regex> = OnceLock::new();
    if let Some(m) = R.get_or_init(|| Regex::new(r"^\d+\.").unwrap()).find(&result.s) {
        result.insert_raw(m.end() - 1, "\\");
    }
    result
}

fn inline_body(chars: &[G]) -> Frag {
    let mut out = Frag::default();
    let n = chars.len();
    let find = |token: &str, from: usize| -> Option<usize> {
        let t: Vec<&str> = token.graphemes(true).collect();
        let mut j = from;
        while j + t.len() <= n {
            if chars[j..j + t.len()].iter().zip(&t).all(|(g, s)| g.s == *s) && j > from && !chars[j - 1].is_whitespace() {
                return Some(j);
            }
            j += 1;
        }
        None
    };
    let first_from = |s: &str, from: usize| -> Option<usize> { (from..n).find(|&k| chars[k].is(s)) };
    let mut i = 0;
    while i < n {
        let c = &chars[i];
        let next = chars.get(i + 1);
        if c.is("*") && next.map(|g| g.is("*")) == Some(true) {
            if let Some(end) = find("**", i + 2) {
                out.raw("#strong[");
                out.append(inline(&chars[i + 2..end]));
                out.raw("]");
                i = end + 2;
                continue;
            }
        }
        if c.is("*") || (c.is("_") && (i == 0 || !chars[i - 1].is_letter())) {
            if let Some(nx) = next {
                if !nx.is_whitespace() {
                    if let Some(end) = find(&c.s, i + 1) {
                        if c.is("*") || end + 1 >= n || !chars[end + 1].is_letter() {
                            out.raw("#emph[");
                            out.append(inline(&chars[i + 1..end]));
                            out.raw("]");
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        if c.is("`") {
            if let Some(end) = first_from("`", i + 1) {
                out.raw("#raw(\"");
                out.mapped_literal(&chars[i + 1..end]);
                out.raw("\")");
                i = end + 1;
                continue;
            }
        }
        // ^[…]: a footnote (brackets may nest inside it).
        if c.is("^") && next.map(|g| g.is("[")) == Some(true) {
            let mut depth = 0i32;
            let mut j = i + 1;
            let mut close = None;
            while j < n {
                if chars[j].is("[") {
                    depth += 1;
                } else if chars[j].is("]") {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(j);
                        break;
                    }
                }
                j += 1;
            }
            if let Some(close) = close {
                let start = out.s.len() as u32;
                out.raw("#footnote[");
                let body = inline(&chars[i + 2..close]);
                let text = body.plain.clone();
                out.append(body);
                out.raw("]");
                let mstart = c.off;
                let mend = chars[close].off + chars[close].len;
                out.notes.push((start, out.s.len() as u32, mstart, mend, text));
                i = close + 1;
                continue;
            }
        }
        if c.is("[") {
            if let Some(close) = first_from("]", i + 1) {
                if close + 1 < n && chars[close + 1].is("(") {
                    if let Some(paren) = first_from(")", close + 2) {
                        let url: String = chars[close + 2..paren].iter().map(|g| g.s.as_str()).collect();
                        out.raw("#link(\"");
                        out.raw(&escape_string(&url));
                        out.raw("\")[");
                        out.append(inline(&chars[i + 1..close]));
                        out.raw("]");
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        // \emph{…}, \textit{…}, \textbf{…}, \textsc{…}; other LaTeX commands are dropped.
        if c.is("\\") && next.map(|g| g.is_letter()) == Some(true) {
            let mut j = i + 1;
            while j < n && chars[j].is_letter() {
                j += 1;
            }
            let name: String = chars[i + 1..j].iter().map(|g| g.s.as_str()).collect();
            if j < n && chars[j].is("{") {
                if let Some(close) = first_from("}", j) {
                    let arg = inline(&chars[j + 1..close]);
                    match name.as_str() {
                        "emph" | "textit" => {
                            out.raw("#emph[");
                            out.append(arg);
                            out.raw("]");
                        }
                        "textbf" => {
                            out.raw("#strong[");
                            out.append(arg);
                            out.raw("]");
                        }
                        "textsc" => {
                            out.raw("#smallcaps[");
                            out.append(arg);
                            out.raw("]");
                        }
                        _ => out.append(arg),
                    }
                    i = close + 1;
                    continue;
                }
            }
            i = j;
            continue;
        }
        let e = escape(c, out.is_empty(), next);
        out.mapped(&e, c);
        i += 1;
    }
    out
}

/// One character of prose, escaped for Typst markup.
fn escape(c: &G, at_start: bool, next: Option<&G>) -> String {
    match c.s.as_str() {
        "\\" | "#" | "$" | "@" | "<" | ">" | "*" | "_" | "`" | "[" | "]" | "~" | "/" => format!("\\{}", c.s),
        "-" if next.map(|g| g.is("-")) == Some(true) || (at_start && next.map(|g| g.is(" ")) == Some(true)) => "\\-".into(),
        "=" if at_start => "\\=".into(),
        "+" if at_start => "\\+".into(),
        _ => c.s.clone(),
    }
}

pub fn escape_string(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn str_lit(s: &str) -> String {
    format!("\"{}\"", escape_string(s))
}

/// Inline Markdown of a title or a line of front matter, unmapped.
pub fn inline_plain(s: &str) -> String {
    inline(&graphemes(&mtext(s))).s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(md: &str) -> String {
        chapter(md, "c", false, SceneBreak::None, Lists::default()).s
    }

    fn with(md: &str, bullets: bool, numbered: bool) -> String {
        chapter(md, "c", false, SceneBreak::None, Lists { bullets, numbered }).s
    }

    #[test]
    fn bullets() {
        assert_eq!(src("- un\n\n- deux\n\nSuite."), "- un\n- deux\nSuite.\n\n");
        assert_eq!(src("+ un\n* deux\n"), "- un\n- deux\n");
        // Not bullets: a scene break, emphasis, a dialogue dash, stars.
        assert_eq!(src("* * *"), "#scenebreak()\n\n");
        assert_eq!(src("*mot* suite"), "#emph[mot] suite\n\n");
        assert_eq!(src("— Oui, dit-il."), "— Oui, dit-il.\n\n");
        assert_eq!(src("– Oui."), "– Oui.\n\n");
        assert_eq!(src("* *"), "\\* \\*\n\n");
        // Nested by its white space, under an item only, one level at a time.
        assert_eq!(src("- un\n  - deux\n    - trois\n        - quatre\n- cinq"), "- un\n  - deux\n  - trois\n    - quatre\n- cinq\n");
        assert_eq!(src("    - seul"), "- seul\n");
        assert_eq!(src("Texte.\n\n    - seul"), "Texte.\n\n- seul\n");
        // A book without bullet lists: a dash opens a paragraph.
        assert_eq!(with("- un\n- deux", false, false), "\\- un\n\n\\- deux\n\n");
        assert_eq!(with("* un", false, false), "\\* un\n\n");
    }

    #[test]
    fn numbered_lists_are_the_books_to_ask_for() {
        let list = "1. un\n\n2. deux\n\n3. trois\n\nSuite.";
        assert_eq!(src(list), "1\\. un\n\n2\\. deux\n\n3\\. trois\n\nSuite.\n\n", "off: as it always was");
        assert_eq!(with(list, true, true), "1. un\n+ deux\n+ trois\nSuite.\n\n");
        assert_eq!(with("1) un\n2) deux", true, true), "1. un\n+ deux\n");
        // The list counts from its first item, whatever was typed after it.
        assert_eq!(with("1. un\n1. deux\n7. trois", true, true), "1. un\n+ deux\n+ trois\n");
        // A sentence that opens on a number stays one, on or off, alone or among others.
        for on in [false, true] {
            assert_eq!(with("1943. Barcelone.", true, on), "1943\\. Barcelone.\n\n");
            assert_eq!(with("Avant.\n\n1943. Barcelone.\n\n1944. Madrid.", true, on), "Avant.\n\n1943\\. Barcelone.\n\n1944\\. Madrid.\n\n");
            assert_eq!(with("36. Guerre.\n\n39. Défaite.", true, on), "36\\. Guerre.\n\n39\\. Défaite.\n\n");
        }
        // Even right after a list: four digits are a year.
        assert_eq!(with("1. un\n1943. Barcelone.", true, true), "1. un\n1943\\. Barcelone.\n\n");
        // Nested, and a bullet list inside a numbered one; the outer list counts on after it.
        assert_eq!(with("1. un\n    1. a\n    2. b\n    - c\n2. deux", true, true), "1. un\n  1. a\n  + b\n  - c\n+ deux\n");
        // A new list starts again at its own number.
        assert_eq!(with("1. un\n2. deux\n\nTexte.\n\n1. trois", true, true), "1. un\n+ deux\nTexte.\n\n1. trois\n");
        // An item's own text is escaped like any line's.
        assert_eq!(with("1. 1943. Barcelone.", true, true), "1. 1943\\. Barcelone.\n");
        // Numbered lists without bullet lists.
        assert_eq!(with("1. un\n- deux\n2. trois", false, true), "1. un\n\\- deux\n\n2\\. trois\n\n");
    }

    #[test]
    fn paragraphs_and_emphasis() {
        assert_eq!(src("# Titre\n\nUn *mot* et **deux**.\n"), "= Titre\n\nUn #emph[mot] et #strong[deux].\n\n");
        assert_eq!(src("1943. Barcelone."), "1943\\. Barcelone.\n\n");
        assert_eq!(src("Fin^[Une note *ici*]."), "Fin#footnote[Une note #emph[ici]].\n\n");
        assert_eq!(src("a -- b / c"), "a \\-- b \\/ c\n\n");
        assert_eq!(src("> une\\\n> deux"), "#quote(block: true)[une \\\ndeux]\n\n");
        assert_eq!(src("{++ajout++}reste {~~vieux~>neuf~~} {--ôté--}"), "reste vieux ôté\n\n");
        assert_eq!(src("<!-- note -->Texte"), "Texte\n\n");
        assert_eq!(src("Un\n\n* * *\n\nDeux"), "Un\n\n#scenebreak()\n\nDeux\n\n");
        assert_eq!(src("\\begin{center}\nX\n\\end{center}"), "#align(center)[\nX\n\n]\n\n");
    }

    #[test]
    fn map_points_back_to_markdown() {
        let md = "Il dit *bonjour* à Ève.";
        let f = chapter(md, "c", false, SceneBreak::None, Lists::default());
        let u16: Vec<u16> = md.encode_utf16().collect();
        // Every mapped run shows the character it maps to.
        for (a, b, m, l) in &f.map {
            let shown = &f.s[*a as usize..*b as usize];
            let orig = String::from_utf16(&u16[*m as usize..(*m + *l) as usize]).unwrap();
            assert!(shown.ends_with(&orig), "{shown:?} vs {orig:?}");
        }
        assert_eq!(f.plain, "Il dit bonjour à Ève.");
    }

    #[test]
    fn scenes_and_comments() {
        let md = "<!-- scène : Un -->\nA\n<!-- scene: Deux -->\nB";
        assert_eq!(chapter(md, "c", false, SceneBreak::Asterism, Lists::default()).s, "A\n\n#asterism()\n\nB\n\n");
        assert_eq!(src("A <!-- long\ncomment --> B"), "A\n\nB\n\n");
    }
}
