# Third-party software and fonts in Musset

Musset is free software under the GNU General Public License, version 3 (see `LICENSE`). The app bundles the
following programs, libraries and fonts. Each keeps its own licence, reproduced or linked below.

## Programs bundled inside Musset.app

| Component | Version | Licence | Source |
|---|---|---|---|
| **pandoc** (DOCX, EPUB, Word import) | 3.9.0.2 | GPL-2.0-or-later | https://github.com/jgm/pandoc/releases/tag/3.9.0.2 |
| **LanguageTool** (spelling and grammar) | 6.6 | LGPL-2.1-or-later | https://languagetool.org/download/ — https://github.com/languagetool-org/languagetool |
| **Eclipse Temurin** Java runtime (runs LanguageTool; trimmed with `jlink`) | 21.0.13+9 | GPL-2.0 with the Classpath Exception | https://adoptium.net — https://github.com/adoptium/temurin21-binaries/releases/tag/jdk-21.0.13%2B9 |

pandoc, LanguageTool and the Java runtime are separate programs that Musset runs; they are shipped unmodified,
except that LanguageTool is trimmed to Musset's six languages and the Java runtime to the modules LanguageTool
uses (`scripts/fetch-languagetool.sh` does both, reproducibly, from the pinned releases above). Their complete
source code is available at the addresses above. LanguageTool also bundles libraries under their own licences,
listed in `LanguageTool/languagetool/third-party-licenses/` inside the app.

## Libraries linked into Musset

| Component | Version | Licence | Source |
|---|---|---|---|
| **libgit2** (git history and sync) | 1.9.2 | GPL-2.0 with the linking exception | https://github.com/libgit2/libgit2 (built through https://github.com/ibrahimcetin/libgit2) |
| **Typst** (the pages of Read mode and of the PDF export), as a library: `typst`, `typst-render`, `typst-pdf`, `typst-kit` | 0.14.2 | Apache-2.0 | https://github.com/typst/typst |

Typst is linked through `musset-typeset/` (Rust), with the crates it depends on, each under its own licence
(MIT or Apache-2.0 for nearly all); `musset-typeset/Cargo.lock` lists them with their exact versions.

## Fonts

All under the SIL Open Font License 1.1; each licence is in `Musset/Resources/Fonts/`.

| Font | Use | Licence file |
|---|---|---|
| **EB Garamond** (Octavio Pardo, Georg Duffner) | The printed book | `EBGaramond-OFL.txt` |
| **Inter** (Rasmus Andersson) | The interface | `Inter-OFL.txt` |
| **IBM Plex Mono** (IBM) | The manuscript | `IBMPlexMono-OFL.txt` |
| **Iosevka Aile and Etoile** (Belleve Invis) | Optional manuscript faces | `Iosevka-OFL.txt` |

## Services Musset can talk to

Musset sends text to an AI only when the author turns it on, through the author's own account with that
provider (Claude, ChatGPT/Codex). Those services are not part of Musset and have their own terms.

The name « Musset » and its icon identify the official app; please use another name for a modified version.
