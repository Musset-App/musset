---
title: Emacs keys on a Mac, without losing your accents
short: Emacs keys
description: Musset's Emacs mode has the mark, the region and a kill ring, with Meta on Option or Esc, so Option still types é, ü and ç. The complete list of bindings.
section: write
order: 10
kind: Reference
---

## Emacs chords, in a writing app

macOS already understands a little Emacs: [[⌃A]], [[⌃E]], [[⌃F]], [[⌃B]], [[⌃N]], [[⌃P]] work in every text field. Musset's Emacs mode adds what is missing for real work: the mark and the region, a kill ring, word and sentence commands on Meta.

Turn it on in **Settings ▸ Keyboard ▸ Emacs**.

## Control keys

| Key | Does |
|---|---|
| [[⌃F]] · [[⌃B]] | Forward · back a character |
| [[⌃N]] · [[⌃P]] | Next · previous line |
| [[⌃A]] · [[⌃E]] | Start · end of the line |
| [[⌃D]] | Delete forward |
| [[⌃T]] | Transpose characters |
| [[⌃O]] | Open a line |
| [[⌃K]] | Kill to the end of the paragraph |
| [[⌃Y]] | Yank the last kill |
| [[⌃W]] | Kill the region |
| [[⌃Space]] or [[⌃@]] | Set the mark |
| [[⌃G]] | Cancel: clear the mark and the selection |
| [[⌃S]] · [[⌃R]] | Find · find previous |
| [[⌃/]] | Undo |
| [[⌃V]] | Page down |

## Meta keys

Meta is [[⌥]], or [[Esc]] followed by the key.

| Key | Does |
|---|---|
| [[⌥F]] · [[⌥B]] | Forward · back a word |
| [[⌥A]] · [[Esc]] [[E]] | Start · end of the sentence |
| [[⌥D]] | Kill the word |
| [[⌥T]] | Transpose words |
| [[⌥W]] | Copy the region |
| [[⌥Y]] | After a yank: the kill before it |
| [[Esc]] [[U]] · [[⌥L]] · [[Esc]] [[C]] | Uppercase · lowercase · capitalise the word |
| [[⌥<]] · [[⌥>]] | Start · end of the chapter |
| [[⌥{]] · [[⌥}]] | Previous · next paragraph |
| [[⌥V]] | Page up |
| [[⌥X]] | Open the [command bar](/guide/command-bar/) |

## After ⌃X

| Keys | Does |
|---|---|
| [[⌃X]] [[⌃S]] | Save now |
| [[⌃X]] [[U]] | Undo |
| [[⌃X]] [[H]] | Select the chapter |
| [[⌃X]] [[⌃X]] | Swap the caret and the mark |

Pause after [[⌃X]] or [[Esc]] and a card lists what may follow.

## Your accents still work

On a Mac, Option is how you type accents: [[⌥E]] then *e* gives é, [[⌥U]] gives the umlaut, [[⌥C]] gives ç, [[⌥N]] the tilde. A writing app that took those keys for Meta would be useless in French, Spanish or German.

So in Musset those keys **stay accents**. For the Emacs commands on the same letters, press [[Esc]] first: [[Esc]] [[E]] for the end of the sentence, [[Esc]] [[U]] to uppercase a word, [[Esc]] [[C]] to capitalise it. Every other Meta command works with Option directly.

## The mark and the region

[[⌃Space]] sets the mark; the status at the bottom of the page says *Mark set*. The region is the text between the mark and the caret, or the selection if you have one. [[⌃W]] kills it, [[⌥W]] copies it, [[⌃X]] [[⌃X]] jumps to the other end.

> macOS often keeps [[⌃Space]] for switching input sources. If nothing happens, use [[⌃@]], or free the shortcut in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Input Sources.

## The kill ring

Musset keeps your last thirty kills. [[⌃Y]] yanks the latest; [[⌥Y]] right after it replaces what you yanked with the one before, and again with the one before that. Each kill also goes to the Mac's clipboard, so other apps see it.

This is the Emacs answer to moving several passages at once: kill three sentences in three places, then yank and cycle.

## What is not there

It is Emacs's editing keys, not Emacs. There are no buffers or file commands ([[⌃X]] [[⌃F]]), no prefix argument ([[⌃U]]), no fill ([[⌥Q]]), no rectangles and no keyboard macros. [[⌃S]] opens Musset's find bar rather than an incremental search. [[⌥X]] opens the command bar, which does for Musset what `M-x` does for Emacs.

See [keyboard modes](/guide/keyboard-modes/) for the three others.
