---
title: The editor inside: an AI that reads your book and never writes it
short: The AI reader
description: Musset's AI reads a chapter like a demanding editor: it quotes your sentence, says what it sees and asks a question. It never writes prose for your book. How to set it up with your own Claude or ChatGPT account, and how to turn it off.
section: revise
order: 7
kind: Guide
---

## A reader, not a writer

Most writing software with an AI offers to write for you. Musset refuses, on principle. Its AI is a **reader**: it tells you where a chapter drags, where a character contradicts chapter four, which image you have used three times. Finding the words stays your work.

This is built in, not a preference:

- Every request Musset sends carries the same instruction. In its own words: *"The author writes every word by hand: you are a critic and a writing partner, not a ghostwriter. Never propose rewritten passages, alternative sentences, replacement wording… Say what does not work, where, and why; point at what to look at; ask the questions that help the author find their own words."*
- The AI is given no way to change your files. It can read the book; it cannot write in it.
- **Everything else in Musset works with the AI off**: writing, structure, proofreading, history, export.

![The editor inside: a chat about the chapter, its notes left in the margin](chat)

## What it does

| You ask for | You get |
|---|---|
| [A reading of the chapter](/guide/ai-readings/) | Notes in the margin, each on the passage it is about |
| [A critique against a rubric](/guide/rubric-critique/) | A score by criterion, every claim backed by a quotation |
| [A check against your own rules](/guide/writing-rules/) | Each breach flagged, citing the rule |
| A conversation | A chat about the chapter or a selected passage |
| The outline filled in | [The plot grid](/guide/plot-grid/), from what is on the page |
| What the book says about a character | Facts from your chapters, in [the Bible](/guide/story-bible/) |

## Set it up

Musset has no AI of its own and holds no key. It uses **your own account** with the provider, through the provider's official tool on your Mac:

- **Claude**, with a Claude subscription;
- **ChatGPT**, with a ChatGPT subscription, through OpenAI's Codex tool.

1. Open the **AI Reader** panel ([[⌘3]]) and click **Choose an AI Reader…**, or open **Settings ▸ AI**.
2. Click **Sign in…** beside Claude or ChatGPT. If the provider's tool is not on your Mac, Musset offers to download it from the provider.
3. Finish signing in on the provider's page, in your browser.

There is no terminal to open and no key to paste. You pay your provider as you already do; Musset takes no margin and adds no usage fee.

## Choose the models

In **Settings ▸ AI**, each task has its own model: the conversation, the margin notes, the proofreading, the outline, the vocabulary, the Bible. A demanding model reads your chapter; a fast one checks typos as you type. The defaults are sensible, and you can change any of them.

## Talk about a chapter

Open the AI Reader panel ([[⌘3]]) and ask. Select a passage first to discuss only that. The reader can look at the other chapters to answer a question of continuity, and look something up on the web to check a fact.

When it points at passages, it offers to add them to the margin as notes, so the conversation leaves something you can work through.

## Three small exceptions, stated plainly

Musset never generates prose. Three tools do touch individual words, and each is yours to use or ignore:

- **AI proofreading**, if you turn it on, fixes obvious typos by itself, such as a doubled letter, and lists each fix with an **Undo**. It is off by default.
- **Synonyms**: right-click a word, ask for synonyms, and click one to replace the word.
- **Agree Tenses**: right-click and choose a tense; each changed verb comes back as a [correction](/guide/track-changes/) to accept or reject.

None of them writes a sentence.

## Check for machine-sounding prose

Editors and prizes increasingly run manuscripts through detectors. If you have your own key for Pangram, a third-party service, add it in **Settings ▸ AI**. The **AI readings** page then has **Check chapter**, which highlights the passages that read as machine-written, before an editor's tool does. Only the text you check is sent, and only when you click.

## What is sent, and when

Almost everything is sent only when you ask: a reading sends the chapter, a critique sends the book, a question sends your question and the chapter.

Three things can send text on their own, and each has its switch in Settings:

| Setting | Sends | Default |
|---|---|---|
| **The Bible ▸ Keep the Bible up to date** | A chapter, a few minutes after you finish working on it | On, once the AI is on |
| **Also proofread with AI** | The paragraph you just wrote | Off |
| **Have the AI check grammar alerts** | The sentences the grammar checker flagged | Off |

Requests go from your Mac to your provider, under your account and its terms. The full table is on [what leaves your Mac](/guide/what-leaves-your-mac/).

## Turn it off

**Settings ▸ AI** has one switch at the top. Off means off: no reader, no notes, no AI proofreading, no outline filling. The panels that depend on it disappear, and the rest of Musset is unchanged.
