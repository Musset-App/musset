---
title: What leaves your Mac, and when
short: Privacy: what leaves your Mac
description: Musset keeps your book on your Mac. A plain list of every case in which text or data is sent somewhere: the AI you set up, Musset Sync, lookups you ask for, and the daily update check.
section: reference
order: 3
kind: Reference
---

## The short version

Out of the box, **nothing you write leaves your Mac**. There is no account to create, no analytics and no tracking. Your books, their history, the typography, the spelling and the grammar checking all run locally.

Text is sent somewhere only when you turn on a feature that needs it. This page lists every one.

## Always on your Mac

- Your books and everything about them: chapters, notes, the Bible, boards, versions.
- The book's history, milestones and tracks.
- Spelling and grammar: LanguageTool runs inside Musset.
- Typography, repetitions, statistics, word counts.
- The cast, and where each character appears.
- Typesetting and every export: PDF, Word, EPUB.

## The AI reader, if you set it up

Musset has no AI service of its own. Requests go from your Mac to **your** provider, under your own account and their terms: Anthropic for Claude, OpenAI for ChatGPT, or OpenRouter, which passes them to the model's maker. Musset sees none of it; a key you give it for OpenRouter or another server stays in the Keychain of your Mac.

With **Ollama** or **LM Studio**, the model runs on your Mac: what is listed below goes to it, and nothing leaves the Mac at all.

Sent **when you ask**:

| You do this | This is sent |
|---|---|
| Ask a question in the chat | Your question and the open chapter; the reader may read other chapters to answer |
| Run a reading, or Annotate | The chapter or the selection, and the notes already in the margin |
| Run the rubric critique | The whole book, the Bible's sheets, your synopsis and the rubric |
| Run one of your checkers | Your rules and the chapter |
| Update the plot grid | The scenes that changed, or the whole book for a rebuild |
| Ask for synonyms, or Agree Tenses | The word and its passage, or the selection |

Sent **on its own**, each with a switch in Settings:

| Setting | Sends | Default |
|---|---|---|
| **Settings ▸ AI ▸ The Bible ▸ Keep the Bible up to date** | A chapter, about three minutes after you stop working on it, to keep *What the book says* current | On, once the AI is on |
| **Settings ▸ Proofreading ▸ Also proofread with AI** | The paragraphs you just wrote | Off |
| **Settings ▸ Proofreading ▸ Have the AI check grammar alerts** | The sentences the grammar checker flagged, with their surroundings | Off |

To send nothing at all, turn off the switch at the top of **Settings ▸ AI**. See [the editor inside](/guide/ai-editor/).

## Musset Sync, if you subscribe

With a writer account, your books are stored on Musset's server so that they follow you and can be shared.

- **What is sent**: the chapters with their whole history, notes, the Bible, versions, tracks, milestones and the book's settings. Files in the book's folder that Musset does not own are never sent.
- **When**: by default, each book goes online the first time you open it. Keep one on this Mac with **Keep this book on this Mac only**, or untick **Send my books to my account and keep them in sync**.
- **Who can read it**: you, and the people you invite to that book. They never see your other books.
- **Encryption**: books travel over HTTPS and are private on the server. They are **not end-to-end encrypted**: someone administering the server could read them. Keep a book off Sync if that matters.
- **Your account**: your name, your e-mail and a password. The Mac keeps a key of its own in the Keychain, not your password.
- **Payment**: through Stripe, in your browser. Musset never sees your card.
- **Your name in the book**: once you are signed in, each point of the book's history carries your Musset user name, which is how [who wrote what](/guide/co-writing/) works. People you share the book with can see it.

A free reader's account sends what a reader does: notes, replies and reviews on the books shared with them. See [Musset Sync](/guide/musset-sync/).

## Things you look up

| You do this | This is sent, to whom |
|---|---|
| Search for a place on a place's sheet | The place you typed, to Apple Maps |
| Add a source by ISBN or DOI | The ISBN or DOI, to Open Library or Crossref |
| Save a web page to the Bible | A request for that page, to its website |
| Check a chapter for machine-sounding prose | The chapter or selection, to Pangram, with your own Pangram key |
| Choose languagetool.org as the grammar checker | The text being checked, to languagetool.org |

None of these happens unless you do it.

## The update check

Once a day Musset asks musset.app whether a newer version exists. The server adds one to a counter by day, version and country, and does the same for downloads. No address and no identifier is kept. The code that does it is [public](https://github.com/Musset-App/musset/tree/main/website/stats).

## Feedback you send

**Send Feedback** (at the foot of the sidebar, and in the Help menu) sends your message to the people who make Musset, not to a public page. It goes with your e-mail address if you give one, so we can answer, and, if you leave the box ticked, the details the sheet shows before you send: Musset's version, macOS, the kind of Mac, the interface language, the keyboard mode and which AI engines are set up (by name, never a key or an address). For a problem you can also attach Musset's latest crash report from the past week. Nothing from your books is sent. The message is kept on Musset's server and e-mailed to us.

## What Musset never does

- No analytics, no telemetry, no crash reports sent in the background.
- No advertising identifiers.
- No use of your text to train anything. Musset has no model of its own; for the AI you set up, your provider's terms apply.

## Check for yourself

Musset is open source. Everything on this page can be verified in [the code](https://github.com/Musset-App/musset), and the files the app writes are described in [the book folder](/guide/book-folder/). The website's own policy is on the [privacy page](/privacy/).
