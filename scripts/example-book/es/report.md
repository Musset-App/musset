# La máquina exploradora del tiempo (J. d'Albroi, B. Bauzá, Barcelona 1925): how the text was made

Source: the scan at archive.org, item `maquina-del-tiempo` (Public Domain Mark 1.0), 80 images of two-page spreads.
The translator signs "J. d'Albroi", probably a pseudonym; no death date was found. The text in
`Musset/Resources/Example/example-time-machine-es.md` is what that scan prints: 32,099 words, sixteen chapters and an
Epílogo, one footnote (the translator's own).

## Method
- Each spread was cut at the gutter and each half read three times by the Mac's text recognition (`ocrh.swift`:
  without language correction at two sizes, and with it). archive.org's own OCR was too poor to use.
- The three readings were aligned word by word (`merge.py`): 37,225 positions, 566 disagreements, 550 settled by
  two readings against one, 16 decided by hand (`decisions.json`).
- Every page was then compared with its image, line by line, by six proofreading agents (`BRIEF.md`): 390 lines
  corrected (`corr-1.txt` … `corr-6.txt`), mostly accents the recognition drops (`había`, `allí`, `comprendí`),
  the diaeresis of `Eloïs`, and italics.
- `build.py` joins the lines into paragraphs, places the footnote, and applies `printfixes.txt`.

## Where an error could have survived
- All three readings come from one engine and share its errors; only the image check catches those.
- The proofreaders read pages 19-26, 40-44 and 58-65 once only; the other pages were read twice.
- No independent full read of the finished text was done after the corrections.

## Kept as printed
The spelling of 1925: `fué`, `dió`, `vió`, `fuí`, `sér`, `oir`, `reir`, `construído`, `ruído`, `ruínas`, `áulas`,
`éllo`, `sinó`, `trás`, `exhuberante`, `¿Es qué…`, `obsesionase`. Dialogue dashes without spaces (`hacer?—dijo.`).
`un mapa, un hacha y una espada` (probably `una maza`) is left as printed.

## Misprints corrected
Forty-four, listed in `printfixes.txt` by kind: damaged or wrong letters, stray accents, three missing accents,
full stops printed in the middle of a sentence, two hyphenated words broken at a line end. Deleting a line there and
running `build.py` again gives the printed form back.

## Uncertain after looking at the image
The proofreaders' `UNSURE` lines in the `corr-*.txt` files: mostly a mark at a line end that may be a comma, a full
stop or a speck in the paper.
