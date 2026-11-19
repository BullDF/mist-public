// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Foundation

/// Owns the agent socket. First-party agents are admitted independently;
/// identified external peers require the Advanced agent-control switch.
final class AgentCDPListener {
    static let shared = AgentCDPListener()

    private let ioQueue = DispatchQueue(label: "com.phibrowser.cdp.listener")
    private let authQueue = DispatchQueue(label: "com.phibrowser.cdp.auth")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketPath: String?
    private var pointerFilePath: String?
    private var running = false

    private init() {}

    // MARK: - Lifecycle

    private static var accessGatesOpen: Bool {
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled
    }

    func setEnabled(_ enabled: Bool) {
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled = enabled
        if !enabled { revokeActiveAccess() }
        DispatchQueue.main.async {
            AppController.shared?.refreshPrefGatedMenuItems()
            if !enabled { AgentTranscriptPanelController.shared.dismiss() }
        }
    }

    func start() {
        ioQueue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        ioQueue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - Socket setup (ioQueue)

    private func startOnQueue() {
        guard !running else { return }

        guard let paths = Self.resolveSocketPaths() else {
            AppLogError("[AgentCDP] could not resolve a socket path")
            return
        }

        Self.sweepOrphanedSocketDirs(
            keeping: (paths.socket as NSString).deletingLastPathComponent)
        guard Self.prepareSocketDirectory(for: paths.socket) else { return }
        unlink(paths.socket)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            AppLogError("[AgentCDP] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        guard Self.bind(fd: fd, to: paths.socket) else {
            close(fd)
            return
        }
        chmod(paths.socket, 0o600)

        guard listen(fd, 16) == 0 else {
            AppLogError("[AgentCDP] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(paths.socket)
            return
        }
        Self.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()

        listenFD = fd
        acceptSource = source
        socketPath = paths.socket
        pointerFilePath = paths.pointer
        running = true

        // Publish the socket path for the skill's discovery (the file may live
        // at a long path; only bind() is bound by sun_path's ~104-byte limit).
        try? (paths.socket + "\n").write(toFile: paths.pointer, atomically: true, encoding: .utf8)

        AppLogInfo("[AgentCDP] listening at \(paths.socket)")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false

        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let socketPath { unlink(socketPath) }
        if let pointerFilePath { unlink(pointerFilePath) }
        socketPath = nil
        pointerFilePath = nil

        revokeActiveAccess()
        AppLogInfo("[AgentCDP] stopped")
    }

    private func revokeActiveAccess() {
        AgentDirectChannelRegistry.shared.closeAll()
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?.closeAllDevToolsConnections()
        }
    }

    // MARK: - Accept loop (ioQueue)

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                // Drained the backlog (EAGAIN/EWOULDBLOCK) or a transient error.
                break
            }
            Self.setNonBlocking(fd)
            authQueue.async { [weak self] in self?.authenticateAndDispatch(fd) }
        }
    }

    // MARK: - Authentication (authQueue, serial)

    private func authenticateAndDispatch(_ fd: Int32) {
        guard AgentPeerIdentity.peerIsSameUser(socketFD: fd) else {
            AppLogWarn("[AgentCDP] rejecting connection from another user")
            Self.denyAndClose(fd)
            return
        }

        // Peek (never consume) the request head up front: the first line
        // routes the connection, and any request may carry the agent-session
        // pid claim used for identification below.
        // A connection that never sent a request — a port probe, a liveness
        // check, a peer that hung up immediately — must not reach identity
        // evaluation: on this serial queue an unidentifiable peer would wedge
        // every legitimate connection behind whatever it costs to turn it
        // away. Close it quietly, before any of that.
        guard let requestHead = Self.peekRequestHead(fd) else {
            close(fd)
            return
        }
        let requestLine = requestHead
            .split(separator: "\r\n", maxSplits: 1).first
            .map(String.init)
        let isPhiAgent = requestLine?.hasPrefix("GET /phi-agent") ?? false

        // Resolve the actual peer ancestry first. Any connection may present
        // an app-issued capability from an earlier `/phi-agent` upgrade; that
        // is the proof that a detached/sandboxed helper was delegated the
        // logical agent session, and it binds this connection — task channel
        // or stock CDP alike — to that session's identity. The
        // caller-supplied pid is a log-only identification aid: it neither
        // joins a Swift task principal nor substitutes the peer identity.
        let peerIdentity = AgentPeerIdentity.resolve(socketFD: fd) ?? .unresolved

        let delegatedSession: AgentDriverSession?
        var servedTypes: Set<String>?
        switch Self.capabilityClaim(inRequestHead: requestHead) {
        case .absent:
            delegatedSession = nil
        case .invalid:
            // Presenting a capability at all commits the connection to
            // capability auth — a malformed one never falls back to peer
            // identity, on any route.
            AppLogWarn("[AgentCDP] rejected malformed agent-session capability")
            Self.denyAndClose(fd)
            return
        case .valid(let capability):
            guard let session = AgentDriverSessionRegistry.shared
                    .session(forCapability: capability) else {
                AppLogWarn("[AgentCDP] rejected unknown agent-session capability")
                Self.denyAndClose(fd)
                return
            }
            // A Drifter chat's Chromium connections need a running turn. Outside one, its
            // helpers get only a `/phi-agent` channel serving `outsideTurnTypes`.
            if session.identity.key == "mist:browser-agent" {
                switch AgentDriverSessionRegistry.shared.browserAgentAdmission(session, socketFD: fd) {
                case .turn:
                    break
                case .outsideTurn where isPhiAgent:
                    servedTypes = BrowserAgentCapability.outsideTurnTypes
                case .outsideTurn:
                    AppLogInfo("[AgentCDP] refused a Drifter chat's browser connection: no turn is running")
                    Self.denyAndClose(fd)
                    return
                case .refused:
                    AppLogWarn("[AgentCDP] refused a Drifter chat's capability from outside its running CLI")
                    Self.denyAndClose(fd)
                    return
                }
            }
            delegatedSession = session
        }

        // Route by the request line: a `/phi-agent` upgrade is an agentSpace.*
        // channel served in the app; everything else (/json, /devtools) is
        // stock CDP handed to Chromium with the fd intact (the peek never
        // consumed it).
        if isPhiAgent {
            let session: AgentDriverSession
            if let delegatedSession {
                session = delegatedSession
                guard evaluate(session.identity) else {
                    AppLogInfo("[AgentCDP] denied delegated access to \(session.identity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
            } else {
                guard evaluate(peerIdentity) else {
                    AppLogInfo("[AgentCDP] denied access to \(peerIdentity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
                session = AgentDriverSessionRegistry.shared.session(for: peerIdentity)
            }
            AgentDirectConnection(
                fd: fd,
                agentName: session.identity.displayName,
                agentPid: session.identity.pid,
                driverPrincipalId: session.principalId,
                agentCapability: session.capability,
                servedTypes: servedTypes
            ).start()
            return
        }

        // Stock CDP follows the same session rules: a delegated
        // helper is evaluated as its session's identity; otherwise the peer's
        // OWN resolved ancestry decides. Naming another agent's pid therefore
        // cannot substitute another agent's identity on raw CDP.
        let identity = delegatedSession?.identity ?? peerIdentity
        if delegatedSession == nil,
           let claimedPid = Self.claimedAgentPid(inRequestHead: requestHead),
           let claimed = AgentPeerIdentity.resolveClaimed(pid: claimedPid) {
            AppLogInfo("[AgentCDP] peer \(identity.displayName) claims agent pid "
                       + "\(claimedPid) (\(claimed.displayName)) — identification only")
        }

        guard evaluate(identity) else {
            AppLogInfo("[AgentCDP] denied access to \(identity.displayName)")
            Self.denyAndClose(fd)
            return
        }

        // Hand the raw fd to Chromium, which owns it from here (closed by the
        // browser whether or not the injection transport is live). Note who
        // opened it first: nothing downstream of the handover can say which
        // agent a browser-reported drive belongs to, so the operating mask's
        // pill names the driver from here — best effort, and only while one
        // agent is connected (AgentCDPDriverRoster).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // A turn may have ended while this admission waited for the
                // main queue. Refuse it before Chromium can acquire a hold.
                if let session = delegatedSession, session.identity.key == "mist:browser-agent",
                   !AgentDriverSessionRegistry.shared.isBrowserTurnActive(principalId: session.principalId) {
                    AppLogInfo("[AgentCDP] refused a Drifter chat's browser connection: its turn ended during admission")
                    Self.denyAndClose(fd)
                    return
                }
                if let session = delegatedSession, session.identity.key == "mist:browser-agent",
                   requestLine?.hasPrefix("GET /devtools/") == true {
                    AgentUserSpaceDriveRegistry.shared.retainBrowserAgentConnection(fd, principalId: session.principalId)
                }
                AgentCDPDriverRoster.shared.noteInjection(
                    key: identity.key, displayName: identity.displayName)
                let attached = ChromiumLauncher.sharedInstance().bridge?
                    .attachDevToolsConnection(withFD: fd) ?? false
                if !attached {
                    AppLogWarn("[AgentCDP] injection transport unavailable; connection dropped")
                }
            }
        }
    }

    /// Peeks (without consuming) at the start of the HTTP request — enough to
    /// cover the request line and the early headers that may carry the agent
    /// claim (the skill puts X-Phi-Agent-Pid right after Host). Non-consuming
    /// so a Chromium-bound fd stays pristine for its HTTP server to read from
    /// the start.
    private static func peekRequestHead(_ fd: Int32) -> String? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 2000)  // up to 2s for the request to arrive
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, Int32(MSG_PEEK))
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    /// The agent-session pid a request claims to act for: an `agentPid` query
    /// value on the request line (e.g. "GET /phi-agent?agentPid=123
    /// HTTP/1.1") or an `X-Phi-Agent-Pid` header on any route.
    private static func claimedAgentPid(inRequestHead head: String) -> pid_t? {
        let lines = head.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }
        let parts = line.split(separator: " ")
        if parts.count >= 2,
           let query = parts[1].split(separator: "?").dropFirst().first {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "agentPid", let pid = pid_t(kv[1]) {
                    return pid
                }
            }
        }
        for header in lines.dropFirst() {
            if header.isEmpty { break }  // end of headers
            guard let colon = header.firstIndex(of: ":") else { continue }
            guard header[..<colon].lowercased() == "x-phi-agent-pid" else { continue }
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            return pid_t(value)
        }
        return nil
    }

    /// App-issued bearer capability proving that this connection belongs to
    /// an already-established logical driver session. Kept in a dedicated
    /// header so stock Chromium simply ignores it on its own connections.
    /// One parser answers both "is one present?" and "what is it?", so the
    /// routing decision and the value can never disagree.
    enum CapabilityClaim: Equatable {
        case absent
        case invalid
        case valid(String)
    }

    /// Scanning stops at the head/body boundary (a stray match in peeked body
    /// bytes is not a claim), and a malformed or duplicated header is
    /// `.invalid` — never silently ignored. Internal for unit coverage.
    static func capabilityClaim(inRequestHead head: String) -> CapabilityClaim {
        var found: String?
        for header in head.components(separatedBy: "\r\n").dropFirst() {
            if header.isEmpty { break }  // end of headers
            guard let colon = header.firstIndex(of: ":"),
                  header[..<colon].lowercased() == "x-phi-agent-capability" else {
                continue
            }
            if found != nil { return .invalid }  // duplicate header
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 32, value.count <= 128,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return .invalid
            }
            found = value
        }
        return found.map(CapabilityClaim.valid) ?? .absent
    }

    private func evaluate(_ identity: AgentIdentity) -> Bool {
        if identity.firstParty { return true }
        if identity.isUnresolved {
            AppLogWarn("[AgentCDP] refused \(identity.displayName)"
                       + (identity.executablePath.isEmpty
                          ? "" : " (\(identity.executablePath))")
                       + " — nothing about this connection identifies an agent;"
                       + " a helper acting for one must present its session capability")
            return false
        }

        return Self.accessGatesOpen
    }

    // MARK: - Helpers

    private struct SocketPaths {
        let socket: String
        let pointer: String
    }

    /// Stable per-bundle suffix (FNV-1a of the bundle id). `String.hashValue`
    /// is seeded per process, which moved the socket directory on every
    /// launch: the stale-socket unlink at start could never fire across
    /// launches, and crash-orphaned dirs accumulated in /tmp until reboot.
    private static func stableSuffix(_ s: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    /// The bound socket lives at a short `/tmp` path (bind() caps sun_path at
    /// ~104 bytes); the pointer file, which has no
    /// length limit, sits in the app-support dir where the skill looks for it.
    private static func resolveSocketPaths() -> SocketPaths? {
        let uid = getuid()
        let bundleId = FileSystemUtils.bundleId
        let hash = stableSuffix(bundleId)
        let dir = "/tmp/phi-cdp-\(uid).\(hash)"
        let socket = (dir as NSString).appendingPathComponent("agent.sock")
        guard socket.utf8.count < 104 else {
            AppLogError("[AgentCDP] socket path too long: \(socket)")
            return nil
        }
        let pointer = (FileSystemUtils.applicationSupportDirctory() as NSString)
            .appendingPathComponent("CDPAgentSocket")
        return SocketPaths(socket: socket, pointer: pointer)
    }

    /// Creates the socket's parent directory as a 0700, self-owned directory,
    /// refusing to proceed if an existing one is owned by someone else (a
    /// squatting attempt on the predictable `/tmp` path).
    private static func prepareSocketDirectory(for socketPath: String) -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir) {
            var st = stat()
            if stat(dir, &st) == 0, st.st_uid != getuid() {
                AppLogError("[AgentCDP] socket dir \(dir) owned by uid \(st.st_uid); refusing")
                return false
            }
            return isDir.boolValue
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            AppLogError("[AgentCDP] mkdir \(dir) failed: \(error)")
            return false
        }
    }

    /// Best-effort sweep of crash-orphaned socket dirs — including the
    /// per-launch-suffixed ones older builds left behind, which a crash
    /// stranded in /tmp until reboot. A sibling dir whose socket no longer
    /// accepts is dead weight; a live one (the other Phi flavor's channel)
    /// is left alone.
    private static func sweepOrphanedSocketDirs(keeping ownDir: String) {
        let prefix = "phi-cdp-\(getuid())."
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            let dir = "/tmp/" + entry
            guard dir != ownDir else { continue }
            let sock = (dir as NSString).appendingPathComponent("agent.sock")
            guard !socketAccepts(sock) else { continue }
            try? fm.removeItem(atPath: dir)
        }
    }

    /// connect(2) probe: a live listener accepts immediately; a
    /// crash-orphaned socket file refuses in ~0 ms.
    private static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        return rc == 0
    }

    private static func fillSunPath(_ addr: inout sockaddr_un, with path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        return true
    }

    private static func bind(fd: Int32, to path: String) -> Bool {
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        if rc != 0 {
            AppLogError("[AgentCDP] bind() failed: \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Writes a short 403 so the skill's HTTP discovery gets a clear status,
    /// then closes. The fd is blocking-drained best-effort; denial is rare.
    private static func denyAndClose(_ fd: Int32) {
        let body = "Mist denied agent access.\n"
        let response = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        close(fd)
    }
}
