import Foundation

/// When the book's folder is committed: a while after the author stops writing, at once when something is done in
/// one go (a rename, a move), and always one commit at a time.
extension BookSession {
    /// Something was written in the book's folder: it is committed once the author has been idle for a while.
    func scheduleCommit() {
        pendingCommit = true
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.commitIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.commitIfPending(message: self.editMessage, background: true)
        }
    }

    /// The name of a commit of what was just written: the chapter that was saved, whichever pane it is in.
    var editMessage: String { "musset: edit \(lastSaved ?? selectedChapterID ?? "")" }

    func commitIfPending(message: String, background: Bool = false) {
        guard pendingCommit else {
            // Nothing to commit, but a commit sent to the background may still be on its way: whoever asks in
            // place (the sync, the history, quitting) reads the repository next, and finds it there.
            if !background { settleCommits() }
            return
        }
        commitTask?.cancel()
        if background { commitInBackground(message) } else { commitNow(message) }
    }

    /// Waits for the commits sent to the background.
    func settleCommits() { gitQueue.sync {} }

    func commitNow(_ message: String) {
        lastSaved = nil
        guard git.isRepo else { pendingCommit = false; return }
        if piste != nil { commitPiste(message); return }
        let git = git, paths = trackedPaths
        do {
            committed(try gitQueue.sync { try git.commit(paths: paths, message: message) })
        } catch {
            lastError = "git: \(error.localizedDescription)"
        }
    }

    /// The same, off the main thread: a commit takes ~100 ms on a real book, and leaving a chapter one
    /// has just written in must not wait for it.
    func commitInBackground(_ message: String) {
        lastSaved = nil
        guard git.isRepo else { pendingCommit = false; return }
        // A track's commit touches no files and takes a few milliseconds.
        if piste != nil { commitPiste(message); return }
        pendingCommit = false
        let git = git, paths = trackedPaths
        gitQueue.async { [weak self] in
            let result = Result { try git.commit(paths: paths, message: message) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let made): self.committed(made)
                case .failure(let error): self.lastError = "git: \(error.localizedDescription)"; self.pendingCommit = true
                }
            }
        }
    }

    private func committed(_ made: Bool) {
        // A later commit went through: the earlier failure no longer holds.
        if lastError?.hasPrefix("git:") == true { lastError = nil }
        if made {
            lastCommitAt = Date()
            // A shared book follows the author's saves on the server.
            Collab.shared.sync(self)
        }
        pendingCommit = false
    }
}
