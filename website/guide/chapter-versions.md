---
title: Two versions of a chapter, side by side
short: Versions of a chapter
description: Write the same chapter two ways in Musset, read both next to each other with what differs marked, and choose which one goes in the book. Nothing is erased.
section: revise
order: 3
kind: How-to
---

## When to use a version

You are not sure the chapter should open at the funeral. Perhaps it should open the night before. The usual answer is to duplicate the file and promise yourself you will remember which copy is the real one.

In Musset a chapter can have several **versions**. One of them is in the book: it is the one that is counted, exported and read. The others wait beside it. You can write in any of them, and change which one is in the book as often as you like.

Use a version for one chapter. To try a change that runs through the whole book, use a [track](/guide/tracks/).

## Start a new version

1. Open the chapter.
2. Click the **version chip** beside the chapter's name at the top of the page, or right-click the chapter in the sidebar, and choose **New Version of This Chapter…**. The command is also in the command bar ([[⌘K]]).
3. Name the new version. The first time, you also name what you have already written; Musset proposes *First version*.
4. Choose where it starts:
   **A copy of what I wrote**, to keep the beginning and change what follows, or
   **A blank page**, with the other version open beside it to look at.
5. Click **Start**.

You are now writing in the new version. The book still has the old one until you decide otherwise.

## Know which version you are in

The chip beside the chapter's name tells you:

- a **filled green dot**: the version you are writing is the one in the book;
- a **hollow dot**: you are writing another version, and the book still has the one named in the tooltip.

Click the chip to move between versions. In the sidebar, a chapter with more than one version shows how many it has.

## Read two versions side by side

Click the chip and choose **Side by Side**. A second column opens beside the editor with another version of the chapter, read-only. In its header:

- a menu chooses which version is shown;
- **What differs** lights the paragraphs that are not, word for word, in the version you are writing;
- **Put in the Book** makes the version shown the book's own.

You can select and copy from the side column, and drag the divider between the two.

![Two versions of the same chapter side by side, with what differs highlighted](versions)

## Choose which version is in the book

When you are writing the version you want, click the chip and choose **Put « name » in the Book**. Musset confirms and offers **Undo** for a few seconds. The version the book had stays among the others; nothing is erased.

From then on, word counts, exports and your readers use the new version.

## Rename or remove a version

Both are in the chip's menu. **Move to the Trash** sends a version to the book's own Trash, where **Put Back** returns it. The version that is in the book cannot be moved to the Trash: put another one in the book first.

## Where versions live on disk

The version in the book is the chapter's own Markdown file. The others are Markdown files too, in `.musset/versions/` inside the book's folder, so they are in the book's [history](/guide/book-history/) and travel with [Musset Sync](/guide/musset-sync/).
