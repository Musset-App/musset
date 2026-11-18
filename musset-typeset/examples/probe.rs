//! Composes a book from a JSON spec and prints what the engine found: `cargo run --release --example probe spec.json [page]`.
use musset_typeset::{Book, Spec};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let spec: Spec = serde_json::from_str(&std::fs::read_to_string(&args[1]).unwrap()).unwrap();
    let t = Instant::now();
    let book = Book::compile(&spec).unwrap_or_else(|e| panic!("{e}"));
    println!("pages: {}  in {:.2}s  warnings: {:?}", book.pages.len(), t.elapsed().as_secs_f64(), book.warnings);
    if let Some(out) = args.get(3) {
        std::fs::write(out, &book.source).unwrap();
    }
    let Some(page) = args.get(2).and_then(|p| p.parse::<usize>().ok()) else { return };
    let p = &book.pages[page];
    println!("page {page}: {} × {} pt, {} glyphs", p.width, p.height, p.glyphs.len());
    let mut last_y = f32::MIN;
    let mut line = String::new();
    for g in &p.glyphs {
        if (g.baseline - last_y).abs() > 1.0 && !line.is_empty() {
            println!("{line}");
            line.clear();
        }
        last_y = g.baseline;
        let md: Vec<u16> = spec.chapters[g.chapter as usize].markdown.encode_utf16().collect();
        let s = String::from_utf16_lossy(&md[g.start as usize..g.end as usize]);
        if g.footnote >= 0 { line += &format!("[^{}]", g.footnote) } else { line += &s }
    }
    println!("{line}");
    let t = Instant::now();
    let (w, h, _) = book.render(page, 2.0, [255, 254, 251], [26, 26, 24]).unwrap();
    println!("render {w}×{h} in {:.3}s", t.elapsed().as_secs_f64());
}
