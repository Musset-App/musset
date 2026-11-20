---
title: Offline spelling and grammar checking in six languages
short: Spelling and grammar
description: Musset checks spelling and grammar with LanguageTool running inside the app, on your Mac: nothing is sent anywhere. What the underlines mean, how to accept a fix, and the book's own dictionary.
section: write
order: 6
kind: How-to
---

## A checker that stays on your Mac

Musset proofreads as you write, in the book's language: English, French, German, Spanish, Italian or Portuguese. The checker is [LanguageTool](https://languagetool.org), and it runs **inside Musset, on your Mac**. Your manuscript is not sent to a server to be checked, and it works on a plane.

It is tuned for fiction. Musset keeps LanguageTool's spelling, grammar and doubled-word checks, and drops its opinions on style, commas and register, which fight literary prose. It also:

- leaves capitalised words alone, since they are mostly your characters and places;
- leaves sentences in another language alone, so the English dialogue in a French novel is not a page of errors.

## What the underlines mean

Paragraphs are checked a couple of seconds after you stop typing. Underlines are dotted, in three colours:

| Colour | Source |
|---|---|
| **Blue** | The grammar checker. Never applied on its own. |
| **Red** | An obvious slip, such as a missing accent, about to be fixed when you leave the paragraph. |
| **Purple** | A suggestion from the AI, if you turned AI proofreading on. |

The pill at the bottom of the page counts what is waiting.

## Accept a suggestion

There are three ways, for three kinds of people.

**With the mouse.** Rest the pointer on an underline. A card explains the rule and offers up to five replacements; click one to apply it. Or choose:

- **Correct It Myself…** to type your own;
- **Keep as Written** to dismiss it for good;
- **Add to the book dictionary** to teach Musset the word;
- **Never Flag This Rule in This Book** to silence the rule.

A right-click on the underline offers the same choices.

**From the keyboard.** Press [[⌘;]] (**Write ▸ Next Proofreading Suggestion**). Musset jumps to the next underline and opens its choices. Press it again for the one after.

**As a list.** Open the Notes panel ([[⌘2]]). Each issue is a row you can tick to apply.

Every correction can be undone with [[⌘Z]].

## Obvious mistakes, fixed for you

With **Fix obvious mistakes** on, Musset corrects a small set of slips by itself, outside the paragraph you are writing: in French, a missing accent or ligature with only one possible answer, such as *soeur* to *sœur*.

Each automatic fix is listed in the Notes panel with an **Undo** button. Undoing one also tells Musset not to make it again.

## The book's dictionary

Invented words, dialect and names belong to a book, so the dictionary does too. Choose **Write ▸ Dictionary & Exceptions…** to see and edit three lists:

- the **book dictionary**;
- what you chose to **keep as written**;
- the **grammar rules switched off** for this book.

They are saved with the book, in its `.musset` folder, and travel with it to your other Macs and into its history.

## Settings

Open **Settings ▸ Proofreading**.

| Setting | What it does |
|---|---|
| **Proofread while I write** | Underlines mistakes, paragraph by paragraph |
| **Fix obvious mistakes** | Applies the certain ones outside the paragraph being written |
| **The book's typography** | Quotes, apostrophes and spaces; see [automatic typography](/guide/smart-typography/) |
| **Grammar checker** | LanguageTool on this Mac, another LanguageTool server, or off |
| **Also proofread with AI** | Sends the current paragraph to the AI. Off by default. |
| **Have the AI check grammar alerts** | Shows a grammar alert only if the AI confirms it. Off by default. |

## The optional AI

A rule-based checker cannot tell what a sentence means, so it sometimes flags a correct agreement. If you use [the editor inside](/guide/ai-editor/), you can let the AI confirm grammar alerts before they are underlined: fewer false alarms, at the price of sending those passages to your AI provider. Both AI options are off unless you turn them on.

## Other tools on a word

Right-click a word for **Synonyms**, **Homonyms** and **Alliterations**. These use the AI too, and appear when it is on.
