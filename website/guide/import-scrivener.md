---
title: Move a Scrivener project to Markdown, with Musset
short: Coming from Scrivener
description: Open a .scriv project in Musset and get a folder of plain Markdown files: parts, chapters and scenes from the binder, synopses, comments, footnotes and italics. What comes across, what does not, and how to check.
section: start
order: 3
kind: How-to
---

## What you get

Musset reads a Scrivener project directly and makes a new book from its manuscript. Scrivener does not have to be open, or even installed, and the project is not modified: Musset works on a copy.

At the end you have a folder of Markdown files, one per chapter, with the binder's structure rebuilt as parts, chapters and scenes. From there the book is plain text, with every version kept, readable by any app.

It works with projects from Scrivener 3 and Scrivener 2.

## Import the project

1. In Musset, choose **File ▸ New Book…** ([[⌘N]]).
2. Under **Or pick up a book that already exists**, click **Scrivener**, and choose your `.scriv` project. You can also drop the project on that window.
3. Check the screen that follows. On the left: title, genre, language and author. On the right: the chapters Musset found, with their word counts.
4. Remove any chapter you do not want with the cross beside it.
5. Click **Create book**.

The title is taken from the project's name. Set the author and the book's language yourself: they are not read from the project.

## How the binder becomes a book

Musset reads the **Draft** folder, which Scrivener also calls Manuscript.

| In the binder | In Musset |
|---|---|
| A folder that contains folders | A **part** |
| Any other folder, or a document directly in the Draft | A **chapter** |
| The documents under a chapter, however deep | Its **scenes**, in binder order |
| A document's title | The scene's name |

So the usual Scrivener shape, a folder per chapter with a document per scene, arrives as you would expect: one chapter file, with each scene under its title.

## What comes across

| Scrivener | Musset |
|---|---|
| Text, paragraphs, italics and bold | As they are |
| Synopsis on an index card | The scene's **Synopsis** in [the plot grid](/guide/plot-grid/) |
| Inspector comments | A highlighted passage with its comment, in the text |
| Inline annotations | A comment in the text |
| Footnotes, inline and linked | Markdown footnotes |
| A style for quotations | A block quote |

Comments and annotations arrive as [revision comments](/guide/track-changes/), which you resolve or remove as you go.

## What does not

Musset's import brings the manuscript. It leaves the rest in your project, which stays intact:

| Scrivener | What happens |
|---|---|
| The Research folder | Not imported |
| Character and place sketches, front matter, templates | Not imported |
| Documents with **Include in Compile** unticked | Left out; the check screen tells you |
| Snapshots | Not imported |
| Labels, status, keywords, custom metadata | Not imported |
| Document notes | Not imported |
| Images in the text, and images or PDFs in the Draft | Not imported |
| Tables | Each cell becomes a paragraph |
| Fonts, sizes, colours, highlights, alignment | Not kept: Markdown has no such marks |
| Compile formats | Not needed; see below |

Two of these are worth a moment before you import:

- **Snapshots.** If an old snapshot matters, roll back or copy it into a document in Scrivener first. In Musset, [every state of every chapter is kept](/guide/book-history/) from the day you import.
- **Research and character sheets.** Drag the files you need onto [the Bible](/guide/story-bible/) once the book exists: PDFs, images and text files are accepted, and PDFs become searchable.

## After the import

1. **Read the sidebar.** Parts, chapters and scenes should mirror your binder.
2. **Tidy the typography.** Choose **Write ▸ Apply Typography to the Whole Book…** to set quotes, dashes and spaces by the rules of your language in one go. See [automatic typography](/guide/smart-typography/).
3. **Set a milestone** named *Imported from Scrivener*. See [milestones](/guide/milestones/).
4. **Keep the `.scriv` project** until you have exported once from Musset and are satisfied.

## Finding your way: Scrivener to Musset

| In Scrivener | In Musset |
|---|---|
| Binder | The sidebar: [parts, chapters, scenes](/guide/chapters-and-scenes/) |
| Corkboard | [Scene cards](/guide/scene-cards/), each holding the scene's whole text |
| Outliner | [The plot grid](/guide/plot-grid/) |
| Character and location sketches | [The Bible](/guide/story-bible/) |
| Snapshots | [The book's history](/guide/book-history/), kept without being asked, and [versions of a chapter](/guide/chapter-versions/) |
| Composition mode | [Focus, Kiosk and Ultra Focus](/guide/distraction-free-writing/) |
| Typewriter scrolling | The same, [[⇧⌘T]] |
| Split editor, Quick Reference | [Panes, tabs and windows](/guide/panes-and-windows/) |
| Revision mode, comments | [Revise mode and corrections](/guide/track-changes/) |
| Project targets | [A word goal for the book](/guide/word-count-and-goals/) |
| Compile | [Export](/guide/export-pdf-word-epub/): three layouts chosen for you, no settings to learn |
| Sync by Dropbox | [Musset Sync](/guide/musset-sync/), or no sync at all |
| The `.scriv` project | [A folder of Markdown files](/guide/book-folder/) |

## What is different, honestly

Musset is for the Mac only: there is no Windows version and no app for writing on a phone. Readers can read and annotate your book on an iPhone or iPad with Musset Reader, but you write on the Mac.

Musset has no Compile. That is deliberate: the export makes a correct submission manuscript for your country, a PDF to read and a PDF for a printer, without a format to design. If you rely on a finely tuned Compile format, check that the built-in layouts suit you before moving.

A fuller comparison is on [Musset and Scrivener](/compare/scrivener-alternative/).
