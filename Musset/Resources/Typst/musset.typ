// Musset — book templates for Typst.
// `blanche`: Collection Blanche (120 × 188 mm, EB Garamond 10.8/13, 4 mm indent, folio at the foot).
// `classique`: manuscript and trade layouts (A4 submission, A5, print), chapter title in the running head.
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

// A part's own page, recto in a book: its numeral, its title below, no folio.
#let part-page(num, title) = {
  context pagebreak(weak: true, to: if facing-pages.get() { "odd" } else { none })
  nofolio()
  v(1fr)
  align(center)[
    #text(size: 1.8em, tracking: 0.08em, num)
    #if title != "" { v(0.8em); text(size: 1.15em, style: "italic", title) }
  ]
  v(2fr)
  pagebreak()
}

#let asterism() = align(center, block(above: 1.2em, below: 1.2em)[⁂])

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

#let blanche(
  title: none, author: none, contact: none, lang: "fr", region: none,
  paper: (120mm, 188mm),
  margins: (inside: 20mm, outside: 14mm, top: 16mm, bottom: 20mm),
  size: 10.8pt, line-height: 13pt, indent: 4mm,
  font: ("EB Garamond 12", "EB Garamond", "Libertinus Serif"),
  crop: false, title-page-on: true, facing: true,
  body,
) = {
  set document(title: title, author: if author != none { author } else { () })
  facing-pages.update(facing)
  set page(..page-setup(paper, margins, crop,
    context if not folio-hidden() {
      let n = here().page()
      align(if not facing { center } else if calc.even(n) { left } else { right }, text(size: size, number-type: "old-style")[#n])
    }, none, facing: facing))
  set text(font: font, size: size, lang: lang, region: region, number-type: "old-style", hyphenate: true)
  set par(justify: true, linebreaks: "optimized", leading: line-height - size * 0.65, spacing: line-height - size * 0.65,
    first-line-indent: (amount: indent, all: lang == "fr"))
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    v(18mm)
    align(center, text(size: size, weight: "regular", smallcaps(it.body)))
    v(14mm)
  }
  show heading.where(level: 2): it => align(center, block(above: 1.4em, below: 1em, text(size: size, weight: "regular", smallcaps(it.body))))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: indent * 2, right: indent, text(size: size * 0.95, it.body))
  if title != none and title-page-on { title-page(title, author, contact, size) }
  body
}

#let classique(
  title: none, author: none, contact: none, lang: "fr", region: none,
  paper: (210mm, 297mm),
  margins: (left: 30mm, right: 30mm, top: 25mm, bottom: 30mm),
  size: 11pt, line-height: none, indent: 1.5em,
  font: ("EB Garamond 12", "EB Garamond", "Libertinus Serif"),
  numbered: true, crop: false, title-page-on: true, facing: true,
  body,
) = {
  let lh = if line-height == none { size * 1.45 } else { line-height }
  set document(title: title, author: if author != none { author } else { () })
  facing-pages.update(facing)
  set page(..page-setup(paper, margins, crop,
    context if not folio-hidden() { align(center, text(size: size * 0.85)[#here().page()]) },
    context {
      let before = query(heading.where(level: 1).before(here()))
      let starts = query(heading.where(level: 1)).any(h => h.location().page() == here().page())
      if before.len() > 0 and not starts and not folio-hidden() { align(center, text(size: size * 0.85, style: "italic", before.last().body)) }
    }, facing: facing))
  set text(font: font, size: size, lang: lang, region: region, hyphenate: true)
  set par(justify: true, linebreaks: "optimized", leading: lh - size * 0.65, spacing: lh - size * 0.65,
    first-line-indent: (amount: indent, all: lang == "fr"))
  set heading(numbering: if numbered { "1" } else { none })
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    v(size * 4)
    align(center, block(below: size * 3)[
      #if it.numbering != none { text(size: size * 0.9, tracking: 0.1em, upper(counter(heading).display("1"))); linebreak() }
      #text(size: size * 1.5, weight: "regular", it.body)
    ])
  }
  show heading.where(level: 2): it => block(above: 1.6em, below: 0.8em, text(size: size * 1.1, style: "italic", it.body))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: 2em, right: 1em, text(size: size * 0.95, it.body))
  if title != none and title-page-on { title-page(title, author, contact, size) }
  body
}

/// A manuscript for submission, by the conventions of its country:
/// - `lines`/`chars`: a fixed grid, in a monospaced face (German Normseite and Italian cartella 30 × 60, French feuillet 25 × 60);
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
  set text(font: font, size: size, lang: lang, region: region, hyphenate: false, top-edge: 0.8em, bottom-edge: -0.2em,
    costs: if lines != none { (widow: 0%, orphan: 0%) } else { (:) })
  set par(justify: justify, leading: leading, spacing: leading, first-line-indent: (amount: indent, all: true))
  set heading(numbering: if numbered { "1" } else { none })
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    if shunn { v(30%) } else { v(pitch * 3) }
    align(center, block(below: pitch * 2)[
      #set text(size: size, weight: "regular")
      #if it.numbering != none { [#counter(heading).display("1")#linebreak()] }
      #it.body
    ])
  }
  show heading.where(level: 2): it => block(above: pitch, below: pitch, text(size: size, style: "italic", it.body))
  show heading: set par(first-line-indent: 0pt)
  show quote.where(block: true): it => pad(left: indent, it.body)
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
