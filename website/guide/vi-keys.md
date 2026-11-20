---
title: vi keys for prose: sentences and paragraphs as text objects
short: vi keys
description: Musset's vi mode has normal, insert and visual modes, with motions and text objects that understand sentences and paragraphs. The complete list of what is implemented, and what is not.
section: write
order: 9
kind: Reference
---

## vi, for sentences

If vi is in your fingers, writing prose anywhere else feels like wearing mittens. Musset's vi mode gives you the modal editing you know, adapted to prose: `j` and `k` move by paragraph, and sentences and paragraphs are text objects.

Turn it on in **Settings ▸ Keyboard ▸ vi**. A chapter opens in NORMAL mode; the state shows at the bottom right of the page, and the caret is a block outside INSERT.

It is a subset of vi, chosen for writing. The lists below are complete: if a command is not here, it is not implemented.

## Modes

| Key | Does |
|---|---|
| [[i]] · [[a]] | Insert before · after the caret |
| [[I]] · [[A]] | Insert at the start · end of the paragraph |
| [[o]] · [[O]] | Open a paragraph below · above |
| [[v]] · [[V]] | VISUAL · VISUAL LINE (whole paragraphs) |
| [[Esc]] or [[⌃[]] | Back to NORMAL |

In INSERT, every key is ordinary typing, with Musset's typography and lists.

## Motions

| Key | Moves to |
|---|---|
| [[h]] · [[l]] | Left · right one character |
| [[w]] · [[b]] · [[e]] | Next word · previous word · end of word |
| [[(]] · [[)]] | Previous · next sentence |
| [[{]] · [[}]] | Previous · next paragraph |
| [[j]] · [[k]] | Next · previous paragraph |
| [[0]] · [[$]] | Start · end of the paragraph |
| [[gg]] · [[G]] | Start · end of the chapter |
| [[⌃D]] [[⌃F]] · [[⌃U]] [[⌃B]] | Page down · page up |

A count works before a motion or a command: `3w`, `2dd`.

> In prose a "line" is a paragraph. `j`, `k`, `0`, `$`, `dd` and `yy` all act on whole paragraphs, however they wrap on screen. In NORMAL mode, move with these motions; the arrow keys are for INSERT.

## Operators and text objects

`d` deletes, `c` changes, `y` yanks. Follow one with a motion (`dw`, `c)`, `y}`, `d$`) or with a text object:

| Object | Is |
|---|---|
| `iw` · `aw` | The word · the word and the space after it |
| `is` · `as` | The sentence · the sentence and the space after it |
| `ip` · `ap` | The paragraph |

Doubled, an operator takes whole paragraphs: `dd`, `cc`, `yy`.

These are the commands that make vi worth having for a novel:

| You type | It does |
|---|---|
| `cis` | Rewrite this sentence |
| `das` | Delete this sentence, and close the gap |
| `yip` | Copy this paragraph |
| `d)` | Delete to the end of the sentence |
| `dap` then `}` then `p` | Move this paragraph down one |

A word includes its apostrophe, and a sentence of dialogue followed by its *she said* is one sentence.

## Other commands

| Key | Does |
|---|---|
| [[x]] · [[X]] | Delete the character under · before the caret |
| [[p]] · [[P]] | Put after · before the caret |
| [[u]] · [[⌃R]] | Undo · redo |
| [[.]] | Repeat the last delete or put |
| [[~]] | Switch the case of the character |
| [[/]] | Open the find bar |
| [[n]] · [[N]] | Next · previous match |
| [[:]] | Open the [command bar](/guide/command-bar/) |

Yanks and deletes also go to the Mac's clipboard, so [[⌘V]] in another app has them.

`:` opens Musset's command bar rather than an ex line. Type the name of what you want: a chapter, *export*, *focus*.

## What is not there

Not implemented: `r` and `R`, `s` and `S`, `C`, `D`, `Y`, `J`, the find-character motions (`f`, `t`, `;`, `,`), `%`, `^`, marks, named registers, macros, block visual mode, ex commands, and a line number before `G`. The indent operators `>` and `<` do nothing: prose has no indentation to shift. The `.` command repeats deletes and puts, not changes made with `c`.

If you miss one of these in daily writing, [tell us](https://github.com/Musset-App/musset/issues): the mode grows from what writers ask for.

## With the rest of Musset

- [[⌘]] shortcuts work in every mode: [[⌘K]], [[⌘S]], [[⌘F]].
- In [Revise mode](/guide/track-changes/), what `d` and `c` do becomes corrections, like any other edit.
- In [Ultra Focus](/guide/ultra-focus/), there are no modes: only forward.

See [keyboard modes](/guide/keyboard-modes/) for the three others.
