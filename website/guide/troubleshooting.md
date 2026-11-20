---
title: Troubleshooting and common questions
short: Troubleshooting
description: Answers to what people ask most about Musset: recovering text, moving a book, Intel Macs, iPad and Windows, syncing, the AI reader, exports, and where to get help.
section: reference
order: 4
kind: Reference
---

## Recovering work

**I deleted a paragraph yesterday.** Open the History panel ([[⌘7]]), find the sitting, and click **Put Back**. Or type a few words of it in the search field, which searches even what no longer exists. See [the book's history](/guide/book-history/).

**I cut something and want it back.** Passages of a sentence or more that you cut are kept in the Bible's **Cuts** folder, with a button to put each back. See [the Bible](/guide/story-bible/#cuts-nothing-is-lost).

**I deleted a chapter.** It is in the book's **Trash**, at the bottom of the sidebar. Click **Put Back**.

**My whole revision went wrong.** In the History panel, choose **Go Back to This Sitting…** on the last good sitting. Nothing is erased: today's text stays in the history.

**Musset stopped while I was in Ultra Focus.** Reopen the book. What you wrote is put back, and the status pill says so.

**My Mac was lost or broke.** If the book was on [Musset Sync](/guide/musset-sync/), sign in on another Mac and download it. Otherwise restore the book's folder from your backup: the folder is the whole book, history included.

## Books and files

**Where is my book?** In the folder you chose when you created it, by default `Documents/Musset`. In **All Books** ([[⇧⌘H]]), right-click the book and choose **Reveal in Finder**.

**How do I move a book?** Move its folder in the Finder, then choose **File ▸ Open Book Folder…** ([[⌘O]]).

**Can I edit the files with another app?** Yes. Chapters are Markdown files. Avoid editing a chapter in two apps at the same moment.

**Can I keep the book in iCloud Drive or Dropbox?** The folder can live anywhere. A file-sync service handles the text files well; what it handles badly is the book's hidden history folder when two Macs write at once. For one Mac, or as a backup, it is fine. To write on two Macs, use Musset Sync.

**How do I delete a book?** Remove it from the library (right-click its card in All Books), then delete its folder in the Finder. Musset never deletes a folder itself.

**How do I back up?** Any backup of the book's folder is complete: Time Machine, an external disk, a copy.

## Macs, phones and other systems

**Does Musset run on an Intel Mac?** A build for Intel Macs is being tested; see [issue 1](https://github.com/Musset-App/musset/issues/1).

**Which macOS?** macOS 14 Sonoma or later.

**Is there an iPad or iPhone version?** Not for writing. Musset Reader, for iPhone and iPad, is for the people you share a book with: they read, annotate and talk with you. See [reading for an author](/guide/read-for-an-author/).

**Windows or Linux?** No. Musset is a Mac app. Your book is plain Markdown in a folder, so the text itself opens on any system.

## Writing

**The quotation marks are not the ones I want.** They follow the book's language and variant. Change it in the book's settings under **Book language**, or turn the rules off in **Settings ▸ Proofreading**. See [automatic typography](/guide/smart-typography/).

**Musset keeps flagging a name or an invented word.** Rest the pointer on the underline and choose **Add to the book dictionary**. See [spelling and grammar](/guide/spelling-and-grammar/).

**A hyphen at the start of a line turned into a dash.** In a novel, that is a dialogue dash. If your book needs bullet lists, turn them on in the book's settings under **Structure ▸ In the text**.

**⌘K does nothing.** The command bar belongs to an open book. On the All Books screen, open a book first.

**How do I get out of Kiosk mode?** Press [[⌃⌘K]] again. **Out of Ultra Focus?** Press [[⌃⌘U]]; if a lock is on, it opens when the goal is met. The Mac's Force Quit, [[⌥⌘Esc]], always works.

**In vi mode the arrow keys do nothing.** In NORMAL mode, move with the motions (`h` `l` `w` `b` `j` `k`). The arrows work in INSERT. See [vi keys](/guide/vi-keys/).

## Revising and sharing

**My editor's Word file will not import.** Use **Bring In a Corrected Word File…**, not New Book. It must be a `.docx`. If Musset says the file was not recognised as one of this book's exports, only its tracked changes are read. See [an editor who uses Word](/guide/word-track-changes/).

**The status bar says "Not synced".** Rest the pointer on it: the tooltip gives the reason. Without a subscription it simply means the book is on this Mac only.

**Sync says a track changed on two Macs.** Tracks are not merged. Write in a given track on one Mac at a time.

**My reader does not see my latest chapters.** Readers read a milestone, not your desk. Set a new milestone and tick their name. See [sharing a book](/guide/share-with-beta-readers/).

## The AI reader

**Is the AI required?** No. Everything except the readings, the critique, the checkers and the automatic filling of the outline works without it.

**It says I am not signed in.** Open **Settings ▸ AI** and sign in again beside the provider's name.

**Will it rewrite my text?** No. It reads, quotes, questions and annotates. See [the editor inside](/guide/ai-editor/).

**Does it cost extra?** Musset charges nothing for it. It uses your own Claude or ChatGPT subscription.

## Exports

**Where did my export go?** Into the book's folder, under `.musset/exports/`. Musset shows it in the Finder when it is done.

**Can I change the font or the margins of the PDF?** No; the layouts are made to be correct without settings. For your own design, export Word: its named styles flow into InDesign or a template. See [typeset a book](/guide/typeset-a-book/).

**My corrections are missing from the PDF.** Corrections you have not decided are never exported: the PDF shows the text without them. Accept them first. See [corrections](/guide/track-changes/).

**The exported file has my real name in its title, and I am entering a blind competition.** The pseudonym replaces your name on the pages. Rename the file before sending it.

## Getting help

- Write to **hello@musset.app**.
- Report a bug or ask for a feature on [GitHub](https://github.com/Musset-App/musset/issues).
- The [support page](/support/) has the basics for Musset Reader.

When you report a problem, say which version of Musset you have (**Musset ▸ About Musset**) and which macOS.
