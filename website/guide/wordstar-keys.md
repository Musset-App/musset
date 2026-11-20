---
title: WordStar keys on a Mac
short: WordStar keys
description: Write on a Mac with WordStar's control diamond, blocks that stay marked, and place markers. The complete list of WordStar commands in Musset, and what is not there.
section: write
order: 8
kind: Reference
---

## Why WordStar, in this century

WordStar put every command under the fingers of a touch typist. The cursor moves with the left hand on the home row, and a block of text stays marked while you go and look for where it belongs. Novelists who learned it rarely found anything as good for moving prose around.

Musset has a WordStar mode. Turn it on in **Settings ▸ Keyboard ▸ WordStar**. The keys are on Control ([[⌃]]); Command keeps Musset's own shortcuts.

## The diamond

| Key | Moves |
|---|---|
| [[⌃E]] | Up a line |
| [[⌃X]] | Down a line |
| [[⌃S]] | Left a character |
| [[⌃D]] | Right a character |
| [[⌃A]] | Back a word |
| [[⌃F]] | Forward a word |
| [[⌃R]] | Up a page |
| [[⌃C]] | Down a page |

## Deleting and the rest

| Key | Does |
|---|---|
| [[⌃G]] | Deletes the character under the caret |
| [[⌃T]] | Deletes to the start of the next word |
| [[⌃Y]] | Deletes the paragraph |
| [[⌃U]] | Undoes |
| [[⌃N]] | Opens a new line at the caret |
| [[⌃L]] | Finds the next match |

## Quick movement: ⌃Q

| Keys | Does |
|---|---|
| [[⌃Q]] [[S]] · [[⌃Q]] [[D]] | Start · end of the line |
| [[⌃Q]] [[R]] · [[⌃Q]] [[C]] | Start · end of the chapter |
| [[⌃Q]] [[B]] · [[⌃Q]] [[K]] | Start · end of the block |
| [[⌃Q]] [[0]]–[[9]] | Goes to a place marker |
| [[⌃Q]] [[F]] | Find |
| [[⌃Q]] [[A]] | Find and replace |
| [[⌃Q]] [[Y]] | Deletes to the end of the line |

## Blocks: ⌃K

| Keys | Does |
|---|---|
| [[⌃K]] [[B]] | Marks the start of the block |
| [[⌃K]] [[K]] | Marks the end of the block |
| [[⌃K]] [[V]] | Moves the block to the caret |
| [[⌃K]] [[C]] | Copies the block to the caret |
| [[⌃K]] [[Y]] | Deletes the block |
| [[⌃K]] [[H]] | Hides or shows the block |
| [[⌃K]] [[0]]–[[9]] | Sets a place marker |
| [[⌃K]] [[S]] | Saves now |

The second key can be typed with or without Control. If you pause after [[⌃K]] or [[⌃Q]], a card lists what may follow.

## The block that stays

This is the heart of WordStar, and the reason to use the mode. Mark a block and it stays marked, highlighted, while you move the caret anywhere. Nothing is on a clipboard waiting to be overwritten.

1. Put the caret at the start of the passage and press [[⌃K]] [[B]].
2. Go to its end and press [[⌃K]] [[K]].
3. Travel to where it belongs. Read around. Change your mind.
4. Press [[⌃K]] [[V]] to move it there, or [[⌃K]] [[C]] to copy it.

If you have a selection, [[⌃K]] [[B]] marks both ends at once.

**It works across chapters.** Mark a block in chapter three, open chapter nine, and press [[⌃K]] [[V]]: the passage moves there and leaves chapter three. [[⌃Q]] [[B]] takes you back to the block from wherever you are, opening its chapter if needed.

## Place markers

[[⌃K]] [[1]] drops marker 1 at the caret; [[⌃Q]] [[1]] returns to it, from any chapter. You have ten, 0 to 9. Use them as fingers in a book: one where you are writing, one on the scene you keep checking.

Blocks and markers last while Musset is open; they are not saved with the book.

## What is not there

Musset implements the WordStar a novelist uses, not the whole program. There is no insert/overwrite toggle ([[⌃V]]), no paragraph reformat ([[⌃B]]), no block to or from a file ([[⌃K]] [[W]], [[⌃K]] [[R]]), no print codes and no dot commands. Formatting is Markdown, with Musset's own shortcuts: [[⌘I]] for italic, [[⌘B]] for bold.

The other modes are described in [keyboard modes](/guide/keyboard-modes/).
