---
title: Musset Sync: the same book on every Mac
short: Musset Sync
description: Musset Sync keeps your books online with their whole history, on all your Macs, offline first. How to set it up, what the status bar says, and what happens when the same paragraph changes in two places.
section: share
order: 1
kind: How-to
---

## What Sync is, and what it is not

Musset is complete without an account. Your book lives on your Mac as plain files, with its whole [history](/guide/book-history/), and nothing leaves the machine.

**Musset Sync** is the optional service on top:

- your books online, with their whole history;
- the same book on all your Macs;
- [sharing a book](/guide/share-with-beta-readers/) with an editor or with beta readers, who do not pay.

It costs €4.99 a month in the euro area and $4.99 elsewhere, for all your books. Payment is handled by Stripe in your browser.

## Create an account and subscribe

1. Open **All Books** ([[⇧⌘H]]). The account is the left column. You can also choose **Sign In to Musset…** in the Musset menu.
2. Choose **Create an account** and enter your name as others will see it, your e-mail, and a password of ten characters or more.
3. Open **Plan and billing** and start Musset Sync, or click **Not synced** in the status bar of any book.
4. Pay in the browser window that opens. Musset updates by itself once the payment is confirmed.

Your password is not kept on the Mac: each Mac gets its own key, stored in the Keychain.

> A free account is enough to read and annotate the books other people share with you. Only putting your own books online needs Sync.

## Which books go online

By default, each book is sent to your account the first time you open it. It stays private: only the people you invite can open it.

To keep one book on this Mac only, right-click **Not synced** in its status bar and choose **Keep this book on this Mac only**. To stop sending books automatically, open **Plan and billing** and untick **Send my books to my account and keep them in sync**.

What is synced is what Musset owns in the book's folder: the chapters, the notes, the Bible, versions, tracks, milestones and settings. Any other file you keep in that folder is left alone.

## Get a book on a second Mac

1. Install Musset on the other Mac and sign in.
2. Open **All Books** ([[⇧⌘H]]) and choose **My books**.
3. Books that are online but not on this Mac have a **Download** button.

## Read the status bar

The bottom of the window tells you where the book stands. Click the word to open the book's sharing page.

| It says | It means |
|---|---|
| **In sync** | This Mac and your account hold the same book |
| **Syncing…** | Changes are going out or coming in |
| **Offline** | Your work is saved on this Mac and goes out when the connection returns |
| **N received as corrections** | The same paragraph changed in two places; see below |
| **Not synced** | The book is on this Mac only, or the last sync failed; the tooltip says why |

Sync runs when a book opens, when you come back to Musset, about two minutes after you stop typing, and every two minutes while Musset is in front.

## Work offline

Nothing about writing depends on the connection. Write on the train, and the book syncs when you are back. The history is kept locally either way.

## When the same paragraph changed on two Macs

You wrote on the laptop without a connection, then on the desktop before the laptop had synced. Musset never asks you to resolve a conflict, and it never shows you merge markers.

- A paragraph changed on one side only is taken from that side.
- A paragraph changed on both sides keeps **your** text, and the other one arrives as a [correction](/guide/track-changes/) with the comment *From another Mac*. Accept it or reject it like any correction.

The status bar says how many arrived that way. Notes and settings are merged item by item.

> One exception: a [track](/guide/tracks/) changed on two Macs is not merged. Sync tells you which one, and that track waits. Write in a given track on one Mac at a time.

## Privacy

Books are private on the server, and travel over HTTPS. They are not end-to-end encrypted: as the app itself says, someone administering the server could read them. If that matters for a book, keep it on this Mac only. The full list of what leaves your Mac is in [privacy](/guide/what-leaves-your-mac/).
