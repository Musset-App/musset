---
title: The plot grid: one row per scene, one column per thread
short: The plot grid
description: Outline a novel scene by scene in Musset's plot grid. Columns for the synopsis, the characters, the motifs, the subplot and what you are hiding, filled by you or proposed by the AI from your text.
section: structure
order: 3
kind: How-to
---

## What the grid is for

Halfway through a novel you need answers the text itself is too long to give. When did we last see the brother? Does the subplot vanish for nine chapters? Is the clue planted before it is found?

The **plot grid** answers them. It is a table with one row for every scene of the book, grouped by chapter, and one column for each thread you want to follow. Open it with [[⌘5]], or from the table icon at the bottom of the sidebar. Press [[⌘5]] again to return to your chapter.

The rows are your real scenes. They follow the text: rename a scene and its row is renamed; move a scene to another chapter and its row goes with it. The grid cannot drift away from the book.

## The columns

Three columns are fixed: the scene's name (click it to open the scene), its length, and its **status**.

Then come your own. A new book starts with:

| Column | Holds |
|---|---|
| **Synopsis** | What happens in the scene, in a sentence or two |
| **Characters** | Who is in it, as tags |
| **Motifs** | What recurs: the red scarf, the tide, the lie |
| **Subplot** | The second story's beat, if this scene has one |
| **Hidden plot** | What is really going on, that the reader does not know yet |
| **Notes** | Anything else |

The genre you chose for the book adjusts them. A crime novel gets *investigation*, *clues* and *false leads*; a fantasy gets *world* and *magic*; a romance gets *relationship* and *obstacles*; an essay gets *thesis*, *arguments* and *sources*.

Make the grid yours:

- **Add a column** with the **+** at the right of the toolbar.
- **Right-click a column's title** to rename it, move it left or right, or delete it.

Above each chapter's rows is a line for **what this chapter is for**. One honest sentence there is worth a great deal: a chapter you cannot justify is a chapter to look at.

## Fill it in

Click a cell and type. In a tag column, click **+** to pick a name from the book's index or add a new one. Each character and motif keeps one colour through the grid.

Fill it as you write, or afterwards, as a way of rereading the book structurally. You can also fill the open chapter's rows from the Plan panel ([[⌘6]]) without leaving the text.

## Follow one thread

Click a character's or a motif's tag. Every scene without it fades, and the toolbar counts the scenes that have it. You see at once where the brother disappears, or that the scarf appears twice in the first chapter and never again.

The **Index** button lists the book's characters and motifs with the number of scenes each appears in. Right-click a tag there to rename it, or to merge two that are the same person.

## Let the AI propose a first pass

If you use [the editor inside](/guide/ai-editor/), the **Update** button reads your scenes and fills the grid from what is on the page: what happens, who is there, which motifs appear. It describes; it does not judge or advise, and it writes nothing in your book.

- **Rebuild from the whole book** reads everything once and builds the index of characters and motifs.
- **Update changed scenes** reads only what changed since.

Three rules keep the grid yours:

- **A cell you wrote is never overwritten.** Cells filled by the AI are marked with a sparkle; edit one and it becomes yours.
- **You choose which columns the AI may fill.** Right-click a column's title and untick *The AI fills this column*. *Hidden plot* and *Notes* are yours alone from the start.
- **Everything works with the AI off.** The grid is then simply a table you keep.

An orange dot marks a scene whose text has changed since it was last read.

## How writers use it

- **Before writing**: with [planned chapters](/guide/chapters-and-scenes/#plan-chapters-you-have-not-written) and a synopsis, to see the shape.
- **Mid-draft**: to find where a thread was dropped.
- **Before revision**: fill *what this chapter is for* for every chapter. The ones that resist are where the revision starts.
- **For a mystery**: read down the *clues* and *false leads* columns in order. That is what your reader will know, and when.

## On disk

The grid is kept in `.musset/plot.json` in [the book folder](/guide/book-folder/), in the book's history.
