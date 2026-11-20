---
title: Turn a Word manuscript into chapters and scenes
short: Coming from Word
description: Bring a .docx manuscript into Musset. It is cut into chapters at its headings, or at the habit your chapter titles follow, and into scenes at its * * * breaks. The original file is not changed.
section: start
order: 4
kind: How-to
---

## One long document, cut where it should be

A novel written in Word is usually one long file. Musset reads it and cuts it into what a book is made of: one chapter per file, with scenes inside.

Your `.docx` is not changed. Musset works on a copy and creates a new book folder.

## Import the manuscript

1. In Musset, choose **File ▸ New Book…** ([[⌘N]]).
2. Under **Or pick up a book that already exists**, click **Word** and choose your `.docx`. You can also drop the file on that window.
3. Check the title, the genre, the **book language** and the author on the left. The title comes from the file's name; set the language yourself.
4. On the right, check the list of chapters Musset found, with their word counts.
5. Click **Create book**.

Musset reads `.docx` files. Open an older `.doc`, an `.rtf` or an OpenDocument file in Word or Pages and save it as `.docx` first.

## How Musset finds your chapters

**If you used Word's heading styles**, it is simple: each *Heading 1* is a chapter, and each *Heading 2* a named scene inside it.

**If you did not**, like most novelists, Musset looks for your habit. Chapter titles in a manuscript nearly always share something: they come after a page break, they are centred, they are numbered (*Chapter 12*, *XII*, *Twelve*), or they are in bold or capitals. Musset finds the combination your manuscript repeats and tells you which one it used.

A line that stands out only once, a dedication or a part's title, is listed apart as **Marked, but alone: not a chapter**, with a button to make it one.

## Correct the cut

The check screen is where you fix what the reading missed:

- Click the cross beside a chapter to merge it with the one before.
- Click **Make it a chapter** on a line Musset set apart.
- Tick **Show the text** to see every paragraph of the document on a line; click any line to start a chapter there.

Text before the first chapter title is kept as a chapter named *Opening*.

## Scenes

A line that holds only a mark, `* * *`, `***`, `#` or `⁂`, becomes a scene break. Blank lines alone do not make scenes, because manuscripts use them for too many things.

Once the book exists, you can add scenes anywhere with [[⇧⌘N]], or lay a chapter out as [scene cards](/guide/scene-cards/) and split it by hand.

## What is kept

| In Word | In Musset |
|---|---|
| Italics and bold | Kept |
| Footnotes | Kept, as Markdown footnotes |
| Block quotes, bulleted and numbered lists | Kept |
| Tables | Kept as Markdown tables |
| Tracked changes | Accepted: insertions stay, deletions go |
| Comments | Not imported |
| Images | Not imported |
| Fonts, sizes, colours, underline, alignment | Not kept: the text becomes plain Markdown |

Two things to do in Word before you import:

- **Decide your tracked changes**, or accept that Musset keeps the text as if all were accepted.
- **Check your footnotes afterwards.** In a book with many, open the last chapter and make sure each note sits with its chapter.

> If an editor has sent *back* a Word file with corrections on a book you already have in Musset, do not import it as a new book. Use **Bring In a Corrected Word File…**: their tracked changes become corrections in your text. See [an editor who uses Word](/guide/word-track-changes/).

## After the import

1. **Tidy the typography.** Word files carry a mix of straight and curly quotes and odd spaces. Choose **Write ▸ Apply Typography to the Whole Book…**. See [automatic typography](/guide/smart-typography/).
2. **Look at the shape.** Press [[⌘4]] for one bar per chapter, as tall as the chapter is long.
3. **Set a milestone** named *Imported from Word*; see [milestones](/guide/milestones/).

From here on, every state of every chapter is kept in [the book's history](/guide/book-history/), and you can still [send a Word file](/guide/word-track-changes/) to anyone who asks for one.
