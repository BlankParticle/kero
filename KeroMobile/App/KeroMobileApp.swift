import SwiftUI

@main
struct KeroMobileApp: App {
    @StateObject private var hostStore: HostStore
    @StateObject private var identityStore: IdentityStore
    @StateObject private var knownHostStore: KnownHostStore
    @StateObject private var sessionStore: TerminalSessionStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-live-ssh-testing") {
            let environment = ProcessInfo.processInfo.environment
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeroMobileLiveSSHTests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let keychain = KeychainStore(
                service: "sh.kero.mobile.live-tests.\(ProcessInfo.processInfo.processIdentifier)"
            )
            let hostStore = HostStore(
                storageURL: root.appendingPathComponent("hosts.json"),
                keychain: keychain
            )
            if let hostname = environment["KERO_LIVE_SSH_HOST"],
               let username = environment["KERO_LIVE_SSH_USERNAME"],
               let password = environment["KERO_LIVE_SSH_PASSWORD"] {
                let host = SSHHost(
                    name: "Live SSH Test",
                    hostname: hostname,
                    port: Int(environment["KERO_LIVE_SSH_PORT"] ?? "") ?? 22,
                    username: username,
                    passwordRequiresUserPresence:
                        environment["KERO_LIVE_SSH_USER_PRESENCE"] == "1"
                )
                try? hostStore.upsert(host, password: password)
            }
            let identityStore = IdentityStore(
                storageURL: root.appendingPathComponent("identities.json"),
                keychain: keychain
            )
            let knownHostStore = KnownHostStore(
                storageURL: root.appendingPathComponent("known-hosts.json")
            )
            _hostStore = StateObject(wrappedValue: hostStore)
            _identityStore = StateObject(wrappedValue: identityStore)
            _knownHostStore = StateObject(wrappedValue: knownHostStore)
            let sessionStore = TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
            _sessionStore = StateObject(wrappedValue: sessionStore)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeroMobileUITests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let keychain = KeychainStore(
                service: "sh.kero.mobile.ui-tests.\(ProcessInfo.processInfo.processIdentifier)"
            )
            let hostStore = HostStore(
                storageURL: root.appendingPathComponent("hosts.json"),
                keychain: keychain
            )
            let identityStore = IdentityStore(
                storageURL: root.appendingPathComponent("identities.json"),
                keychain: keychain
            )
            let knownHostStore = KnownHostStore(
                storageURL: root.appendingPathComponent("known-hosts.json")
            )
            _hostStore = StateObject(wrappedValue: hostStore)
            _identityStore = StateObject(wrappedValue: identityStore)
            _knownHostStore = StateObject(wrappedValue: knownHostStore)
            let sessionStore = TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ui-testing-active-sessions")
                || arguments.contains("-ui-testing-single-active-session") {
                let hosts = [
                    SSHHost(
                        name: "Build Server",
                        hostname: "192.0.2.10",
                        username: "builder"
                    ),
                    SSHHost(
                        name: "Home Server",
                        hostname: "192.0.2.11",
                        username: "admin"
                    ),
                ]
                let sessionCount = arguments.contains(
                    "-ui-testing-single-active-session"
                ) ? 1 : 2
                for host in hosts.prefix(sessionCount) {
                    let session = sessionStore.openSession(for: host)
                    session.terminalView.feed(
                        text: """
                        Last login: Wed Jul 29 18:40:47 2026
                        Welcome to fish, the friendly interactive shell
                        Type help for instructions on how to use fish
                        builder in build-server in ~
                        > 
                        """
                    )
                    session.updateTitle("[\(host.displayName)] ~")
                    session.captureThumbnail()
                }
            }
            _sessionStore = StateObject(wrappedValue: sessionStore)
            return
        }
        #endif

        let keychain = KeychainStore()
        let hostStore = HostStore(keychain: keychain)
        let identityStore = IdentityStore(keychain: keychain)
        let knownHostStore = KnownHostStore()
        _hostStore = StateObject(wrappedValue: hostStore)
        _identityStore = StateObject(wrappedValue: identityStore)
        _knownHostStore = StateObject(wrappedValue: knownHostStore)
        _sessionStore = StateObject(
            wrappedValue: TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hostStore)
                .environmentObject(identityStore)
                .environmentObject(knownHostStore)
                .environmentObject(sessionStore)
        }
    }
}
