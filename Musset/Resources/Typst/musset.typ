// Musset — book templates for Typst.
// `book`: a printed book, any trim (120 × 188 mm by default, EB Garamond 10.8/13, folio at the outer foot).
// `fullpage`: the same typography on a full page (A4 reading copy or home-printed submission), with a running head.
// `manuscript`: a country's submission manuscript.
// A book can override this file with its own templates/musset.typ.

/// No page number on the current page (LaTeX's \thispagestyle{empty}).
#let nofolio() = [#metadata(none)<nofolio>]
#let folio-hidden() = query(<nofolio>).any(m => m.location().page() == here().page())

/// What a scene break shows: Musset's asterisk, or a manuscript's own mark ("#" in a Shunn manuscript).
#let scene-mark = state("musset-scene-mark", none)

/// Scene break (* * *, ---).
#let scenebreak() = context {
  let m = scene-mark.get()
  if m == none { align(center, block(above: 1.2em, below: 1.2em, text(tracking: 0.6em)[\*])) }
  else { align(center, block(above: 0pt, below: 0pt, m)) }
}

/// Between two scenes (Musset's `<!-- scene: … -->` markers): a blank line, or an asterism.
#let scenegap() = v(1.2em)
/// Facing pages (a printed book: inside and outside margins, rectos on the right) or single pages (a manuscript,
/// a PDF on screen: the same margin left and right, no blank verso).
#let facing-pages = state("musset-facing", true)

/// A book with a form of its own (a play, a collection, fragments…): Musset says, before each piece, the line it
/// opens under (« Chapitre 3 », « Prologue », or none for the title alone), and once where the levels open:
/// "rightPage", "newPage" or "inPage". Left as they are, a book is set as Musset always set one.
#let piece-label = state("musset-piece-label", auto)
#let piece-opens = state("musset-piece-opens", "newPage")
#let group-opens = state("musset-group-opens", "rightPage")

// A part's own page, recto in a book: its numeral, its title below, no folio.
// In a formed book: the group's line (« Acte II »), on a right-hand page or on the next page.
#let part-page(num, title) = {
  context pagebreak(weak: true, to: if facing-pages.get() and group-opens.get() == "rightPage" { "odd" } else { none })
  nofolio()
  v(1fr)
  align(center)[
    #text(size: 1.8em, tracking: 0.08em, num)
    #if title != "" { v(0.8em); text(size: 1.15em, style: "italic", title) }
  ]
  v(2fr)
  pagebreak()
}

/// A group that opens in the page, in a book whose pieces run on in the page too: a heading, and the text goes on.
#let part-heading(num, title) = {
  v(3em, weak: true)
  align(center, block(below: 1.6em, sticky: true)[
    #text(size: 1.4em, tracking: 0.08em, num)
    #if title != "" { v(0.6em); text(size: 1.1em, style: "italic", title) }
  ])
}

/// Where a group begins, for the contents of a formed book: a group is a page, not a heading.
#let group-mark(num, title) = [#metadata((num: num, title: title))<musset-group>]

/// Whether the contents list each piece's sections (its `## ` sub-headings): said once, in a book that reads them so.
#let contents-sections = state("musset-contents-sections", false)

/// The contents of a formed book: its groups, each piece under the line it opens with, and its sections if asked.
#let book-contents() = context {
  set par(first-line-indent: 0pt, justify: false)
  let listed = selector(heading.where(level: 1)).or(<musset-group>)
  for it in query(if contents-sections.get() { listed.or(heading.where(level: 2)) } else { listed }) {
    let loc = it.location()
    if it.func() == metadata {
      block(above: 1.5em, below: 0.8em, sticky: true)[#smallcaps(it.value.num)#if it.value.title != "" [ · #emph(it.value.title)]]
    } else if it.level == 2 {
      block(above: 0.55em, below: 0.55em, inset: (left: 1.4em), link(loc)[#it.body #box(width: 1fr, repeat(gap: 0.15em)[.]) #loc.page()])
    } else {
      let label = piece-label.at(loc)
      block(above: 0.7em, below: 0.7em, link(loc)[#if label != auto and label != none [#label · ]#it.body #box(width: 1fr, repeat(gap: 0.15em)[.]) #loc.page()])
    }
  }
}

#let asterism() = align(center, block(above: 1.2em, below: 1.2em)[⁂])

/// Lists in the text: in the body's face, the marker at the paragraph's indent, the lines hanging under the text,
/// the items a line apart like the lines of a paragraph, and `gap` between the list and the text around it.
/// A list inside an item is told by the items' spacing, set there: it takes no gap of its own.
#let text-lists(indent, leading, gap, body) = {
  set list(indent: indent, body-indent: 0.5em)
  set enum(indent: indent, body-indent: 0.5em)
  let apart(it) = context {
    if list.spacing == auto and enum.spacing == auto {
      block(above: gap, below: gap, {
        set list(indent: 0.2em, spacing: leading)
        set enum(indent: 0.2em, spacing: leading)
        it
      })
    } else { it }
  }
  show list: apart
  show enum: apart
  body
}

/// Invisible marker at the start of each paragraph: lets Musset map a page position back to the text.
#let mk(ch, off) = context [#metadata((ch: ch, off: off, page: here().page(), y: here().position().y.pt()))<musset>]

/// Crop marks at the trim corners, drawn in the slug area around the trimmed page.
#let crop-marks(slug) = {
  let len = slug - 2mm
  let stroke = 0.3pt + black
  for (x, y, dx, dy) in ((0, 0, -1, -1), (1, 0, 1, -1), (0, 1, -1, 1), (1, 1, 1, 1)) {
    let px = if x == 0 { slug } else { 100% - slug }
    let py = if y == 0 { slug } else { 100% - slug }
    place(top + left, dx: px, dy: py - (if dy < 0 { len + 1mm } else { -1mm }), line(length: len, angle: 90deg, stroke: stroke))
    place(top + left, dx: px - (if dx < 0 { len + 1mm } else { -1mm }), dy: py, line(length: len, stroke: stroke))
  }
}

/// Page setup shared by both styles: trim size, margins, optional slug with crop marks.
#let page-setup(paper, margins, crop, footer, header, facing: true) = {
  let slug = if crop { 12mm } else { 0mm }
  let margins = margins
  if not facing {
    // Single pages: the two side margins become one, halfway between them.
    let a = margins.at("inside", default: margins.at("left", default: none))
    let b = margins.at("outside", default: margins.at("right", default: none))
    if a != none and b != none {
      let kept = (:)
      for (k, v) in margins { if k not in ("inside", "outside", "left", "right") { kept.insert(k, v) } }
      kept.insert("left", (a + b) / 2)
      kept.insert("right", (a + b) / 2)
      margins = kept
    }
  }
  let m = (:)
  for (k, v) in margins { m.insert(k, v + slug) }
  (
    width: paper.at(0) + 2 * slug,
    height: paper.at(1) + 2 * slug,
    margin: m,
    background: if crop { crop-marks(slug) } else { none },
    footer: footer,
    header: header,
  )
}

#let title-page(title, author, contact, size) = {
  page(header: none, footer: none)[
    #v(30%)
    #align(center)[
      #text(size: size * 1.25, smallcaps(title))
      #v(18mm)
      #if author != none { text(size: size, author) }
      #if contact != none { v(1fr); text(size: size * 0.8, contact) }
    ]
  ]
}

/// A chapter's opening, shared by both styles: sunk a tenth of the way down the page, its number (if any) in
/// old-style figures, its title in small caps at the text size.
/// In a printed book (facing pages) the first chapter opens on a recto, after the front matter's blank versos.
/// In a formed book the line over the title is the piece's own (« Scène 2 », « Prologue »), every piece can open on
/// a recto, and pieces that open in the page follow each other after a gap (the first still opens the text).
#let chapter-opening(it, size, sink, gap) = context {
  let first = query(heading.where(level: 1)).first().location() == it.location()
  let opens = piece-opens.get()
  let label = piece-label.get()
  let running = opens == "inPage" and not first
  if not running {
    pagebreak(weak: true, to: if facing-pages.get() and (first or opens == "rightPage") { "odd" } else { none })
    v(sink)
  } else {
    v(size * 2.8, weak: true)
  }
  align(center, block(below: if running { size * 1.6 } else { gap }, sticky: running)[
    #set text(size: size, weight: "regular")
    #if label == auto { if it.numbering != none { text(tracking: 0.08em, counter(heading).display("1")); v(0.9em) } } else if label != none { text(tracking: 0.08em, label); v(0.9em) }
    #smallcaps(it.body)
  ])
}

/// A printed book, the French literary way (any trim): EB Garamond, line spacing 1.2, a small indent on every
/// paragraph, chapter titles in small caps a tenth of the way down, old-style figures, the folio at the outer foot
/// and no running head. The default page is 120 × 188 mm at 10.8/13.
#let book(
  title: none, author: none, contact: none, lang: "fr", region: none,
  paper: (120mm, 188mm),
  margins: (inside: 20mm, outside: 14mm, top: 16mm, bottom: 20mm),
  size: 10.8pt, line-height: none, indent: none,
  font: ("EB Garamond 12", "EB Garamond", "Libertinus Serif"),
  numbered: false, crop: false, title-page-on: true, facing: true,
  body,
) = {
  let lh = if line-height == none { size * 1.2 } else { line-height }
  let indent = if indent == none { size * 1.05 } else { indent }
  set document(title: title, author: if author != none { author } else { () })
  facing-pages.update(facing)
  set page(..page-setup(paper, margins, crop,
    context {
      let n = here().page()
      // No folio before the text starts: the front matter, and the blank verso facing the first chapter.
      let opening = query(heading.where(level: 1)).map(h => h.location().page()).at(0, default: 0)
      if not folio-hidden() and n >= opening {
        align(if not facing { center } else if calc.even(n) { left } else { right }, text(size: size, number-type: "old-style")[#n])
      }
    }, none, facing: facing))
  set text(font: font, size: size, lang: lang, region: region, number-type: "old-style", hyphenate: true)
  set par(justify: true, linebreaks: "optimized", leading: lh - size * 0.65, spacing: lh - size * 0.65,
    first-line-indent: (amount: indent, all: lang == "fr"))
  set heading(numbering: if numbered { "1" } else { none })
  show heading.where(level: 1): it => chapter-opening(it, size, paper.at(1) * 0.096, paper.at(1) * 0.075)
  show heading.where(level: 2): it => align(center, block(above: 1.4em, below: 1em, text(size: size, weight: "regular", smallcaps(it.body))))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: indent * 2, right: indent, text(size: size * 0.95, it.body))
  show: text-lists.with(indent, lh - size * 0.65, lh * 0.5 + (lh - size * 0.65))
  if title != none and title-page-on { title-page(title, author, contact, size) }
  body
}

/// A full page (A4 by default): a reading copy or a submission printed at home, with the book's typography —
/// small-caps chapter titles and running head, old-style figures, folio centred at the foot — on a roomier leading.
#let fullpage(
  title: none, author: none, contact: none, lang: "fr", region: none,
  paper: (210mm, 297mm),
  margins: (left: 30mm, right: 30mm, top: 25mm, bottom: 30mm),
  size: 11pt, line-height: none, indent: none,
  font: ("EB Garamond 12", "EB Garamond", "Libertinus Serif"),
  numbered: true, crop: false, title-page-on: true, facing: true,
  body,
) = {
  let lh = if line-height == none { size * 1.45 } else { line-height }
  let indent = if indent == none { size * 1.05 } else { indent }
  set document(title: title, author: if author != none { author } else { () })
  facing-pages.update(facing)
  set page(..page-setup(paper, margins, crop,
    context if not folio-hidden() { align(center, text(size: size * 0.9, number-type: "old-style")[#here().page()]) },
    context {
      let before = query(heading.where(level: 1).before(here()))
      let starts = query(heading.where(level: 1)).any(h => h.location().page() == here().page())
      // Pieces that open in the page start on most pages: the head names the one the page begins in.
      if before.len() > 0 and (not starts or piece-opens.get() == "inPage") and not folio-hidden() {
        align(center, text(size: size * 0.9, tracking: 0.04em, smallcaps(before.last().body)))
      }
    }, facing: facing))
  set text(font: font, size: size, lang: lang, region: region, number-type: "old-style", hyphenate: true)
  set par(justify: true, linebreaks: "optimized", leading: lh - size * 0.65, spacing: lh - size * 0.65,
    first-line-indent: (amount: indent, all: lang == "fr"))
  set heading(numbering: if numbered { "1" } else { none })
  show heading.where(level: 1): it => chapter-opening(it, size, paper.at(1) * 0.096, paper.at(1) * 0.06)
  show heading.where(level: 2): it => align(center, block(above: 1.4em, below: 1em, text(size: size, weight: "regular", smallcaps(it.body))))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: indent * 2, right: indent, text(size: size * 0.95, it.body))
  show: text-lists.with(indent, lh - size * 0.65, lh * 0.5 + (lh - size * 0.65))
  if title != none and title-page-on { title-page(title, author, contact, size) }
  body
}

// The names these styles had before (books whose own templates/musset.typ or older exports still call them).
#let blanche = book
#let classique = fullpage

/// A manuscript for submission, by the conventions of its country:
/// - `lines`/`chars`: a fixed grid, in a monospaced face (German Normseite and Italian cartella 30 × 60);
/// - `shunn`: the English standard manuscript (contact block and word count on page one, "Surname / TITLE / page" header,
///   chapters a third of the way down, "#" between scenes);
/// - otherwise a plain page: a serif at 12 pt, the line spacing asked for, ragged right.
#let manuscript(
  title: none, author: none, contact: none, lang: "en", region: none,
  paper: (210mm, 297mm), margins: (left: 25mm, right: 25mm, top: 25mm, bottom: 25mm),
  font: ("Times New Roman", "Libertinus Serif"), size: 12pt, pitch: 24pt,
  lines: none, chars: none,
  indent: 1.25cm, justify: false,
  running: none, shunn: false, count: none,
  numbered: false, crop: false, title-page-on: true, facing: false,
  body,
) = {
  let leading = pitch - size
  // A fixed grid sets the text block from the norm: chars × an em's 0.6 (Courier's advance), lines × pitch.
  let ml = margins.at("left", default: 25mm)
  let mt = margins.at("top", default: 25mm)
  let mr = if chars != none { paper.at(0) - ml - chars * size * 0.6 } else { margins.at("right", default: 25mm) }
  let mb = if lines != none { paper.at(1) - mt - (lines * pitch - leading) - 0.5pt } else { margins.at("bottom", default: 25mm) }
  set document(title: title, author: if author != none { author } else { () })
  facing-pages.update(false)
  if shunn { scene-mark.update(text("#")) }
  set page(
    width: paper.at(0), height: paper.at(1),
    margin: (left: ml, right: mr, top: mt, bottom: mb),
    header: context {
      if here().page() > 1 and not folio-hidden() {
        set text(size: size)
        if shunn { align(right, [#running / #here().page()]) }
        else { grid(columns: (1fr, auto), running, [#here().page()]) }
      }
    },
    footer: none,
  )
  // A full grid page: no line held back for widows and orphans.
  set text(font: font, size: size, lang: lang, region: region, hyphenate: false, number-type: "lining", top-edge: 0.8em, bottom-edge: -0.2em,
    costs: if lines != none { (widow: 0%, orphan: 0%) } else { (:) })
  set par(justify: justify, leading: leading, spacing: leading, first-line-indent: (amount: indent, all: true))
  set heading(numbering: if numbered { "1" } else { none })
  // The norm's heading, a number over the title; a formed book gives the line itself (« Chapter 3 », « Prologue »).
  show heading.where(level: 1): it => context {
    let label = piece-label.get()
    let running = piece-opens.get() == "inPage" and query(heading.where(level: 1)).first().location() != it.location()
    if running { v(pitch * 2, weak: true) } else {
      pagebreak(weak: true)
      if shunn { v(30%) } else { v(pitch * 3) }
    }
    align(center, block(below: if running { pitch } else { pitch * 2 }, sticky: running)[
      #set text(size: size, weight: "regular")
      #if label == auto { if it.numbering != none { [#counter(heading).display("1")#linebreak()] } } else if label != none { [#label#linebreak()] }
      #it.body
    ])
  }
  show heading.where(level: 2): it => block(above: pitch, below: pitch, text(size: size, style: "italic", it.body))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: indent, it.body)
  // Lists stay plain: a hyphen or a number at the paragraph's indent, a line like the others, no space around.
  set list(indent: indent, marker: [-])
  set enum(indent: indent)
  show emph: it => it
  if title != none and title-page-on {
    page(header: none)[
      #if shunn {
        grid(columns: (1fr, auto),
          [#if author != none { author } #if contact != none { linebreak(); contact }],
          [#if count != none { count }])
        v(1fr)
        align(center)[#upper(title) #if author != none { v(pitch); [#author] }]
        v(1fr)
      } else {
        v(1fr)
        align(center)[
          #text(size: size * 1.4, title)
          #if author != none { v(pitch * 2); author }
        ]
        v(1fr)
        if contact != none or count != none {
          grid(columns: (1fr, auto), [#if contact != none { contact }], [#if count != none { count }])
        }
      }
    ]
  }
  body
}
