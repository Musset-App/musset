---
title: Version history for a book: get back anything you wrote
short: The book's history
description: Musset keeps every state of every chapter as you write. How to find a sentence you deleted, put a paragraph back, compare a chapter with an earlier day, or take the whole manuscript back.
section: revise
order: 1
kind: How-to
---

## What Musset keeps, and when

You never save a copy of a chapter in Musset, and you never rename a file `final-v3`. The text is written to disk as you type, and Musset adds a point to the book's history on its own:

- two minutes after you stop typing;
- when you leave a chapter for another one;
- when you switch books or quit;
- at once for anything that reshapes the book: moving a chapter, splitting a scene, renaming a character, bringing in an editor's corrections.

To add a point yourself, choose **Write ▸ Save Now** ([[⌘S]]). It shows in the history as *Saved by hand*.

Points less than 45 minutes apart are shown together as one **sitting**, which is how you remember your work anyway: Tuesday morning, Thursday night.

> The history is an ordinary git repository inside the book's folder. You never have to see it, and you need neither git nor Xcode's tools installed. If you know git, everything in it is yours to read. See [the book folder](/guide/book-folder/).

When you first open a folder as a book, Musset asks whether to keep its history. Leave the box ticked: versions, tracks and milestones all depend on it.

## Open the history

Choose **View ▸ History** ([[⌘7]]). The panel opens on the right, with a switch at the top for what you are looking at:

| Scope | What it shows |
|---|---|
| **Selection** | The past states of the paragraph you selected in the text |
| **Chapter** | Every sitting that touched the open chapter |
| **Several…** | The chapters you tick |
| **Book** | Every sitting, whatever the chapter |

Each sitting is a row with its date and the words added and removed. Open one to see each change: a minus for what was removed, a plus for what was added, a tilde for what was reworded.

## Put a deleted paragraph back

1. Open the History panel ([[⌘7]]) and set the scope to the chapter.
2. Open the sitting in which the paragraph went. To narrow the list, use the filter menu and choose **Removed**.
3. Click **Put Back** beside the removed text.

The paragraph returns where it was, and [[⌘Z]] undoes it. If the text around it has changed since, Musset asks where it should go: where it is now, after or before a sentence that still exists, or at the end of the chapter.

The same row offers **Remove** for text that was added in that sitting, and **Put the old one back** for a sentence that was reworded.

## Find a sentence that no longer exists

The search field at the top of the panel reads **Search, even what no longer exists**. Type three letters or more of anything you remember: a name you later changed, an image you cut.

Musset shows the life of the phrase, with dates: *Written*, *Reworked*, *Removed*, *Back*. From there, **Put Back** returns a removed passage, and **Open that day's text** shows the chapter as it stood.

## See how one paragraph changed

Select a passage in the editor, then set the scope to **Selection**. The panel lists the paragraph as it is now and each earlier state with its date. **Put this one back** restores the one you prefer.

This is the quickest way to answer the question every reviser asks at midnight: was it better before?

## Compare a chapter with an earlier day

Click a chapter's name inside an open sitting, or choose **Compare with Today** on a sitting in the book's history. A window opens with two views:

- **Changes** shows one text, with removed words struck in red and added words in green;
- **Side by Side** shows the past text on the left and today's on the right.

The comparison is always between a past moment and today's text.

## Go back to a past sitting

Sometimes a week of revision went the wrong way. On any sitting, open the **…** menu and choose **Go Back to This Sitting…**. Musset asks what should come back:

- the open chapter;
- the chapters you ticked;
- the whole manuscript and the order of its chapters.

It shows how many chapters and words change, and offers **See the differences…** first. Notes, the Bible and the book's settings do not move.

Going back erases nothing. Musset sets a [milestone](/guide/milestones/) named *Before going back to* with the date, then writes the old text as a new point in the history. If you change your mind, today's text is one sitting away.

To take only some paragraphs from a past sitting, choose **Bring this sitting…** instead. You get the same paragraph-by-paragraph window used for [tracks](/guide/tracks/).

## The book's history, as a picture

For the whole view, open the command bar ([[⌘K]]) and choose **The Book's History**, or click the expand button of the History panel. A timeline shows the manuscript as a line with a dot for each sitting, milestones as flags above it, and tracks branching below and coming back. It covers the last three months.

## Chapters you deleted

Deleting a chapter moves it to the book's own **Trash**, at the bottom of the sidebar. The file stays in the folder with its notes and versions; the book only stops counting it. **Put Back** returns it to its place.

**Delete for Good…** sends the file to the Finder's Trash. After that Musset has no button to bring the chapter back, so empty the book's Trash only when you are sure. A [milestone](/guide/milestones/) set before a big clean-up lets you export the whole book as it stood that day.
