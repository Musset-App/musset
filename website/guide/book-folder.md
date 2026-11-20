---
title: The book folder: what Musset writes on disk
short: The book folder
description: A Musset book is a folder of Markdown files with a git history. What each file is, what Musset touches and what it leaves alone, and how to read the book without Musset.
section: reference
order: 2
kind: Reference
---

## A book is a folder

There is no project file and no database. A book is an ordinary folder that you can see in the Finder, copy to a USB key, back up with Time Machine, or open in any text editor.

```
The Salt Road/
├── 01_the_ferry.md          a chapter: plain Markdown
├── 02_the_salt_works.md
├── 03_low_tide.md
├── bible/                   characters, places, timeline, documents, cuts
└── .musset/                 hidden: everything about the book that is not its text
    ├── book.json            title, author, language, order of the chapters
    ├── notes/               margin notes, one file per chapter
    ├── versions/            other versions of a chapter
    ├── plot.json            the plot grid
    └── exports/             the PDFs, Word and EPUB files you made
```

The folder is by default in `Documents/Musset`. Choose another place when you create the book.

## The promise

Musset reads and writes three things in that folder: the **chapter files**, the **`bible/`** folder and the hidden **`.musset/`** folder. Anything else you keep there, research PDFs or a spreadsheet, is left alone: never changed, never added to the history, never synced.

Musset does not delete your files. A chapter you delete goes to the book's own Trash, where it can be put back.

## Chapters

Each chapter is one Markdown file. Its title is its first heading:

```
# The Ferry

The boat left at six, and she was not on it.

<!-- scene: Morning crossing -->

By the time the second ferry came…
```

- The number at the start of a file name is only a name. The order of the book is in `book.json`, so reordering chapters renames nothing.
- Renaming a chapter changes its heading, not its file name.
- A scene starts at a line `<!-- scene: Title -->`. It is a comment, so it never reaches the printed page.
- Parts are not folders: they are listed in `book.json`, and each chapter says which part it is in.

The marks Musset uses are described in [Markdown for novelists](/guide/markdown-for-novelists/).

## What is in `.musset`

| File or folder | Holds |
|---|---|
| `book.json` | Title, subtitle, author, language, word goal, the order and status of chapters, parts, the book's form, the cover and special pages |
| `notes/` | Margin notes, one Markdown file per chapter |
| `versions/` | The other [versions of a chapter](/guide/chapter-versions/) |
| `plot.json` | The plot grid and each scene's status |
| `dictionary.txt` | The book's own dictionary, one word per line |
| `rubric.md`, `checkers.json` | The AI reader's criteria and your own writing rules |
| `trash/` | Chapters in the book's Trash |
| `word-exports/` | What was sent to an editor in Word, to read their file when it returns |
| `exports/` | Exported PDFs, Word and EPUB files |

Some of it is only about this Mac and is kept out of the history and out of sync: `exports/`, the AI conversations, caches, and `state.json`, which remembers where your caret was and how your panes were arranged.

## The Bible

`bible/` is a visible folder, yours to read in the Finder. Sheets for characters and places are Markdown files; boards are [JSON Canvas](https://jsoncanvas.org) files, an open format other apps read. See [the Bible](/guide/story-bible/).

## The history

The book's folder is a git repository. Musset records a point about two minutes after you stop typing and at each structural change; see [the book's history](/guide/book-history/).

You never need git. If you do know it, it is all standard:

```
cd "The Salt Road"
git log --oneline
```

- Musset's commits start with `musset:`.
- [Milestones](/guide/milestones/) are tags, and [tracks](/guide/tracks/) are branches.
- Musset only commits the files it owns, and leaves alone anything you staged yourself.

## Read the book without Musset

This is the test of an open format, so here it is plainly:

- **Read or edit a chapter**: open the `.md` file in any text editor.
- **Get the whole text in order**: the order is the `chapters` list in `.musset/book.json`.
- **Convert it**: any Markdown tool works, [pandoc](https://pandoc.org) for example.
- **Go back in time**: any git client shows every state of every chapter.

If Musset disappeared tomorrow, you would lose an editor and keep a book.

## Move, copy, back up

- **Move a book**: move its folder in the Finder, then **File ▸ Open Book Folder…** ([[⌘O]]).
- **Copy a book**: duplicate the folder. The copy carries the whole history.
- **Back up**: any backup of the folder is a backup of everything. [Musset Sync](/guide/musset-sync/) keeps a copy online with its history, if you want one.
- **Remove a book from the library**: right-click its card in All Books ([[⇧⌘H]]). The folder is not deleted.

> Avoid putting a book's folder inside a folder that another service syncs file by file while you write on two machines at once. The text files cope well; the hidden git folder does not like being merged by a file-sync service.
