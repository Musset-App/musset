---
title: Work with an editor who uses Word
short: An editor who uses Word
description: Send your book as a Word file with Track Changes on, and bring the editor's tracked changes and comments back into Musset as corrections and notes, even if you kept writing meanwhile.
section: revise
order: 6
kind: How-to
---

## The round trip

Most editors, agents and publishers work in Microsoft Word, and they will not change for your book. You do not have to leave your own tools for theirs.

1. You export the book from Musset as a Word file.
2. Your editor works in it as usual, with tracked changes and comments.
3. You bring the returned file into Musset. Each tracked change becomes a correction in your text, each comment a note in the margin.

You keep writing in between. Musset places the corrections on the text as it is today.

## Send the book

1. Choose **Export…** ([[⌘E]]).
2. Choose the layout **Word (.docx)**.
3. Choose what goes in: the whole book, the chapters with a given status, or the chapters you tick.
4. Click **Export DOCX**.

The file is laid out the way editors expect: A4, 2.5 cm margins, Times New Roman 12, line spacing 1.5, a header with your name and the title, page numbers. It uses named styles for chapter titles, scene breaks, block quotes and footnotes, so a publisher's template applies cleanly.

**Track Changes is already switched on** in the file, so nothing your editor does goes unseen, even if they forget to turn it on.

Musset keeps a record of exactly what it sent. That is what lets it understand the file that comes back.

> Corrections still waiting in your text are not sent: the Word file has the text as it stands without them. Decide them first if you want your editor to see the result.

## Bring the corrected file back

1. Choose **Bring In a Corrected Word File…**, just under Export in the menu, or from the command bar ([[⌘K]]).
2. Drop the `.docx` your editor sent back.
3. Check the summary. Musset shows when the file was exported, whose tracked changes Word found in it, and for each chapter how many corrections and comments it holds.
4. Under **From**, confirm who sent the file. Their name will sign each correction.
5. Click **Bring in**.

Nothing changes in your book before that last click. When you confirm, Musset sets a [milestone](/guide/milestones/) named *Before the corrections of* with the sender's name, so the book as it stood is one click away, and then opens the first chapter that has corrections.

## Decide each correction

The editor's changes are now ordinary [corrections](/guide/track-changes/): struck through, in green, signed. Go through them with [[⌥⌘]]] (next), [[⌥⌘↩]] (accept) and [[⌥⌘⌫]] (reject), or open the Notes panel on **Whole book** to see them all and filter by sender.

Their comments are notes in the margin, on the passage they were about:

- a comment that ends with a question mark becomes a *question*;
- replies in Word's thread come as replies under the note;
- a comment marked resolved in Word arrives already resolved.

Nothing prints until you accept it. Exports show your text without the pending corrections.

## If you kept writing in the meantime

This is the part most tools get wrong. Musset finds each correction's place in today's text by the words around it.

- A change you had already made yourself is recognised and skipped.
- A change whose passage you rewrote is not forced into the text. It becomes a note describing it, such as *« old » → « new »*, counted in the summary as **to place by hand**.
- Chapters you reworked heavily are flagged **rewritten since** in the summary, so you know where to look closely.

Bringing the same file in twice is safe: only what is not there yet is added.

## What comes back, and what does not

| Comes back | Does not |
|---|---|
| Insertions, deletions and replacements | Changes to fonts, colours and layout |
| Moved text, as a deletion and an addition | Changes to paragraph styles |
| Italic, bold, superscript and subscript on changed words | Edits to the title page, headers and footers |
| Added and edited footnotes | |
| Comments and their replies | |
| Paragraphs split, joined, added or removed | |

If your editor forgot Track Changes, or turned it off for a while, their edits are still found: Musset compares the returned text with what it sent.

A file Musset does not recognise as one of this book's exports can still be brought in. In that case only its tracked changes count.

One name signs each import. If two people marked up the same file, bring it in under the name of the person who sent it; the summary lists everyone Word found.
