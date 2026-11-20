---
title: Chapters, scenes and parts: give the book its shape
short: Chapters, scenes and parts
description: How to organise a novel in Musset: add and reorder chapters, cut them into scenes, group them in parts, mark each one draft, done, edited or final, and set chapters aside without deleting them.
section: structure
order: 1
kind: How-to
---

## Three levels

A book in Musset has up to three levels, and you use as many as the book needs:

- **parts**, which group chapters;
- **chapters**, one file each;
- **scenes**, inside a chapter.

They are all in the sidebar ([[⌘1]]): parts as headings, chapters under them, and each chapter unfolding to its scenes. A collection, a journal or a play uses other words for the same levels; you choose them with [the book's form](/guide/start-a-book/).

## Chapters

**Add a chapter.** Click **+** at the bottom of the sidebar and give it a title. It is added at the end of the book.

**Split a chapter where you are.** In the text, press [[↩]] three times in a row: the first makes a paragraph, the second a scene, the third cuts the chapter there, and what follows becomes the next chapter. [[⌘Z]] puts it back together.

**Reorder.** Drag chapters in the sidebar. Nothing is renamed on disk; the order is kept in the book's settings file.

**Rename.** Right-click the chapter and choose **Rename…**, or simply edit the title at the top of the chapter's text.

**Open two at once.** [[⌘]]-click a chapter to open it in the next pane, [[⌥]]-click to open it in a new tab. See [panes, tabs and windows](/guide/panes-and-windows/).

## Scenes

A scene is a stretch of a chapter with a title of its own: a change of place, of time, of point of view. Scenes are how Musset lets you see and move the pieces of a chapter without cutting it into files.

**Start a scene as you write.** Press [[↩]] on an empty paragraph. Musset names the scene *Scene 2*, *Scene 3* and so on, in the book's language; click the title to change it. [[⌫]] at once removes the marker.

**Start a scene in existing text.** Put the caret in the paragraph where the scene begins and choose **Write ▸ New Scene Here** ([[⇧⌘N]]). Type its title.

**Rename a scene.** Edit its title in the text, or right-click the scene in the sidebar and choose **Rename Scene…**. Two scenes of the same chapter cannot share a title.

**Split, merge and move scenes.** That is best done with the chapter laid out as [scene cards](/guide/scene-cards/).

On the page, a scene's title is a small centred line between two rules. It never prints: in the book the reader sees the space or ornament you chose for scene breaks. In the file it is one line, `<!-- scene: Title -->`.

> With the AI reader on, **Propose Scenes…** (right-click a chapter) reads a long unbroken chapter and suggests where its scenes begin. You tick the ones you want and Musset inserts the markers. It does not touch the text.

## Parts

For a book in parts, choose the form **Novel in parts** when you create it, or later in the book's settings under **Structure**.

**Create a part.** Right-click the chapter that opens it and choose **Part ▸ New Part Starting Here**. The part takes that chapter and those that follow. Right-click chapter 1, then chapter 8, and you have parts I and II.

**Name a part.** Right-click its heading and choose **Name…**. The numeral (I, II, III) follows the order of the parts.

**Move a chapter to another part.** Drag it under that part's heading, or use the **Part** menu.

**Remove a part.** Right-click its heading and choose **Delete Part (Chapters Stay)**. Only the grouping goes.

## A prologue, an interlude, an epilogue

Some pieces carry a name instead of a number. Right-click a chapter and choose **Unnumbered ▸ Prologue**, **Interlude** or **Epilogue**. They go where you like and do not shift the numbering of the chapters around them. Add your own kinds (*Letter*, *Coda*) in the book's settings.

## Status: draft, done, edited, final

Every chapter has a status, shown as a coloured dot:

| Status | Meaning |
|---|---|
| **Draft** | Being written |
| **Done** | First version finished |
| **Edited** | Revised after critique |
| **Final** | Ready, nothing more to change |

Set it from the dot in the title bar of the chapter, or by right-clicking the chapter in the sidebar. Scenes have a status too.

Statuses are more than decoration. You can export only the chapters with a given status, and [share with a reader](/guide/share-with-beta-readers/) only what is *Edited* or *Final*. The bottom of the sidebar and the Stats panel show how much of the book stands where.

## Strands

A novel that alternates two periods or three narrators can give each chapter a **strand**: *1943*, *Now*, *Claire*. Create strands in the book's settings under **Structure ▸ Strands**, then right-click a chapter and choose **Strand**. The book's overview colours the chapters by strand and can show one strand alone, so you can read 1943 straight through and check that it holds.

## Set a chapter aside: Drafts

A chapter you are not sure belongs in the book does not have to be deleted. Right-click it and choose **Move to Drafts**, or drag it onto **Drafts** at the bottom of the sidebar.

A chapter in Drafts stays a file with its notes and versions. It only stops being counted and exported. To return it, drag it back to its place in the list, or right-click and choose **Put in the Book**.

To keep a chapter in the book but out of an export, right-click it and choose **Exclude from export**.

## Delete a chapter

Right-click and choose **Move to Trash**. The chapter goes to the book's own Trash, under Drafts, where **Put Back** returns it to its place. See [chapters you deleted](/guide/book-history/#chapters-you-deleted).

## Plan chapters you have not written

On the **Synopsis** page, add **planned chapters**: a title and what the chapter will do. They appear greyed in the sidebar in their place, so the book's shape is visible before the text exists. **Start writing** turns one into a real chapter.
