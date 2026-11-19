import Foundation
import Dispatch

final class MarkdownFileWatcher {
    private let url: URL
    private let callback: (String) -> Void
    private let queue = DispatchQueue(label: "MarkdownFileWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var cancelled = false
    private var needsReopen = false

    init(url: URL, callback: @escaping (String) -> Void) {
        self.url = url
        self.callback = callback
        queue.async { [weak self] in self?.openAndRead(retries: 10) }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            pending?.cancel()
            source?.cancel()
            source = nil
        }
    }

    deinit { source?.cancel(); pending?.cancel() }

    private func openAndRead(retries: Int) {
        guard !cancelled else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if retries > 0 { queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.openAndRead(retries: retries - 1) } }
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: queue)
        watcher.setCancelHandler { close(fd) }
        watcher.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.needsReopen = self.needsReopen || !watcher.data.intersection([.delete, .rename]).isEmpty
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.cancelled else { return }
                if self.needsReopen { self.needsReopen = false; self.source?.cancel(); self.source = nil; self.openAndRead(retries: 10) }
                else { self.read() }
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        source = watcher
        watcher.resume()
        read()
    }

    private func read() {
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async { [weak self] in self?.callback(text) }
    }
}
