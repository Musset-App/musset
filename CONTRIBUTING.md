# Contributing to Musset

Thank you for wanting to help. Musset is made for writers, and most of what improves it starts with a writer saying
what got in their way.

## Ideas, problems and questions

- **From the app:** **Send Feedback**, at the foot of the sidebar (or in the Help menu). It goes straight to the people
  who make Musset, not to a public page, and can attach the details of your Mac and Musset's latest crash report.
  Nothing from your books is sent. Leave an address if you'd like an answer.
- **On GitHub:** [open an issue](https://github.com/Musset-App/musset/issues/new). Issues are public, so leave out
  anything from a book you don't want seen.

A good report says what you did, what you expected and what happened instead, with Musset's version (Musset › About
Musset) and your macOS. A good idea says what you were trying to write or do, more than the button you'd add: there is
often a simpler way to the same place.

What changed in each release is in [CHANGELOG.md](CHANGELOG.md).

## What goes in

These principles decide what Musset becomes, so a change that goes against one is unlikely to be taken, however
well made:

1. **Musset never generates the author's text.** Features may read, quote, question and annotate; they do not write
   prose for the book.
2. **The author's files are sacred.** Musset writes only chapter files, `bible/` and `.musset/`, and never deletes
   anything without a way back.
3. **Everything works with the AI off.**
4. **The keyboard first; calm by default.** A feature earns its place in the interface.
5. **Tests with real text.** Add or update tests with each change.

For anything larger than a fix, open an issue first and say what you have in mind: it saves you from writing code that
won't fit.

## Code

How to build Musset, run the tests and find your way around the project is in the README:
[Build from source](README.md#build-from-source), [Tests](README.md#tests) and [Project layout](README.md#project-layout).

- Swift 5 mode, SwiftUI with AppKit where the editor needs it. The Xcode project is generated from `project.yml` by
  XcodeGen: change `project.yml`, never the generated project.
- Run the full suite before you send a change. Tests that need the authors' own books or a live AI skip themselves.
- Every string the interface shows goes through `L()` and needs an entry in each of the six tables (see below).
- Follow the code around you: short names, comments that say why, no dead code.

### How a pull request lands

This repository is published from the project's working tree, one commit per release, signed by the project. So a pull
request isn't merged with GitHub's button: once it's agreed, the change is brought into the working tree, reviewed and
tested with the rest, and published with the next release. Your name goes in the commit message and in the changelog,
and the pull request is closed with a link to the release that carries it.

## Translations

The interface is in English, French, German, Spanish, Italian and Portuguese (Brazil and Portugal). Corrections are
very welcome, from a word to a whole table: the tables are `Musset/Resources/Localization/<language>.json`, and
[Translating the interface](README.md#translating-the-interface) explains how strings are looked up. Keep the
placeholders (`{%0}`) and, in French, the non-breaking space before `:`, `;`, `?` and `!`.

## Licence

Musset is released under the [GNU General Public License, version 3](LICENSE). By sending a contribution you agree that
it is released under the same licence.
