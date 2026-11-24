# Proofreading a transcription against the page images

A 1925 Spanish book (H. G. Wells, «La máquina exploradora del tiempo», Bauzá, Barcelona) was read by OCR.
Your file `lines-N.txt` holds the OCR text of your pages, one printed line per line:

    p048 L03 · reconocer algunas, como una especie de fram-

`p048` is the page, `L03` the line on that page, then `¶` if the printed line starts indented (a new paragraph),
`·` if not, `#` for the first line under a chapter title. Then the line's text.

Each page has two images in `half/`: `pNNN-a.png` (top half) and `pNNN-b.png` (bottom half; a line or two overlap).
The images do not show the chapter heading or page number on every page; ignore headings, page numbers, ornaments
and any watermark.

## What to do
For every page in your file, Read both images and compare every printed line with its line in the file, character by
character. Look hardest at what OCR gets wrong on this book:
- accents, above all a missing `í` (OCR reads `habia`, `alli`, `comprendi` where the print has `había`, `allí`, `comprendí`), and `ó é á ú ñ ü`;
- `¿ ¡`, commas against full stops, `;` against `:`, missing dashes;
- letters confused: `f/t`, `l/I/1`, `ll` read as `Il` or `H`, `m/in`, `n/u`, `c/e`, `rn/m`;
- words glued together or split, a word missing, a line missing, two lines in the wrong order;
- the `¶` / `·` mark: `¶` only where the printed line really starts further right than its neighbours.

## Rules
- Give the text **as printed**. Do not modernise spelling (`fué`, `dió`, `vió`, `sér`, `construído`, `oir` stay) and
  do not repair the printer's own mistakes: if the image itself has a misprint, keep it and report it under MISPRINT.
- A word broken at the end of a line ends with a plain hyphen `-`. The dialogue dash is `—` (em dash), written
  without spaces around it unless the print clearly has one.
- Words printed in italics (visibly slanted type) are wrapped in asterisks: `*así*`.
- A footnote line at the foot of a page stays where it is; just correct its text.
- Never guess. If the image is unclear at a spot, leave the line as it is and report it under UNSURE.
- Do not correct a line that is already right.

## What to write
Write one file, `corr-N.txt` (N = your number), in the same folder, and nothing else. Format:

    p048 L02 · pie del suelo, llenas de diversas frutas. Creí
    p051 L07+ · a whole printed line that is missing, to insert after L07
    p060 L12 DELETE
    MISPRINT p048 L01: printed «inultitud», probably «multitud»
    UNSURE p077 L20: «rnás» or «más», the image is blurred

A correction is always the complete corrected line in the format of the input file. One line per correction.
Do every page; do not sample. When done, reply with three numbers only: pages checked, lines corrected, misprints reported.
