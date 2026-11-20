---
title: Install Musset on your Mac
short: Install Musset
description: Download Musset, drag it to Applications and open it. What it needs (macOS 14, Apple silicon), how it updates, how to remove it, and how to build it from source.
section: start
order: 1
kind: How-to
---

## What you need

- A Mac with **Apple silicon** (M1 or later).
- **macOS 14 Sonoma** or later.

A build for Intel Macs is being tested; follow [issue 1 on GitHub](https://github.com/Musset-App/musset/issues/1) if you have one.

Musset is free while it is a beta. From version 1.0 it will cost US$9.90, once. It needs no account, and nothing you write leaves your Mac unless you ask for it.

## Install

1. [Download Musset](/download). You get a disk image, `Musset.dmg`.
2. Open the disk image and drag **Musset** onto **Applications**.
3. Open Musset from Applications or from Spotlight.

Musset is signed and notarized by Apple, so macOS opens it without a warning beyond the usual "downloaded from the internet" question.

## First launch

Musset asks one thing: **What is your book called?** A working title will do. From there you either start a new book, or pick up one that already exists in a folder, in Word, in Scrivener or in Ulysses.

- New book: follow [your first book in Musset](/guide/start-a-book/).
- Existing book: see [bringing a book in](/guide/import-word/), or the page for [Scrivener](/guide/import-scrivener/) or [Markdown, Ulysses and Obsidian](/guide/import-markdown/).

The interface is in English, French, German, Spanish, Italian or Portuguese; choose it from the globe at the top right of this first screen.

## Updates

Musset checks for a newer version once a day and offers to install it. To check now, choose **Musset ▸ Check for Updates…**.

The check sends no identifier: the server only adds one to a counter by day, version and country. See [what leaves your Mac](/guide/what-leaves-your-mac/).

## Where your books are

Musset does not hide your work in a library. Each book is an ordinary folder, by default in `Documents/Musset`, and you can put it anywhere: another disk, a folder you already back up. See [the book folder](/guide/book-folder/).

## Remove Musset

Drag Musset from Applications to the Trash. Your books are not inside the app and are not touched: they stay in their folders, readable by any text editor.

## Build it yourself

Musset is open source under the GPL v3. The [repository on GitHub](https://github.com/Musset-App/musset) explains how to build it with Xcode, and that stays true after version 1.0.

## Optional: the AI reader

Musset can read your chapters like an editor and leave notes in the margin. It never writes text for your book. This uses your own Claude or ChatGPT account and is off until you set it up; everything else works without it. See [the editor inside](/guide/ai-editor/).
