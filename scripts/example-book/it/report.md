# Un'esplorazione nel futuro (De Luca, Vallardi 1902) — transcription report

File: `example-time-machine-it.md` — 31610 words (31970 whitespace-separated tokens), 197074 characters, 17 headings, 872 paragraphs. Book pages 5–177 (PDF pages 7–179). No footnotes in this edition.

## Chapter titles
1. Introduzione
2. La macchina
3. L’Esploratore ritorna
4. Il viaggio
5. Nell’età dell’oro
6. Il crepuscolo dell’umanità
7. Un colpo inaspettato
8. Esplorazioni
9. I Morlocks
10. Quando venne la notte
11. Il palazzo di porcellana verde
12. Nelle tenebre
13. La trappola della sfinge bianca
14. L’ultima visione
15. Il ritorno dell’Esploratore
16. Dopo il racconto
17. Epilogo

## Method and numbers
Three readings were aligned token by token: archive.org ABBYY (A), macOS Vision with language correction (V1), and a third pass I added, Vision without language correction with line and word boxes (V3, `S/ocr/ocr3.swift`), used as backbone for page, line and indentation.

- 37,591 aligned positions; 35,586 agreed in all three readings.
- About 2,130 disagreements (1,724 differing regions plus about 400 accent/case differences on otherwise matching words).
- About 1,250 settled by rule: ABBYY agreeing with one Vision reading (312); only one reading a real word, checked against the book's own agreed vocabulary and the macOS Italian spell checker (about 730); final accent present in ABBYY and dropped by Vision (93); comma/period before a lowercase word (47); `È`/`E` (14); stray running heads and signatures (8).
- 882 decided by me one by one from the three readings in context (`decisions.json`).
- About 230 lines were checked on the page image (cropped line strips in `crops/`): 120 to settle disagreements, about 110 during the proofreading read.
- Then one full proofreading read of the text, which produced 91 further OCR/assembly repairs (`postedits.txt`) and 120 corrections of misprints (`printfixes.txt`, listed below).
- Italics were found by measuring the slant of every word box on every page, then confirmed on the image: 12 passages.

## Decisions of principle you may want to reverse
1. **The 1902 printing is careless, and I corrected its evident misprints.** Where all three readings and the image agree on a misprint (missing accent, swapped letters, doubled word, comma for period before a capital), the clean file has the corrected form. Every one is listed below and lives in `printfixes.txt`; deleting a line there and rerunning `S/ocr/assemble.py` restores the printed form.
2. `cosi` → `così` everywhere (17 places printed without the accent, 23 with).
3. Kept as printed: `perchè`, `nè`, `sè`, `benchè`, `pocanzi`, `da vero`, `a bastanza`, `in vece`, `in fatti`, `colezione`, `bujo`, `dubbii`, `studii`, `nikel`, `edifizio`, `volontieri`, `novamente`, `dieciotto`, `nerpicarmi`, `imprevidibile`, `piedistallo` (once, beside `piedestallo`), circumflex plurals `necessarî`, `varî`, `bacterî`, `proseguî` (= proseguii), and the internal accents `dànno`, `èra`, `vòlti`, `rètina`, `ronzìo`, `gridìo`, `tremolìo`, `pendìo`.
4. Ellipses: three dots → `…`; the print often has four or five (`….`, `…..`), kept as printed. Two places printed with two dots are given as `…`.
5. Dialogue dashes are as printed, including the places where the print omits the dash before the verb of saying (`— Ebbene? disse allo Psicologo`, `— Questo fa bene! esclamò.`). Two speeches printed without their opening dash got one (`— Benissimo!`, `— Io, almeno, mi difenderò!`).
6. Guillemets as printed: chapters IV, V, VI, IX, XI–XV open with `«`; chapters VII, VIII and X do not; `»` closes only at the two places the print closes it.
7. A paragraph break was accepted only after sentence-final punctuation; five breaks lost to a missing period in the OCR were restored by hand.

## Still not certain after looking at the image
- p. 10 (PDF) `sòlido`, p. 108 `macchinètta`, p. 118 `bràccio`, p. 122 `ròsea`, p. 130 `immèrsa`: ABBYY reads an internal accent and the scan shows a mark that may be an accent or a speck. Given without accent.
- p. 59 `…un secondo pensiero: Osservai la mezza dozzina…`: the print has a colon, then a capital on a new line that does not look indented. Kept in one paragraph.
- p. 71 `frammezzo all’altro viluppo dei cespugli`: printed `altro`; probably a misprint for `alto` or `atro` (Wells: "black tangle"). Left as printed.
- p. 71 `la lena già scarna`: printed so; possibly `scarsa`. Left as printed.
- p. 91 `Ma i più, poco pratici…`: printed `Ma più, poco pratici`; I supplied `i`.
- p. 113 `…relazioni affatto diverse:` followed by `Gli Eloi…` on a new indented line: kept as two paragraphs, as printed.
- p. 127 `rari fossili a pezzi staccati`: ABBYY has `a`, Vision does not, the image is unclear. Took ABBYY.
- p. 164 `Le stelle lucevano molto: ma mi parve…`: the print seems to read `mai`; sense and Wells require `ma`.
- p. 176 `una massa nera gialla` and p. 178 `uomini ancor ma gli enigmi`: left exactly as printed.
- p. 83 `e, l’abisso che mi separava` and p. 49 `nulla, in ciò di allarmante`: odd commas, left as printed.
- p. 108 `alle terga; mi tiravano i panni.`: semicolon as printed.
- Missing final accents: Vision drops them and the print itself sometimes omits them, so I restored them from sense wherever a verb form required one. I believe none is left, but this is the class of error most likely to have survived.

No page was unreadable. ABBYY lost two passages entirely (PDF p. 34, the Traveller's "Io non me la sento di disputare…" speech, and p. 162, the crab scene); both come from Vision alone and were read against the page.

## Features of this edition
- Title on the title page: *Un'esplorazione nel futuro (The Time Machine)*, "Traduzione di P. de Luca", "II. edizione". Seventeen numbered chapters (I–XVII, the last being the Epilogo), following the 1895 Heinemann division. Chapter titles follow the French translation of Davray (1899) closely ("L'Esploratore ritorna", "Il crepuscolo dell'umanità", "Un colpo inaspettato", "Esplorazioni", "La trappola della sfinge bianca", "L'ultima visione"), and so does much of the wording: De Luca appears to have translated from the French.
- The narrator addresses the reader directly at the end of ch. III: "quale sto per narrarla a voi, lettori, nei capitoli seguenti". Not in Wells.
- Names: the Time Traveller is "l'Esploratore del tempo" (lowercase *tempo*; once "Esploratore del Tempo", once "esploratore"), later also "il viaggiatore"; the Medical Man is "il Dottore" (once "il medico"); the Provincial Mayor is "il Sindaco provinciale", then "il Provinciale"; the Very Young Man is "un giovanetto" / "il Giovinetto" / "il Giovanetto"; the Editor is "il Redattore capo"; the Journalist "il Giornalista" (once "il Pubblicista"); the Silent Man "l'Uomo taciturno" (once "l'Uomo silenzioso"). Blank, Filby, Hillyer, Richardson keep their names.
- "Morlocks" is invariable ("alcun Morlocks", "un Morlocks"; "Morlock" once). "Eloi", "Weena". The machine is "la Macchina del Tempo" in the Traveller's narration, "Macchina del tempo" in the frame.
- The year is given as "802701" (no separator) twice and once in words, "ottocentoduemilasettecentuno"; "802000" once.
- The italic sentence on time and space is italic in the print. Other italics: *istantaneo*, *mangiare*, *Ora*, *il perchè*, *Morlocks* and *Eloi* at their naming, *notti oscure* (twice), *Philosophical Transactions*, *Paese dei Bravi*, *cancan*, *Pall Mall Gazette*.
- Local colour and references kept or adapted: "Simone Newcomb", "New-York", "Tubingen", "Nabuccodonosor", "Grant Allen", "Darwin il giovane", "Carlyle", "Combe Wood", "Banstead", "Wimbledon", "Wandsworth e Battersea"; the "Land of the Leal" becomes "l'aria del *Paese dei Bravi*". Distances stay in miles; the descent of the well is "circa duecento metri".
- The grey man episode and the Kangaroo-like creatures of the serial are absent, as in the Heinemann text. The "Further Vision" keeps the crabs and the eclipse.

## Misprints of the 1902 edition corrected in the clean file
- `ciò che che hanno saputo` → `ciò che hanno saputo`
- `fondare una geometrica a quattro` → `fondare una geometria a quattro`
- `— Sì si, credo` → `— Sì sì, credo`
- `si rischiarò. ⏎  ⏎ Benissimo! — In quanto` → `si rischiarò. ⏎  ⏎ — Benissimo! — In quanto`
- `poi prosegui:` → `poi proseguì:`
- `la gran difficolta —` → `la gran difficoltà —`
- `rigirarsi altresi e viaggiare` → `rigirarsi altresì e viaggiare`
- `— Sarà! — continuo con` → `— Sarà! — continuò con`
- `calzoni, usci passo` → `calzoni, uscì passo`
- `— Che diamine fara?` → `— Che diamine farà?`
- `molto finalmente costrutta` → `molto finamente costrutta`
- `da presso al focolare Posò` → `da presso al focolare. Posò`
- `gli disse di setndere l’indice` → `gli disse di stendere l’indice`
- `poi Filby dichiaro che` → `poi Filby dichiarò che`
- `per tissare in faccia` → `per fissare in faccia`
- `presso che compiuta, è quando` → `presso che compiuta, e quando`
- `— Ma sì, ma si! —` → `— Ma sì, ma sì! —`
- `noi ne percoliamo uno solo` → `noi ne percorriamo uno solo`
- `delle parti di nikei e di` → `delle parti di nikel e di`
- `ineguaglianze delsuolo,` → `ineguaglianze del suolo,`
- `questa esplorazione del tempo Può forse` → `questa esplorazione del tempo? Può forse`
- `di mangiare io, è non farò` → `di mangiare io, e non farò`
- `laboratorio oggi, stesso alle quattro` → `laboratorio oggi stesso, alle quattro`
- `ma occorrera assolutamente` → `ma occorrerà assolutamente`
- `Riposero poi.` → `Riposerò poi.`
- `— E inteso! — approvò` → `— È inteso! — approvò`
- `del tempo narro la sua` → `del tempo narrò la sua`
- `che si rianimo a poco` → `che si rianimò a poco`
- `con tutt’i i suoi pregi` → `con tutt’i suoi pregi`
- `laboratorio si riempi di nebbia` → `laboratorio si riempì di nebbia`
- `verso la porte del giardino` → `verso la porta del giardino`
- `un mormorio vertignoso e` → `un mormorio vertiginoso e`
- `Sono immensamente moleste. E come sulle` → `Sono immensamente moleste. È come sulle`
- `E provavo altresi l’orrore` → `E provavo altresì l’orrore`
- `crescente follia, proseguì la corsa` → `crescente follia, proseguî la corsa`
- `splendida archichettura,` → `splendida architettura,`
- `un infinita serie` → `un’infinita serie`
- `intelletto mi riusci oltremodo` → `intelletto mi riuscì oltremodo`
- `apparivano profondamente incavato` → `apparivano profondamente incavate`
- `di un si lontano avvenire` → `di un sì lontano avvenire`
- `e mi avvidi lì per li che` → `e mi avvidi lì per lì che`
- `qua e là qalche bianca` → `qua e là qualche bianca`
- `nell’aiutare e opere` → `nell’aiutare le opere`
- `e l’aunento era cessato` → `e l’aumento era cessato`
- `diventare fiacchezza, Anche al tempo` → `diventare fiacchezza. Anche al tempo`
- `delle neccessità` → `delle necessità`
- `nella primitiva, quantità` → `nella primitiva quantità`
- `Di li a poco, mi colse` → `Di lì a poco, mi colse`
- `fin da miei primi gesti` → `fin dai miei primi gesti`
- `mi fece vergognare.; tuttavia` → `mi fece vergognare; tuttavia`
- `qualche rumore li dentro` → `qualche rumore lì dentro`
- `all’improviso` → `all’improvviso`
- `Io, però, erano quasi sicuro` → `Io, però, ero quasi sicuro`
- `Uno di esso era presso` → `Uno di essi era presso`
- `fu aspirato li per li e disparve` → `fu aspirato lì per lì e disparve`
- `un gran nnmero di` → `un gran numero di`
- `aveva allora si poca stima` → `aveva allora sì poca stima`
- `vicinanze delle sfinge bianca` → `vicinanze della sfinge bianca`
- `temeva l’oscurità temeva tutto` → `temeva l’oscurità, temeva tutto`
- `ella dormi con la testa` → `ella dormì con la testa`
- `La notte che sussegui al` → `La notte che susseguì al`
- `con l’espressione che qualche animale` → `con l’impressione che qualche animale`
- `la terrà era più presso` → `la terra era più presso`
- `E generalmente ammesso` → `È generalmente ammesso`
- `accaddeun fatto` → `accadde un fatto`
- `Mi assali l’antica` → `Mi assalì l’antica`
- `due individui de mondo` → `due individui del mondo`
- `ne accessi alcuni` → `ne accesi alcuni`
- `il nuovo punto di visita:` → `il nuovo punto di vista:`
- `l’accettai li per li,` → `l’accettai lì per lì,`
- `perdette gradamente il diritto` → `perdette gradatamente il diritto`
- `zone del territorio, Ne’ dintorni` → `zone del territorio. Ne’ dintorni`
- `bellezza; e e al di sotto` → `bellezza; e al di sotto`
- `alcun abile guida` → `alcuna abile guida`
- `che di li a pochi giorni` → `che di lì a pochi giorni`
- `Veena, mi accompagnò` → `Weena mi accompagnò`
- `mano molle che, si posava` → `mano molle, che si posava`
- `ad ogni mode erano` → `ad ogni modo erano`
- `Io, almeno, mi difenderò! — pensavo.` → `— Io, almeno, mi difenderò! — pensavo.`
- `essere i Morloks, secondo` → `essere i Morlocks, secondo`
- `di dieciotto, o giù di li.` → `di dieciotto, o giù di lì.`
- `Di Morloks, fino a quel` → `Di Morlocks, fino a quel`
- `le radici sporgeniti,` → `le radici sporgenti,`
- `il terrore che dividova le` → `il terrore che divideva le`
- `come un riflesse di fuoco` → `come un riflesso di fuoco`
- `occhi primi d’entrare` → `occhi prima d’entrare`
- `perchè era si umana` → `perchè era sì umana`
- `del genere dei mesanterì.` → `del genere dei megaterî.`
- `estinzione dei bacterì e` → `estinzione dei bacterî e`
- `la mente e suscito una filza` → `la mente e suscitò una filza`
- `si vedevano qua e la dei cartoni` → `si vedevano qua e là dei cartoni`
- `una spece di danza` → `una specie di danza`
- `d’una belennite fossile` → `d’una belemnite fossile`
- `mai stato si crudelmente` → `mai stato sì crudelmente`
- `Weena sembrata svenuta` → `Weena sembrava svenuta`
- `e mi colpi allora un` → `e mi colpì allora un`
- `un istante e stramazzo.` → `un istante e stramazzò.`
- `fosse prodootto…` → `fosse prodotto…`
- `quelle mani aggruppanti` → `quelle mani aggrappanti`
- `spaventava mai si fortemente` → `spaventava mai sì fortemente`
- `tuttavia in torno a me` → `tuttavia intorno a me`
- `che queli dal mondo sovrapposto` → `che quelli del mondo sovrapposto`
- `e sentito un vero piacere` → `e sentivo un vero piacere`
- `quello che avevo preceduto:` → `quello che avevo preveduto:`
- `la calma fini di colpo` → `la calma finì di colpo`
- `leggera schiuma; c’era una` → `leggera schiuma, c’era una`
- `un’acsensione sui monti` → `un’ascensione sui monti`
- `Quel grido fu si lugubre` → `Quel grido fu sì lugubre`
- `una specie di tilamento` → `una specie di filamento`
- `lo stessa folla di sozzi` → `la stessa folla di sozzi`
- `lucevano molto: mai mi parve` → `lucevano molto: ma mi parve`
- `quanto vi ha detto è per voi` → `quanto vi ho detto è per voi`
- `grata del camminetto` → `grata del caminetto`
- `— Ma si, verissimamente!` → `— Ma sì, verissimamente!`
- `Dissi di si, comprendendo` → `Dissi di sì, comprendendo`
- `egli usci nel corridoio` → `egli uscì nel corridoio`
- `in capo di sciegliere per` → `in capo di scegliere per`
- `Sfrugai l’ultimo fiammifero` → `Sfregai l’ultimo fiammifero`
- `O si rigittò invece` → `O si rigettò invece`
- `Ma più, poco pratici` → `Ma i più, poco pratici`
