---
title: Smart quotes, dashes and non-breaking spaces, by language
short: Automatic typography
description: Musset sets quotation marks, apostrophes, dashes, ellipses and non-breaking spaces by the rules of the book's language: English, French, German, Spanish, Italian or Portuguese. The rules, and how to turn them off.
section: write
order: 5
kind: Reference
---

## Type straight, read typeset

Type `"Don't," she said...` and Musset gives you “Don’t,” she said… A French book gets « guillemets » with their non-breaking spaces, a German one „Anführungszeichen“, a Spanish one the raya.

The rules come from the book's language, which you set in the book's settings under **Book language**. They are plain rules, applied on your Mac; no AI is involved.

Musset never changes the paragraph you are writing. It tidies a paragraph when you leave it, so nothing moves under your fingers. The one exception is the apostrophe, which curls as you type it.

## The rules, language by language

In every language: an apostrophe between two letters becomes ’, three full stops become an ellipsis …, and doubled spaces become one.

| Language | Quotation marks | Inside a quotation | Dash between words | Dialogue dash |
|---|---|---|---|---|
| English (US) | “ ” | | — unspaced | |
| English (UK) | ‘ ’ | “ ” | – spaced | – |
| Français | « » with non-breaking spaces | | – spaced | — |
| Deutsch (Deutschland) | „ “ | ‚ ‘ | – spaced | – |
| Deutsch (Schweiz) | « » | ‹ › | – spaced | – |
| Español (España) | « » | “ ” | — | — |
| Español (Latinoamérica) | “ ” | ‘ ’ | — | — |
| Italiano | « » | “ ” | – spaced | — |
| Português (Portugal) | « » | “ ” | – spaced | — |
| Português (Brasil) | “ ” | ‘ ’ | – spaced | — |

To get a dash, type a hyphen with a space on each side, or two hyphens. To open a line of dialogue with a dash, type a hyphen at the start of the line.

## What each language adds

**French.** A non-breaking space goes before `;` `:` `!` `?` and inside the guillemets, so a line never begins with a lone question mark. It is not added inside a time such as 12:30. Names that carry their own punctuation, such as *Yahoo!*, are left alone, and if you remove a space Musset added after a name, it remembers that name for the book.

**German.** Abbreviations get their thin space: *z.B.* becomes *z. B.*, and likewise *d. h.*, *u. a.*, *i. d. R.* In a Swiss book, ß becomes ss.

**Italian.** *E'* at the start of a sentence becomes *È*, and *po'* gets its proper apostrophe.

**French, Spanish, Italian and Portuguese.** Latin phrases such as *a priori*, *de facto*, *in extremis* and *vice versa* are set in italics.

## What Musset leaves alone

- The paragraph you are writing.
- Your notes to yourself (`<!-- … -->`), code, and web addresses.
- Corrections waiting to be decided.
- A paragraph with an odd number of straight quotation marks, because it cannot tell which opens and which closes.

## Undo it, or turn it off

Each round of tidying is one step of undo, named *Typography*. Press [[⌘Z]] and the paragraphs go back to what you typed; Musset then leaves them alone until you edit them again.

To turn the rules off, open **Settings ▸ Proofreading** and switch off **The book's typography**. The same switch is in the gear menu at the bottom of the Notes panel.

## Fix a whole manuscript at once

A book you brought in from Word or another app arrives with whatever quotes and spaces it had. Choose **Write ▸ Apply Typography to the Whole Book…**. Musset tells you how many fixes it would make in how many chapters, and asks before doing anything. It is saved as one point in the [history](/guide/book-history/), so it can be taken back.

## In the files

Musset writes the real characters into your Markdown files: a curly apostrophe is a curly apostrophe, and a French non-breaking space is the standard one (U+00A0). Any other app, and any typesetter, reads them as they are.
