import Foundation

public enum SSHTunnelError: Error, Equatable, Sendable {
    /// A host, user or target that could be read as an option or would break the forward specification.
    case invalid(String)
    /// `ssh` ended before the tunnel was ready; the text is what it printed.
    case failed(String)
    case timedOut
}

/// An open path to a server that is only reachable through another host.
public protocol Tunnel: Sendable {
    /// The local Unix socket that leads to the database.
    var socketPath: String { get }
    func close()
}

/// Opens tunnels. The demo environment has none: it never starts a process.
public protocol TunnelProviding: Sendable {
    func openTunnel(for profile: ConnectionProfile, prompt: AskpassHandler?) async throws -> any Tunnel
}

public struct SSHTunnelConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int?
    public var user: String
    public var identityFile: String
    public var targetHost: String
    public var targetPort: Int
    /// Extra `-o` options, for tests against a throwaway sshd.
    var extraOptions: [String] = []

    public init(host: String, port: Int? = nil, user: String = "", identityFile: String = "", targetHost: String, targetPort: Int) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public init(profile: ConnectionProfile) throws {
        guard let port = profile.effectivePort else { throw SSHTunnelError.invalid(profile.host) }
        self.init(
            host: profile.ssh.host.trimmingCharacters(in: .whitespaces), port: profile.ssh.port,
            user: profile.ssh.user.trimmingCharacters(in: .whitespaces), identityFile: profile.ssh.identityFile,
            targetHost: profile.host.trimmingCharacters(in: .whitespaces), targetPort: port)
    }

    private static func isSafe(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// The arguments of `/usr/bin/ssh`. The system OpenSSH does everything else: `~/.ssh/config`, agents,
    /// ProxyJump and known hosts apply as they do in a terminal.
    func arguments(socketPath: String, batchMode: Bool) throws -> [String] {
        guard Self.isSafe(host) else { throw SSHTunnelError.invalid(host) }
        guard user.isEmpty || Self.isSafe(user) else { throw SSHTunnelError.invalid(user) }
        guard Self.isSafe(targetHost), !targetHost.contains("["), !targetHost.contains("]"), !targetHost.contains("/"),
              (1...65_535).contains(targetPort) else { throw SSHTunnelError.invalid(targetHost) }
        let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost

        var arguments = [
            "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        if batchMode { arguments += ["-o", "BatchMode=yes"] }
        for option in extraOptions { arguments += ["-o", option] }
        if let port { arguments += ["-p", String(port)] }
        if !user.isEmpty { arguments += ["-l", user] }
        if !identityFile.isEmpty { arguments += ["-i", (identityFile as NSString).expandingTildeInPath] }
        arguments += ["-L", "\(socketPath):\(target):\(targetPort)", "--", host]
        return arguments
    }
}

/// One `ssh -N -L <unix-socket>:host:port` process. Every connection of a window goes through its
/// socket, so the user authenticates once, and TLS to the database works through it.
public final class SSHTunnel: Tunnel, @unchecked Sendable {
    public let socketPath: String
    private let directory: String
    private let process: Process
    private let askpass: AskpassServer?
    private let output = Output()

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ data: Data) {
            lock.withLock {
                text += String(decoding: data, as: UTF8.self)
                if text.count > 4000 { text = String(text.suffix(4000)) }
            }
        }

        /// What ssh said, without the lines it prints for every forwarded channel.
        var message: String {
            lock.withLock {
                text.split(whereSeparator: \.isNewline).filter { !$0.contains("setsockopt TCP_NODELAY") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private init(socketPath: String, directory: String, process: Process, askpass: AskpassServer?) {
        self.socketPath = socketPath
        self.directory = directory
        self.process = process
        self.askpass = askpass
    }

    /// Starts ssh and waits for the forward to be ready. `askpassExecutable` is the program OpenSSH runs
    /// to ask a question; without it, or without a handler, ssh runs in batch mode and never asks.
    public static func open(
        _ configuration: SSHTunnelConfiguration, askpassExecutable: String?, prompt: AskpassHandler?, timeout: TimeInterval = 180
    ) async throws -> SSHTunnel {
        let directory = try makeDirectory()
        let socketPath = directory + "/s"
        var environment = ProcessInfo.processInfo.environment
        var askpass: AskpassServer?
        if let askpassExecutable, let prompt, let server = AskpassServer(socketPath: directory + "/a", handler: prompt) {
            askpass = server
            environment["SSH_ASKPASS"] = askpassExecutable
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment[AskpassClient.socketVariable] = server.socketPath
            if environment["DISPLAY"] == nil { environment["DISPLAY"] = ":0" }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        do {
            process.arguments = try configuration.arguments(socketPath: socketPath, batchMode: askpass == nil)
        } catch {
            askpass?.stop()
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let tunnel = SSHTunnel(socketPath: socketPath, directory: directory, process: process, askpass: askpass)
        errors.fileHandleForReading.readabilityHandler = { [output = tunnel.output] handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data) }
        }

        do {
            try process.run()
        } catch {
            tunnel.close()
            throw SSHTunnelError.failed(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: socketPath) {
            if !process.isRunning {
                let message = tunnel.output.message
                tunnel.close()
                throw SSHTunnelError.failed(message.isEmpty ? "ssh exited with status \(process.terminationStatus)" : message)
            }
            if Date() > deadline {
                tunnel.close()
                throw SSHTunnelError.timedOut
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The questions are over once the forward is up.
        askpass?.stop()
        return tunnel
    }

    /// A private directory whose path is short enough for a Unix socket (104 bytes at most).
    private static func makeDirectory() throws -> String {
        for base in [NSTemporaryDirectory(), "/tmp/"] {
            var template = Array((base + "rw-XXXXXX").utf8CString)
            guard base.utf8.count < 80, mkdtemp(&template) != nil else { continue }
            return String(cString: template)
        }
        throw SSHTunnelError.failed("cannot create a private directory for the tunnel")
    }

    public var isRunning: Bool { process.isRunning }

    /// What ssh reported, for explaining a connection that failed through the tunnel.
    public var diagnostics: String { output.message }

    public func close() {
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        askpass?.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

/// Opens SSH tunnels with the system OpenSSH.
public struct SSHTunnelProvider: TunnelProviding {
    /// The executable OpenSSH runs to ask a question: the app itself, which then acts as the helper.
    public let askpassExecutable: String?

    public init(askpassExecutable: String?) { self.askpassExecutable = askpassExecutable }

    public func openTunnel(for profile: ConnectionProfile, prompt: AskpassHandler?) async throws -> any Tunnel {
        try await SSHTunnel.open(SSHTunnelConfiguration(profile: profile), askpassExecutable: askpassExecutable, prompt: prompt)
    }
}
