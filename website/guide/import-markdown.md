---
title: Open a folder of Markdown files as a book
short: Coming from Markdown, Ulysses or Obsidian
description: Use Musset on a manuscript you already keep as Markdown files, from iA Writer, Obsidian, Ulysses or a plain folder. Open the folder in place, or import a copy; your files are not rewritten.
section: start
order: 5
kind: How-to
---

## Two ways in

If your book is already Markdown, you have a choice.

| | Open in place | Import a copy |
|---|---|---|
| **What happens** | The folder you choose becomes the book. Musset adds a hidden `.musset` folder to it. | Musset reads the folder and creates a new book folder elsewhere. |
| **Your files** | Stay where they are, with their names | Are not touched |
| **Use it for** | A folder that is already organised: iA Writer, Obsidian, your own | An export from Ulysses, or sheets grouped in sub-folders |
| **Command** | **File ▸ Open Book Folder…** ([[⌘O]]) | **New Book…** ([[⌘N]]), then the **Ulysses** tile |

## Open a folder in place

1. Choose **File ▸ Open Book Folder…** ([[⌘O]]) and select the folder.
2. Musset lists the chapters it found. Only they will appear in the app; nothing else in the folder is shown or touched.
3. Check the title and the **book language**.
4. Remove from the list any file that is not a chapter, and drag the others into order.
5. Leave **Keep this book's history** ticked, and click **Open Book**.

Musset looks for chapters in this order:

- `.md` files in the folder whose names start with a number, such as `01-arrival.md`, in numerical order;
- otherwise, the `.md` files of a sub-folder named `chapters` or `scenes`.

Each file is a chapter. Its title is its first `# ` heading, or its file name.

If nothing is found, the book opens empty and you add chapters from the sidebar. To help Musset, number your files before opening the folder.

**What Musset writes.** A hidden `.musset` folder with the book's settings, and, if you kept the box ticked, the book's history. If the folder had no history, Musset first records your files exactly as they are, so there is a point to return to. Your chapter files are not renamed or moved.

> The folder already uses git? Musset says so, saves the chapters in it before writing anything, and from then on commits only the files it owns. See [the book folder](/guide/book-folder/).

## From iA Writer

iA Writer keeps plain Markdown files in a folder. Number the chapter files, then open the folder in place. You can keep opening the same files in iA Writer; they stay ordinary Markdown.

## From Obsidian

A vault is a folder. If your manuscript is a sub-folder of the vault, open **that sub-folder** as the book, not the whole vault. Musset shows only the chapters and leaves your other notes alone.

Obsidian's own links (`[[Like this]]`) are left as text. Musset's boards are [JSON Canvas](https://jsoncanvas.org) files, the format of Obsidian's canvases, so a canvas you drew there can be read by both.

## From Ulysses

Ulysses keeps its sheets in a library of its own, so export first:

1. In Ulysses, select the group that holds the book and export it as **Markdown**, to a folder.
2. In Musset, choose **File ▸ New Book…** ([[⌘N]]) and click **Ulysses**, or drop the exported folder on that window.
3. Check the chapters, and click **Create book**.

How the export is read:

| In the folder | In Musset |
|---|---|
| A sheet at the top level | A chapter |
| A sub-folder (a group) | A chapter, named after the group |
| The sheets inside it | Its scenes |

Titles come from each sheet's first heading. Only one level of groups is read, so if your book is nested deeper, export each part separately or flatten it first.

The same route works for any folder of `.md`, `.markdown` or `.txt` files arranged that way.

## Scenes in your files

Musset marks a scene with a line of its own:

```
<!-- scene: Morning crossing -->
```

Files that do not have such lines are one scene each. Add them as you go with [[⇧⌘N]], or lay a chapter out as [scene cards](/guide/scene-cards/) and split it where you like.

A line of `* * *` or `---` is shown as a scene break on the page and printed as one.

## After opening

- Run **Write ▸ Apply Typography to the Whole Book…** if your files have straight quotes. See [automatic typography](/guide/smart-typography/).
- Read [Markdown for novelists](/guide/markdown-for-novelists/) for the few marks Musset uses. Links, images, tables and code are kept in the file and shown as plain text.
- Set a [milestone](/guide/milestones/) once the book looks right.
