//! The whole book as one Typst document (the style's call, the special pages, the chapters), and its source map.

use crate::markup::{self, inline_plain, str_lit, Frag, Lists, SceneBreak};
use serde::Deserialize;
use std::collections::BTreeMap;

/// What the engine is asked to compose. Sent as JSON through the C ABI.
#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Spec {
    /// The template's source (`Musset/Resources/Typst/musset.typ`, or the book's own `templates/musset.typ`).
    pub template: String,
    #[serde(default = "default_style")]
    pub style: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub contact: Option<String>,
    #[serde(default = "default_lang")]
    pub lang: String,
    #[serde(default)]
    pub layout: Layout,
    pub chapters: Vec<ChapterSpec>,
    /// The book's special pages, around the chapters. A manuscript has none.
    #[serde(default)]
    pub pages: Pages,
    /// "none", "blank" or "asterism".
    #[serde(default)]
    pub scene_break: Option<String>,
    /// Reading mode's paragraph markers (`#mk`), off for the export and the reader.
    #[serde(default)]
    pub markers: bool,
    /// Folders searched for fonts, first wins.
    #[serde(default)]
    pub font_dirs: Vec<String>,
    /// Also the fonts installed on the system (default: on macOS, off on iOS).
    #[serde(default)]
    pub system_fonts: Option<bool>,
    /// Where other files the source names (a cover image) are read from.
    #[serde(default)]
    pub resource_dir: Option<String>,
    /// A book with a form of its own: where its levels open. Absent, the book Musset always set.
    #[serde(default)]
    pub form: Option<Form>,
    /// What the book recognises in its text. Absent, what Musset always read: bullet lists.
    #[serde(default)]
    pub text: TextOptions,
}

/// What a book recognises in its pieces' text (Book Settings › Structure), whether or not it has a form of its own.
#[derive(Deserialize, Debug, Clone, Copy)]
#[serde(rename_all = "camelCase", default)]
pub struct TextOptions {
    /// « - », « + », « * » open a bullet item.
    pub bullets: bool,
    /// « 1. » opens a numbered list.
    pub numbered: bool,
    /// Sub-headings are sections: the contents list them under their piece.
    pub sections: bool,
}

impl Default for TextOptions {
    fn default() -> Self {
        TextOptions { bullets: true, numbered: false, sections: false }
    }
}

/// Where the levels of a book with a form of its own open: "rightPage", "newPage" or "inPage". The words and the
/// numbers come ready with each chapter (`ChapterSpec::opening`, `ChapterSpec::part`): nothing is named here.
#[derive(Deserialize, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Form {
    #[serde(default)]
    pub group_opens: Option<String>,
    #[serde(default)]
    pub piece_opens: Option<String>,
}

fn default_style() -> String {
    "book".into()
}
fn default_lang() -> String {
    "fr".into()
}

#[derive(Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    /// ("120mm", "188mm").
    pub paper: Option<(String, String)>,
    /// "inside" → "20mm"…
    pub margins: Option<BTreeMap<String, String>>,
    /// "10.8pt".
    pub size: Option<String>,
    #[serde(default)]
    pub crop: bool,
    #[serde(default = "yes")]
    pub numbered: bool,
    #[serde(default = "yes")]
    pub title_page: bool,
    #[serde(default = "yes")]
    pub facing: bool,
    /// A submission manuscript's norm: its arguments, running head and count.
    #[serde(default)]
    pub manuscript: Option<Manuscript>,
}

impl Default for Layout {
    fn default() -> Self {
        Layout { paper: None, margins: None, size: None, crop: false, numbered: true, title_page: true, facing: true, manuscript: None }
    }
}

fn yes() -> bool {
    true
}

/// The book's special pages: only those it has. Before the chapters, in this order: cover, title page, dedication,
/// epigraph, contents; after them: acknowledgements, colophon. Words Musset supplies (« Contents », the colophon)
/// come in the book's language.
#[derive(Deserialize, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Pages {
    #[serde(default)]
    pub cover: Option<Cover>,
    #[serde(default)]
    pub title_page: Option<TitlePage>,
    #[serde(default)]
    pub dedication: Option<String>,
    #[serde(default)]
    pub epigraph: Option<Epigraph>,
    /// The contents page's title.
    #[serde(default)]
    pub contents: Option<String>,
    #[serde(default)]
    pub acknowledgements: Option<Titled>,
    /// The colophon's lines.
    #[serde(default)]
    pub colophon: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Cover {
    /// "typographic", "image" or "plain".
    pub style: String,
    #[serde(default)]
    pub genre: String,
    #[serde(default)]
    pub publisher: String,
    pub ground: String,
    pub accent: String,
    /// The image's path in the resource folder, for the "image" style.
    #[serde(default)]
    pub image: Option<String>,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct TitlePage {
    #[serde(default)]
    pub subtitle: Option<String>,
    #[serde(default)]
    pub contact: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Epigraph {
    pub text: String,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Titled {
    pub title: String,
    pub text: String,
}

/// Lines of front matter, each its own line on the page.
fn lines(t: &str) -> String {
    t.trim().split(['\n', '\r']).map(inline_plain).collect::<Vec<_>>().join(" \\\n")
}

impl Pages {
    /// Typst for what goes before the chapters. The title page is laid here, after the cover, never by the template.
    /// `sections`: the contents list each piece's sections (`## `) under it.
    pub fn front(&self, title: &str, author: &str, formed: bool, sections: bool) -> String {
        let mut s = String::new();
        if let Some(c) = &self.cover {
            let plain = c.style == "plain";
            let accent = str_lit(if plain { "#1A1A18" } else { &c.accent });
            s += &format!(
                "#page(margin: 0pt, header: none, footer: none, fill: rgb({}))[\n#nofolio()\n",
                str_lit(if plain { "#FFFFFF" } else { &c.ground })
            );
            if let (true, Some(img)) = (c.style == "image", &c.image) {
                s += &format!("#place(top + left, image({}, width: 100%, height: 100%, fit: \"cover\"))\n", str_lit(img));
            }
            if c.style == "typographic" {
                s += &format!("#place(top + left, dx: 5%, dy: 3.5%, rect(width: 90%, height: 93%, stroke: 0.6pt + rgb({accent})))\n");
                s += &format!("#place(top + left, dx: 6.6%, dy: 4.6%, rect(width: 86.8%, height: 90.8%, stroke: 0.6pt + rgb({accent})))\n");
            }
            s += &format!(
                "#align(center)[#v(16%)#text(size: 0.95em, tracking: 0.18em)[{}]\n#v(11%)",
                inline_plain(&author.to_uppercase())
            );
            s += &format!("#text(size: 2.6em, fill: rgb({accent}))[{}]", inline_plain(title));
            if !c.genre.is_empty() {
                s += &format!("\n#v(0.8em)#text(style: \"italic\")[{}]", inline_plain(&c.genre));
            }
            s += "]\n";
            if !c.publisher.is_empty() {
                s += &format!(
                    "#place(bottom + center, dy: -9%, text(size: 0.7em, tracking: 0.18em)[{}])\n",
                    inline_plain(&c.publisher.to_uppercase())
                );
            }
            s += "]\n\n";
        }
        if let Some(t) = &self.title_page {
            s += &format!(
                "#page(header: none, footer: none)[#nofolio()#v(30%)#align(center)[#text(size: 1.25em, smallcaps[{}])",
                inline_plain(title)
            );
            if let Some(sub) = t.subtitle.as_deref().filter(|x| !x.is_empty()) {
                s += &format!("\n#v(4mm)#emph[{}]", inline_plain(sub));
            }
            s += &format!("\n#v(18mm){}", inline_plain(author));
            if let Some(contact) = t.contact.as_deref().filter(|x| !x.is_empty()) {
                s += &format!("\n#v(1fr)#text(size: 0.8em)[{}]", inline_plain(contact));
            }
            s += "]]\n\n";
        }
        if let Some(d) = &self.dedication {
            s += &format!("#page(header: none, footer: none)[#nofolio()#v(30%)#align(center)[#emph[{}]]]\n\n", lines(d));
        }
        if let Some(e) = &self.epigraph {
            s += &format!(
                "#page(header: none, footer: none)[#nofolio()#v(26%)#align(right)[#block(width: 72%)[#set align(right)\n#emph[{}]",
                lines(&e.text)
            );
            if let Some(src) = e.source.as_deref().filter(|x| !x.is_empty()) {
                s += &format!(" \\\n#v(0.5em)#text(size: 0.9em)[{}]", inline_plain(src));
            }
            s += "]]]\n\n";
        }
        if let Some(title) = &self.contents {
            // Its own title, not a heading: a heading would start a new right-hand page.
            // A book with a form of its own lists its groups and its pieces' labels too (the template's `book-contents`).
            let contents = match (formed, sections) {
                (true, _) => "book-contents()",
                (false, false) => "outline(title: none, depth: 1)",
                // A section under its piece: indented, without a number of its own.
                (false, true) => "{ show outline.entry.where(level: 2): it => link(it.element.location(), it.indented(none, it.inner())); outline(title: none, depth: 2) }",
            };
            s += &format!(
                "#page(header: none, footer: none)[#nofolio()#align(center)[#text(size: 1.3em)[{}]]#v(2em)#{}]\n\n",
                inline_plain(title),
                contents
            );
        }
        s
    }

    /// Typst for what goes after the chapters.
    pub fn back(&self) -> String {
        let mut s = String::new();
        if let Some(a) = &self.acknowledgements {
            s += &format!("#pagebreak()\n#align(center)[#text(size: 1.2em)[{}]]\n#v(2em)\n", inline_plain(&a.title));
            let paragraphs: Vec<String> = a.text.trim().split("\n\n").map(|p| inline_plain(&p.replace('\n', " "))).collect();
            s += &paragraphs.join("\n\n");
            s += "\n\n";
        }
        if let Some(c) = &self.colophon {
            s += &format!("#page(header: none, footer: none)[#nofolio()#v(1fr)#align(center)[#text(size: 0.8em)[{}]]#v(3em)]\n", lines(c));
        }
        s
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct Manuscript {
    pub args: String,
    pub running: String,
    pub count: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct ChapterSpec {
    pub id: String,
    pub markdown: String,
    /// A part's page before this chapter: (numeral, title).
    #[serde(default)]
    pub part: Option<(String, String)>,
    /// In a book with a form of its own: what the piece opens under. Absent, the chapter opens as it always did.
    #[serde(default)]
    pub opening: Option<Opening>,
}

/// A piece's opening as the book's form has it, in the book's words.
#[derive(Deserialize, Debug, Clone, Default)]
pub struct Opening {
    /// The line over the title: « Chapitre 3 », « Prologue ». None: the title alone.
    #[serde(default)]
    pub label: Option<String>,
    /// The title a text without a heading of its own opens under.
    #[serde(default)]
    pub title: Option<String>,
}

/// A run of the main source showing one character of a chapter.
#[derive(Clone, Copy, Debug)]
pub struct Entry {
    pub a: u32,
    pub b: u32,
    pub chapter: u32,
    pub m: u32,
    pub l: u32,
}

#[derive(Clone, Debug)]
pub struct Note {
    pub a: u32,
    pub b: u32,
    pub chapter: u32,
    pub m: u32,
    pub e: u32,
    pub text: String,
}

/// Inline code's string literal in the main source, and its characters (UTF-8 length in the code, chapter range).
#[derive(Clone, Debug)]
pub struct Raw {
    pub a: u32,
    pub b: u32,
    pub chapter: u32,
    pub items: Vec<(u32, u32, u32)>,
}

pub struct Composed {
    pub source: String,
    pub entries: Vec<Entry>,
    pub notes: Vec<Note>,
    pub raws: Vec<Raw>,
}

/// `BookLanguage(code:)`: a stored code as one of Musset's variants, as (language, region).
pub fn book_language(code: &str) -> (String, String) {
    let all = ["en-US", "en-GB", "fr-FR", "de-DE", "de-CH", "es-ES", "es-419", "it-IT", "pt-PT", "pt-BR"];
    let c = code.replace('_', "-").to_lowercase();
    let v = all.iter().find(|v| v.to_lowercase() == c).copied().unwrap_or_else(|| {
        match c.split('-').next().unwrap_or(&c) {
            "fr" => "fr-FR",
            "de" => {
                if c.ends_with("ch") {
                    "de-CH"
                } else {
                    "de-DE"
                }
            }
            "es" => {
                if c == "es-es" {
                    "es-ES"
                } else if c.chars().count() > 2 {
                    "es-419"
                } else {
                    "es-ES"
                }
            }
            "it" => "it-IT",
            "pt" => {
                if c.ends_with("br") {
                    "pt-BR"
                } else {
                    "pt-PT"
                }
            }
            _ => {
                if c.ends_with("gb") || c.ends_with("uk") {
                    "en-GB"
                } else {
                    "en-US"
                }
            }
        }
    });
    (v[..2].to_string(), v.rsplit('-').next().unwrap_or("").to_string())
}

/// The template as served: a template written before the styles were renamed gets the new names too.
pub fn template_source(own: &str) -> String {
    let mut t = own.to_string();
    for (new, old) in [("book", "blanche"), ("fullpage", "classique")] {
        if !t.contains(&format!("#let {new}(")) && t.contains(&format!("#let {old}(")) {
            t.push_str(&format!("\n#let {new} = {old}\n"));
        }
    }
    // A template written before a book could choose its form: what a formed book calls is there, and the pages
    // stay the template's own.
    for (name, definition) in [
        ("piece-label", "#let piece-label = state(\"musset-piece-label\", auto)"),
        ("piece-opens", "#let piece-opens = state(\"musset-piece-opens\", \"newPage\")"),
        ("group-opens", "#let group-opens = state(\"musset-group-opens\", \"rightPage\")"),
        ("group-mark", "#let group-mark(num, title) = none"),
        ("part-heading", "#let part-heading = part-page"),
        ("book-contents", "#let book-contents() = outline(title: none, depth: 1)"),
        ("contents-sections", "#let contents-sections = state(\"musset-contents-sections\", false)"),
    ] {
        if !t.contains(&format!("#let {name}")) {
            t.push_str(&format!("\n{definition}\n"));
        }
    }
    t
}

pub fn compose(spec: &Spec) -> Composed {
    let scene = match spec.scene_break.as_deref() {
        Some("blank") => SceneBreak::Blank,
        Some("asterism") => SceneBreak::Asterism,
        _ => SceneBreak::None,
    };
    let l = &spec.layout;
    let lists = Lists { bullets: spec.text.bullets, numbered: spec.text.numbered };
    let (base, region) = book_language(&spec.lang);
    let mut s = String::from("#import \"musset.typ\": *\n");
    s += &format!(
        "#show: {}.with(title: {}, author: {}, contact: {}, lang: {}, region: {}, crop: {}",
        spec.style,
        str_lit(&spec.title),
        str_lit(&spec.author),
        spec.contact.as_deref().map(str_lit).unwrap_or_else(|| "none".into()),
        str_lit(&base),
        str_lit(&region),
        l.crop
    );
    let mut out = Composed { source: String::new(), entries: vec![], notes: vec![], raws: vec![] };
    let push_chapter = |s: &mut String, out: &mut Composed, index: usize, ch: &ChapterSpec| {
        if index == 0 {
            // Where the levels open, said once before the first of them; the template's own are not repeated.
            for (state, opens, usual) in [
                ("group-opens", spec.form.as_ref().and_then(|f| f.group_opens.as_deref()), "rightPage"),
                ("piece-opens", spec.form.as_ref().and_then(|f| f.piece_opens.as_deref()), "newPage"),
            ] {
                if let Some(o) = opens.filter(|o| *o != usual) {
                    *s += &format!("#{state}.update({})\n", str_lit(o));
                }
            }
        }
        if let Some((num, title)) = &ch.part {
            if ch.opening.is_some() {
                // For the contents: a group is not a heading.
                *s += &format!("#group-mark({}, {})\n", str_lit(num), str_lit(title));
            }
            // A group in the page needs its pieces in the page too: before a piece that takes a page, it has its own.
            let opens = |o: Option<&String>| o.map(String::as_str) == Some("inPage");
            let running = spec.form.as_ref().is_some_and(|f| opens(f.group_opens.as_ref()) && opens(f.piece_opens.as_ref()));
            *s += &format!("#{}({}, {})\n\n", if running { "part-heading" } else { "part-page" }, str_lit(num), str_lit(title));
        }
        let f: Frag = markup::chapter(&ch.markdown, &ch.id, spec.markers, scene, lists);
        if let Some(o) = &ch.opening {
            let titled = f.s.starts_with("= ") || f.s.contains("\n= ");
            // A text without a heading opens under the title it is given, or under its label alone.
            let given = if titled { None } else { o.title.as_deref().or(o.label.as_deref()) };
            let label = if titled || o.title.is_some() { o.label.as_deref() } else { None };
            *s += &format!("#piece-label.update({})\n", label.map(str_lit).unwrap_or_else(|| "none".into()));
            if let Some(t) = given {
                *s += &format!("= {}\n\n", inline_plain(t));
            }
        }
        let shift = s.len() as u32;
        out.entries.extend(f.map.iter().map(|&(a, b, m, l)| Entry { a: a + shift, b: b + shift, chapter: index as u32, m, l }));
        out.notes.extend(f.notes.iter().map(|(a, b, m, e, t)| Note {
            a: a + shift,
            b: b + shift,
            chapter: index as u32,
            m: *m,
            e: *e,
            text: t.clone(),
        }));
        out.raws.extend(f.raws.iter().map(|(a, b, items)| Raw { a: a + shift, b: b + shift, chapter: index as u32, items: items.clone() }));
        *s += &f.s;
        *s += "\n";
    };
    if let Some(m) = &l.manuscript {
        s += &format!(", {}, running: {}, count: {}, numbered: {})\n\n", m.args, str_lit(&m.running), str_lit(&m.count), l.numbered);
        for (i, ch) in spec.chapters.iter().enumerate() {
            push_chapter(&mut s, &mut out, i, ch);
        }
        out.source = s;
        return out;
    }
    if let Some((w, h)) = &l.paper {
        s += &format!(", paper: ({w}, {h})");
    }
    if let Some(m) = &l.margins {
        let mut parts: Vec<String> = m.iter().map(|(k, v)| format!("{k}: {v}")).collect();
        parts.sort();
        s += &format!(", margins: ({})", parts.join(", "));
    }
    if let Some(size) = &l.size {
        s += &format!(", size: {size}");
    }
    if spec.style == "classique" || spec.style == "fullpage" {
        s += &format!(", numbered: {}", l.numbered);
    }
    if !l.title_page {
        s += ", title-page-on: false";
    }
    if !l.facing {
        s += ", facing: false";
    }
    s += ")\n\n";
    if spec.text.sections && spec.form.is_some() && spec.pages.contents.is_some() {
        // The formed book's contents (the template's `book-contents`) list the sections too.
        s += "#contents-sections.update(true)\n";
    }
    s += &spec.pages.front(&spec.title, &spec.author, spec.form.is_some(), spec.text.sections);
    for (i, ch) in spec.chapters.iter().enumerate() {
        push_chapter(&mut s, &mut out, i, ch);
    }
    s += &spec.pages.back();
    out.source = s;
    out
}
