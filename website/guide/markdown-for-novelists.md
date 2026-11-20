---
title: Markdown for novelists: the little you need
short: Markdown for novelists
description: A novel needs very little Markdown: italics, a scene break, a footnote, a note to yourself. What Musset recognises, how it shows on the page, and the shortcut for each.
section: write
order: 4
kind: Reference
---

## Why plain text

A chapter in Musset is a Markdown file: ordinary text, with a few marks for what a typewriter could not do. You can open it in any editor, on any computer, in thirty years. Nothing about your book depends on Musset continuing to exist.

You do not have to learn Markdown to use Musset. Every mark has a shortcut, and the marks themselves fold away from the page. But it is your book in those files, and it helps to know what is in them.

## What a novel uses

| You want | You type | Shortcut |
|---|---|---|
| *Italic* | `*word*` | [[⌘I]] |
| **Bold** | `**word**` | [[⌘B]] |
| A scene break | [[↩]] twice, or `* * *` on its own line | [[⇧⌘N]] |
| A footnote | `^[The note.]` where the call goes | [[⌥⌘6]] |
| A quotation or a letter | `> ` at the start of the paragraph | [[⌥⌘']] |
| A heading | `# `, `## ` or `### ` | [[⌥⌘1]] [[⌥⌘2]] [[⌥⌘3]] |
| Back to body text | | [[⌥⌘0]] |
| A note to yourself | `<!-- check the date -->` | |
| A line break in a paragraph | | [[⇧↩]] |

That is all of it. All the commands are in the **Format** menu.

## How it looks on the page

The marks are faint in the paragraph you are writing and invisible everywhere else, so the page reads as text:

- italics are italic, bold is bold;
- a footnote is smaller and grey, in place;
- a quotation is set apart in grey italic;
- a note to yourself is small and faint.

## Scenes

A scene starts with a line of its own:

```
<!-- scene: Morning crossing -->
```

On the page it is a small centred title between two hairlines, and it never reaches the printed book: the reader sees the usual space or ornament between scenes. Scenes are what the sidebar, the scene cards and the plot grid are built on. See [chapters and scenes](/guide/chapters-and-scenes/).

You rarely type that line. Press [[↩]] on an empty paragraph and Musset makes it, or use **New Scene Here** ([[⇧⌘N]]).

## Notes to yourself

Anything between `<!--` and `-->` is an author's note. It can run over several paragraphs. It is never exported: not to PDF, not to Word, not to EPUB. Use it for the reminder that belongs exactly there: *she cannot know this yet*.

For remarks you want to list, tick off and filter, use margin notes instead ([[⌥⌘N]]). See [notes and todos](/guide/notes-and-todos/).

## Corrections

When you revise, your changes are written in the file in a notation called CriticMarkup, such as `{--cut this--}` and `{++add that++}`. Musset shows them as struck and green text. See [Revise mode and corrections](/guide/track-changes/).

## Lists and sub-headings, for non-fiction

A novel has no bullet lists, so by default a hyphen at the start of a line is a dialogue dash, and `1943.` opens a sentence. If your book needs them, turn them on in the book's settings, under **Structure ▸ In the text**:

- **Bullet lists**: a line starting with `-`, `*` or `+` and a space is an item. Return continues the list; [[Tab]] nests the item.
- **Numbered lists**: a line starting with `1.` opens a list.
- **Sub-headings**: `##` and `###` become sections that show in the sidebar and, for `##`, in the table of contents.

## Sources

Typing `[@` opens the list of your book's sources, and inserts a citation such as `[@woolf1929, p. 12]`. Sources are kept in the book's Bible.

## Paragraphs on disk

In Musset a paragraph is one line. In the file, paragraphs are separated by a blank line, as standard Markdown wants. Copying from Musset gives standard Markdown, and pasting it in works the same way.
