import Foundation

/// Watches a single file for on-disk changes and fires a callback (debounced,
/// on the main queue). Handles atomic saves (write-to-temp + rename, common in
/// editors) by re-arming when the watched inode is deleted or renamed: it polls
/// briefly until a file reappears at the same path, then rewatches it.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    /// Coalesces rapid successive writes into one reload.
    private let debounceInterval: TimeInterval = 0.15

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        guard arm() else { return nil }
    }

    deinit {
        stop()
    }

    /// Open the file and start a dispatch source watching it. Returns false if
    /// the file can't be opened.
    @discardableResult
    private func arm() -> Bool {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        self.source = source

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic save replaced the inode: rewatch the path once it reappears.
                self.rearmAfterReplace()
            } else {
                self.scheduleChange()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        return true
    }

    /// Tear down the current source (and its fd via the cancel handler).
    private func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    /// After the watched inode is deleted/renamed (typical of atomic saves),
    /// poll the path until a file exists there again, then rewatch and fire.
    private func rearmAfterReplace() {
        stop()
        pollForReplacement(attemptsLeft: 40)
    }

    private func pollForReplacement(attemptsLeft: Int) {
        if FileManager.default.fileExists(atPath: path), arm() {
            scheduleChange()
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollForReplacement(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
