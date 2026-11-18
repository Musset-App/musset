//! The engine on a small book: pages, the text map, footnotes, reflow.
use musset_typeset::document::{ChapterSpec, Layout, Spec};
use musset_typeset::Book;

fn spec(chapters: &[(&str, &str)], paper: (&str, &str)) -> Spec {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/..");
    Spec {
        template: std::fs::read_to_string(format!("{root}/Musset/Resources/Typst/musset.typ")).unwrap(),
        style: "book".into(),
        title: "Essai".into(),
        author: "Musset".into(),
        contact: None,
        lang: "fr".into(),
        layout: Layout { paper: Some((paper.0.into(), paper.1.into())), title_page: false, ..Default::default() },
        chapters: chapters.iter().map(|(id, md)| ChapterSpec { id: id.to_string(), markdown: md.to_string(), part: None, opening: None }).collect(),
        pages: Default::default(),
        scene_break: None,
        markers: false,
        font_dirs: vec![format!("{root}/Musset/Resources/Fonts")],
        system_fonts: Some(false),
        resource_dir: None,
        form: None,
        text: Default::default(),
    }
}

fn shown(book: &Book, spec: &Spec, page: usize) -> String {
    let mut s = String::new();
    for g in &book.pages[page].glyphs {
        if g.footnote >= 0 {
            continue;
        }
        let md: Vec<u16> = spec.chapters[g.chapter as usize].markdown.encode_utf16().collect();
        s += &String::from_utf16_lossy(&md[g.start as usize..g.end as usize]);
    }
    s
}

#[test]
fn text_map_points_at_the_words() {
    let md = "# Un\n\nLe *chat* dort sur la « table » du salon^[Une note.], près de l’âtre.\n";
    let sp = spec(&[("un", md)], ("120mm", "188mm"));
    let book = Book::compile(&sp).unwrap();
    let text = shown(&book, &sp, 0);
    assert!(text.contains("chat dort sur la"), "{text}");
    // The glyphs of « chat » cover exactly the word, not its asterisks.
    let u: Vec<u16> = md.encode_utf16().collect();
    let at = String::from_utf16(&u).unwrap().find("chat").unwrap();
    let start = md[..at].encode_utf16().count() as i32;
    let cat: Vec<_> = book.pages[0].glyphs.iter().filter(|g| g.start >= start && g.end <= start + 4).collect();
    assert_eq!(cat.len(), 4);
    // The footnote: its number in the text and at the foot, its text in the list.
    let marks: Vec<_> = book.pages[0].glyphs.iter().filter(|g| g.footnote == 0).map(|g| g.baseline).collect();
    assert!(marks.len() >= 2 && marks.iter().any(|y| (y - marks[0]).abs() > 20.0), "the number in the text and at the foot: {marks:?}");
    assert_eq!(book.footnotes[0].text, "Une note.");
}

#[test]
fn reflow_keeps_the_place() {
    let para = "Il marchait le long du quai, sans hâte, regardant les péniches et les pêcheurs qui ne prenaient rien. ";
    let md = format!("# Deux\n\n{}\n\nLe mot repère est ici.\n\n{}\n", para.repeat(40), para.repeat(40));
    let at = md.find("repère").unwrap();
    let offset = md[..at].encode_utf16().count() as i32;
    for paper in [("120mm", "188mm"), ("90mm", "140mm"), ("200mm", "150mm")] {
        let sp = spec(&[("deux", &md)], paper);
        let book = Book::compile(&sp).unwrap();
        let page = book.locate(0, offset);
        assert!(shown(&book, &sp, page).contains("repère"), "{paper:?}: page {page} lacks the anchor");
    }
    // A chapter's very start is its opening page, not the end of the chapter before.
    let sp = spec(&[("un", &md), ("deux", "# Trois\n\nAutre chapitre.\n")], ("120mm", "188mm"));
    let book = Book::compile(&sp).unwrap();
    let page = book.locate(1, 0);
    assert!(shown(&book, &sp, page).contains("Autre chapitre"), "chapter two opens on page {page}");
}

/// On the fixture books (when present): every glyph is mapped to the characters it shows, give or take what
/// typography makes of them (curly quotes, an ellipsis).
#[test]
fn every_glyph_shows_its_characters() {
    let mut dir = std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/.."));
    let fixtures = loop {
        if dir.join("fixtures/conatus").exists() {
            break dir.join("fixtures");
        }
        if !dir.pop() {
            eprintln!("no fixtures: skipped");
            return;
        }
    };
    let same = |shown: &str, md: &str| -> bool {
        let norm = |s: &str| s.replace(['’', '‘'], "'").replace(['“', '”'], "\"").replace('…', "...");
        let quote = |s: &str| matches!(s, "\"" | "'");
        norm(shown) == norm(md)
            || (shown == "…" && md == ".")
            // French quotes, and the narrow space Typst sets inside them, for a typed quote.
            || (quote(md) && matches!(shown, "«" | "»" | "‹" | "›" | "\u{202f}" | "\u{a0}"))
    };
    for book in ["brainiacs", "europa", "conatus"] {
        let d = fixtures.join(book);
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        let mut files: Vec<String> = entries.filter_map(|e| e.ok()).map(|e| e.file_name().into_string().unwrap())
            .filter(|f| f.ends_with(".md") && f.starts_with(|c: char| c.is_ascii_digit())).collect();
        files.sort();
        let chapters: Vec<(String, String)> = files.iter().map(|f| (f.clone(), std::fs::read_to_string(d.join(f)).unwrap())).collect();
        let refs: Vec<(&str, &str)> = chapters.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
        let sp = spec(&refs, ("130mm", "200mm"));
        let b = Book::compile(&sp).unwrap();
        let mds: Vec<Vec<u16>> = sp.chapters.iter().map(|c| c.markdown.encode_utf16().collect()).collect();
        let mut bad = vec![];
        for (pi, p) in b.pages.iter().enumerate() {
            for (g, shown) in p.glyphs.iter().zip(&p.shown).filter(|(g, _)| g.footnote < 0) {
                let md = String::from_utf16_lossy(&mds[g.chapter as usize][g.start as usize..g.end as usize]);
                if !same(shown, &md) {
                    bad.push(format!("{book} p{} {shown:?}→{md:?} @{}", pi + 1, g.start));
                }
            }
        }
        assert!(bad.is_empty(), "{} glyphs mapped elsewhere: {:?}", bad.len(), &bad[..bad.len().min(12)]);
    }
}

#[test]
fn special_pages_stand_around_the_chapters() {
    use musset_typeset::document::{Cover, Epigraph, Pages, TitlePage, Titled};
    let mut sp = spec(&[("un", "# Un\n\nLe texte.\n")], ("120mm", "188mm"));
    sp.title = "Le Sel & l’Écume".into();
    sp.author = "Jeanne Martin".into();
    sp.pages = Pages {
        cover: Some(Cover { style: "typographic".into(), genre: "roman".into(), publisher: "Le Quai".into(), ground: "#F3EEE2".into(), accent: "#9B2F26".into(), image: None }),
        title_page: Some(TitlePage { subtitle: Some("un été".into()), contact: None }),
        dedication: Some("À ceux qui restent,\net à ceux qui partent.".into()),
        epigraph: Some(Epigraph { text: "Persévérer dans son être.".into(), source: Some("Spinoza, *Éthique*".into()) }),
        contents: Some("Table".into()),
        acknowledgements: Some(Titled { title: "Remerciements".into(), text: "Merci à Louise.\nEt à Paul.\n\nMerci aussi.".into() }),
        colophon: Some("Achevé d’imprimer en 2026.\nComposé avec Musset.".into()),
    };
    let book = Book::compile(&sp).unwrap();
    let s = &book.source;
    let at = |needle: &str| s.find(needle).unwrap_or_else(|| panic!("{needle} is not in\n{s}"));
    // Cover, title page, dedication, epigraph, contents, the chapter, acknowledgements, colophon.
    let order = [
        at("JEANNE MARTIN"),
        at("smallcaps[Le Sel & l’Écume]"),
        at("#emph[À ceux qui restent, \\\net à ceux qui partent.]"),
        at("#text(size: 0.9em)[Spinoza, #emph[Éthique]]"),
        at("#outline(title: none, depth: 1)"),
        at("= Un"),
        at("Merci à Louise. Et à Paul.\n\nMerci aussi."),
        at("Achevé d’imprimer en 2026. \\\nComposé avec Musset."),
    ];
    assert!(order.windows(2).all(|w| w[0] < w[1]), "{order:?}");
    // Each on a page of its own: eight pages before the chapter's (the cover's verso stays blank on facing pages or not).
    assert!(book.pages.len() >= 8, "{} pages", book.pages.len());
}

#[test]
fn the_pdf_is_the_pages_read() {
    let para = "Il marchait le long du quai, sans hâte, regardant les péniches et les pêcheurs qui ne prenaient rien. ";
    let sp = spec(&[("un", &format!("# Un\n\n{}\n", para.repeat(60)))], ("120mm", "188mm"));
    let book = Book::compile(&sp).unwrap();
    let pdf = musset_typeset::engine::pdf(&sp).unwrap();
    assert!(pdf.starts_with(b"%PDF-"));
    // One page object per composed page.
    let text = String::from_utf8_lossy(&pdf);
    let pages = text.matches("/Type /Page\n").count() + text.matches("/Type /Page ").count() + text.matches("/Type/Page/").count();
    assert!(book.pages.len() > 1);
    assert!(pages == 0 || pages == book.pages.len(), "{pages} page objects for {} pages", book.pages.len());
    assert!(pdf.len() > 10_000);
}

// MARK: A book with a form of its own

use musset_typeset::document::{Form, Opening};

fn opening(label: Option<&str>, title: Option<&str>) -> Option<Opening> {
    Some(Opening { label: label.map(str::to_string), title: title.map(str::to_string) })
}

/// A book without a form is composed as it always was, to the byte: nothing of a formed book's is called.
#[test]
fn a_book_without_a_form_is_composed_as_before() {
    let mut sp = spec(&[("un", "# Un\n\nLe texte.\n"), ("deux", "# Deux\n\nLa suite.\n")], ("120mm", "188mm"));
    sp.chapters[1].part = Some(("II".into(), "La fuite".into()));
    sp.pages.contents = Some("Table".into());
    let book = Book::compile(&sp).unwrap();
    assert_eq!(
        book.source,
        "#import \"musset.typ\": *\n\
         #show: book.with(title: \"Essai\", author: \"Musset\", contact: none, lang: \"fr\", region: \"FR\", crop: false, paper: (120mm, 188mm), title-page-on: false)\n\n\
         #page(header: none, footer: none)[#nofolio()#align(center)[#text(size: 1.3em)[Table]]#v(2em)#outline(title: none, depth: 1)]\n\n\
         = Un\n\nLe texte.\n\n\n\
         #part-page(\"II\", \"La fuite\")\n\n\
         = Deux\n\nLa suite.\n\n\n"
    );
    // A form that says nothing changes the contents page alone.
    sp.form = Some(Form::default());
    let formed = Book::compile(&sp).unwrap();
    assert_eq!(formed.source, book.source.replace("#outline(title: none, depth: 1)", "#book-contents()"));
    assert_eq!(formed.pages.len(), book.pages.len());
}

/// A play: the acts and the scenes come named and numbered, and are written as given; a text without a heading
/// opens under the title it is given, or under its label alone.
#[test]
fn a_formed_book_opens_under_the_lines_it_is_given() {
    let mut sp = spec(
        &[("p", "Avant le rideau.\n"), ("a", "# Le salon\n\nElle entre.\n"), ("b", "Il sort.\n"), ("c", "# La rue\n\nNuit.\n")],
        ("120mm", "188mm"),
    );
    sp.form = Some(Form::default());
    sp.pages.contents = Some("Table".into());
    sp.chapters[0].opening = opening(Some("Prologue"), None);
    sp.chapters[1].opening = opening(Some("Scène 1"), None);
    sp.chapters[1].part = Some(("Acte I".into(), "".into()));
    sp.chapters[2].opening = opening(Some("Scène 2"), Some("L’adieu"));
    sp.chapters[3].opening = opening(None, None);
    sp.chapters[3].part = Some(("Acte II".into(), "La fuite".into()));
    let book = Book::compile(&sp).unwrap();
    let s = &book.source;
    assert!(s.contains("#book-contents()") && !s.contains("#outline("), "{s}");
    assert!(s.contains("#piece-label.update(none)\n= Prologue\n\nAvant le rideau."), "its kind is its title: {s}");
    assert!(s.contains("#group-mark(\"Acte I\", \"\")\n#part-page(\"Acte I\", \"\")\n\n#piece-label.update(\"Scène 1\")\n= Le salon"), "{s}");
    assert!(s.contains("#piece-label.update(\"Scène 2\")\n= L’adieu\n\nIl sort."), "{s}");
    assert!(s.contains("#group-mark(\"Acte II\", \"La fuite\")\n#part-page(\"Acte II\", \"La fuite\")\n\n#piece-label.update(none)\n= La rue"), "{s}");
    assert!(!s.contains("-opens.update"), "the usual openings are the template's own");
    // The map still points at the words (what is added before a chapter shifts it), each piece on a page of its own.
    let at: Vec<usize> = ["Avant le rideau", "Elle entre", "Il sort", "Nuit"]
        .iter()
        .map(|word| (0..book.pages.len()).find(|p| shown(&book, &sp, *p).contains(word)).unwrap_or_else(|| panic!("{word} is on no page")))
        .collect();
    assert!(at.windows(2).all(|w| w[0] < w[1]), "{at:?}");
}

/// Where the pieces open: each on the next page as always, each on a right-hand page, or one after the other in
/// the page. A group in the page is a heading only when its pieces run on too.
#[test]
fn pieces_open_where_the_form_says() {
    let pages = |piece: Option<&str>, group: Option<&str>| -> (Vec<usize>, usize, String) {
        let mut sp = spec(&[("a", "# A\n\nUn.\n"), ("b", "# B\n\nDeux.\n"), ("c", "# C\n\nTrois.\n")], ("120mm", "188mm"));
        sp.form = Some(Form { group_opens: group.map(str::to_string), piece_opens: piece.map(str::to_string) });
        for (i, ch) in sp.chapters.iter_mut().enumerate() {
            ch.opening = opening(Some(&format!("Fragment {}", i + 1)), None);
        }
        sp.chapters[1].part = Some(("II".into(), "".into()));
        let book = Book::compile(&sp).unwrap();
        ((0..3).map(|i| book.locate(i, 0)).collect(), book.pages.len(), book.source)
    };
    // Facing pages: the first piece on a recto, the part on the next recto, its piece behind it.
    assert_eq!(pages(None, None).0, [0, 3, 4]);
    assert_eq!(pages(Some("newPage"), Some("rightPage")).0, [0, 3, 4]);
    assert_eq!(pages(Some("rightPage"), None).0, [0, 4, 6], "every piece on a recto");
    assert_eq!(pages(None, Some("newPage")).0, [0, 2, 3], "the part on the next page, left or right");
    let (at, count, source) = pages(Some("inPage"), Some("inPage"));
    assert_eq!((at, count), (vec![0, 0, 0], 1), "one after the other in the page");
    assert!(source.contains("#group-opens.update(\"inPage\")\n#piece-opens.update(\"inPage\")\n#piece-label.update(\"Fragment 1\")"), "{source}");
    assert!(source.contains("#part-heading(\"II\", \"\")") && !source.contains("#part-page("), "{source}");
    let (at, _, source) = pages(Some("inPage"), None);
    assert_eq!(at, [0, 3, 3], "a part's page between pieces that run on");
    assert!(source.contains("#part-page(\"II\", \"\")"), "{source}");
    assert!(pages(None, Some("inPage")).2.contains("#part-page(\"II\", \"\")"), "pieces that take a page: the group has its own");
}

/// A template written before a book could choose its form sets a formed book too, its own way.
#[test]
fn an_older_template_sets_a_formed_book() {
    let mut sp = spec(&[("a", "# A\n\nUn.\n"), ("b", "Deux.\n")], ("120mm", "188mm"));
    sp.template = "#let nofolio() = none\n#let part-page(num, title) = [#num #title #pagebreak()]\n#let book(..args, body) = body\n".into();
    sp.form = Some(Form { group_opens: Some("inPage".into()), piece_opens: Some("inPage".into()) });
    sp.pages.contents = Some("Table".into());
    sp.chapters[0].opening = opening(Some("Chapitre 1"), None);
    sp.chapters[1].opening = opening(Some("Chapitre 2"), Some("B"));
    sp.chapters[1].part = Some(("Partie II".into(), "".into()));
    let book = Book::compile(&sp).unwrap_or_else(|e| panic!("{e}"));
    assert!(shown(&book, &sp, book.locate(1, 0)).contains("Deux"));
}

/// Lists and sections, in every layout: the page is composed, the list's words are on it, a sentence that opens
/// on a year stays in the text, and the contents list the sections only in a book that reads them so.
#[test]
fn lists_and_sections_are_the_books_to_ask_for() {
    use musset_typeset::document::{Manuscript, TextOptions};
    // A face the test machine lacks is not the lists' doing.
    let quiet = |b: &Book| b.warnings.iter().all(|w| w.contains("unknown font family"));
    let md = "# Un\n\nAvant la liste.\n\n- pommes\n\n    - reinettes\n\n    - goldens\n\n- poires\n\n1. semer\n\n2. arroser\n\n\
              1943. Barcelone.\n\n## Le verger\n\nSuite.\n\n### Les ruches\n\nFin.\n";
    let mut sp = spec(&[("un", md), ("deux", "# Deux\n\n## La cave\n\nTexte.\n")], ("120mm", "188mm"));
    sp.pages.contents = Some("Table".into());
    // As Musset always read a text: bullets, the numbers a sentence's, the contents one level deep.
    let plain = Book::compile(&sp).unwrap();
    assert!(plain.source.contains("- pommes\n  - reinettes\n  - goldens\n- poires\n1\\. semer\n\n2\\. arroser\n\n1943\\. Barcelone.\n\n"), "{}", plain.source);
    assert!(plain.source.contains("#outline(title: none, depth: 1)") && !plain.source.contains("contents-sections"), "{}", plain.source);

    sp.text = TextOptions { bullets: true, numbered: true, sections: true };
    let book = Book::compile(&sp).unwrap();
    assert!(quiet(&book), "{:?}", book.warnings);
    assert!(book.source.contains("- poires\n1. semer\n+ arroser\n1943\\. Barcelone.\n\n"), "{}", book.source);
    assert!(book.source.contains("outline(title: none, depth: 2)"), "{}", book.source);
    let all: String = (0..book.pages.len()).map(|p| shown(&book, &sp, p)).collect::<Vec<_>>().join("\n");
    for word in ["pommes", "goldens", "arroser", "1943. Barcelone.", "Le verger", "Les ruches"] {
        assert!(all.contains(word), "{word} is on no page");
    }
    // A formed book: its own contents list the sections under their piece, when asked.
    sp.form = Some(Form::default());
    for ch in &mut sp.chapters {
        ch.opening = opening(Some("Chapitre"), None);
    }
    let formed = Book::compile(&sp).unwrap();
    assert!(quiet(&formed), "{:?}", formed.warnings);
    assert!(formed.source.starts_with("#import \"musset.typ\": *\n#show: book.with(") && formed.source.contains(")\n\n#contents-sections.update(true)\n#page("), "{}", formed.source);
    sp.text.sections = false;
    assert!(!Book::compile(&sp).unwrap().source.contains("contents-sections"));
    sp.text.sections = true;

    // The same book as a manuscript and on a full page; with a template written before lists and sections.
    sp.style = "fullpage".into();
    assert!(quiet(&Book::compile(&sp).unwrap()));
    sp.style = "manuscript".into();
    sp.layout.manuscript = Some(Manuscript { args: "size: 12pt, pitch: 24pt".into(), running: "Musset / Essai".into(), count: "100 mots".into() });
    let ms = Book::compile(&sp).unwrap();
    assert!(quiet(&ms), "{:?}", ms.warnings);
    sp.style = "book".into();
    sp.layout.manuscript = None;
    let older = sp.template.replace("#let contents-sections", "#let unused-contents-sections").replace("contents-sections.get()", "false");
    assert!(!older.contains("#let contents-sections"));
    sp.template = older;
    assert!(Book::compile(&sp).is_ok(), "an older template still sets the book");
}
