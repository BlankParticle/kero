import Crypto
import Foundation
import NIOSSH
import UIKit
import XCTest
@testable import Kero

@MainActor
final class KeroMobileTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KeroMobileTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        keychain = KeychainStore(
            service: "sh.kero.mobile.tests.\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        keychain = nil
    }

    func testHostnameNormalizationAndIPv6Display() {
        XCTAssertEqual(
            SSHHost.normalizeHostnameInput("  [2001:db8::1]  "),
            "2001:db8::1"
        )
        XCTAssertTrue(SSHHost.isValidHostname("server.example.com"))
        XCTAssertFalse(SSHHost.isValidHostname("bad host"))

        let host = SSHHost(
            name: "",
            hostname: "2001:db8::1",
            port: 2222,
            username: "demo"
        )
        XCTAssertEqual(host.endpoint, "[2001:db8::1]:2222")
        XCTAssertEqual(host.normalizedEndpoint, "[2001:db8::1]:2222")
    }

    func testKnownHostsPersistAndDetectChangedKeys() throws {
        let url = temporaryDirectory.appendingPathComponent("known-hosts.json")
        let store = KnownHostStore(storageURL: url)
        let host = SSHHost(
            name: "Test",
            hostname: "server.example.com",
            username: "demo"
        )

        let firstKey = "ssh-ed25519 AQID"
        let secondKey = "ssh-ed25519 BAUG"

        guard case .unknown(let proposed) = store.evaluate(
            host: host,
            openSSHKey: firstKey
        ) else {
            return XCTFail("A new server must require explicit trust.")
        }
        XCTAssertTrue(proposed.fingerprint.hasPrefix("SHA256:"))
        try store.trust(proposed)

        guard case .trusted = store.evaluate(
            host: host,
            openSSHKey: firstKey
        ) else {
            return XCTFail("The exact saved key should be trusted.")
        }

        let reloaded = KnownHostStore(storageURL: url)
        guard case .changed(let existing, let replacement) = reloaded.evaluate(
            host: host,
            openSSHKey: secondKey
        ) else {
            return XCTFail("A changed server key must never be trusted silently.")
        }
        XCTAssertEqual(existing.fingerprint, proposed.fingerprint)
        XCTAssertNotEqual(replacement.fingerprint, proposed.fingerprint)

        try reloaded.deleteAll()
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testPasswordsStayOutOfHostMetadata() async throws {
        let url = temporaryDirectory.appendingPathComponent("hosts.json")
        let store = HostStore(storageURL: url, keychain: keychain)
        let host = SSHHost(
            name: "Production",
            hostname: "prod.example.com",
            username: "deploy"
        )

        try store.upsert(host, password: "very-secret-value")
        XCTAssertEqual(try store.password(for: host), "very-secret-value")
        let connectionPassword = try await store.passwordForConnection(for: host)
        XCTAssertEqual(connectionPassword, "very-secret-value")

        let metadata = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(metadata.contains("very-secret-value"))
        XCTAssertTrue(metadata.contains("prod.example.com"))

        var editedHost = host
        editedHost.name = "Production Renamed"
        try store.upsert(editedHost, password: nil)
        XCTAssertEqual(try store.password(for: editedHost), "very-secret-value")

        try store.upsert(editedHost, password: "replacement-secret")
        XCTAssertEqual(try store.password(for: editedHost), "replacement-secret")

        editedHost.authentication = .identity
        editedHost.identityID = UUID()
        try store.upsert(editedHost, password: nil)
        XCTAssertThrowsError(try store.password(for: editedHost))

        try store.deleteAll()
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertThrowsError(try store.password(for: host))
    }

    func testGeneratedIdentityCanBeRecoveredAndErased() throws {
        let url = temporaryDirectory.appendingPathComponent("identities.json")
        let store = IdentityStore(storageURL: url, keychain: keychain)
        let identity = try store.generate(
            name: "Release Test",
            requiresUserPresence: false
        )

        XCTAssertTrue(identity.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(identity.fingerprint.hasPrefix("SHA256:"))
        _ = try store.privateKey(
            for: identity.id,
            hostName: "Test Server"
        )

        let reloaded = IdentityStore(storageURL: url, keychain: keychain)
        XCTAssertEqual(reloaded.identities, [identity])

        try reloaded.deleteAll()
        XCTAssertTrue(reloaded.identities.isEmpty)
        XCTAssertThrowsError(
            try reloaded.privateKey(
                for: identity.id,
                hostName: "Test Server"
            )
        )
    }

    func testSessionStoreReusesSessionUntilExplicitlyClosed() {
        let hostStore = HostStore(
            storageURL: temporaryDirectory.appendingPathComponent("hosts.json"),
            keychain: keychain
        )
        let identityStore = IdentityStore(
            storageURL: temporaryDirectory.appendingPathComponent(
                "identities.json"
            ),
            keychain: keychain
        )
        let knownHostStore = KnownHostStore(
            storageURL: temporaryDirectory.appendingPathComponent(
                "known-hosts.json"
            )
        )
        let sessionStore = TerminalSessionStore(
            hostStore: hostStore,
            identityStore: identityStore,
            knownHostStore: knownHostStore
        )
        let host = SSHHost(
            name: "Persistent Session",
            hostname: "server.example.com",
            username: "demo"
        )

        let first = sessionStore.openSession(for: host)
        let second = sessionStore.openSession(for: host)

        XCTAssertTrue(first === second)
        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertTrue(first.terminalView === second.terminalView)

        sessionStore.close(first)

        XCTAssertTrue(sessionStore.sessions.isEmpty)
        let replacement = sessionStore.openSession(for: host)
        XCTAssertFalse(first === replacement)
    }

    func testPasswordSSHHandshakeShellInputAndResize() async throws {
        let server = TestSSHServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let hostKeyReceived = expectation(
            description: "Server host key was offered for validation"
        )
        let connected = expectation(
            description: "SSH shell became ready"
        )
        let inputReceived = expectation(
            description: "Shell received terminal input"
        )
        let resizeReceived = expectation(
            description: "Shell received the requested terminal size"
        )
        let disconnected = expectation(
            description: "SSH client disconnected cleanly"
        )

        server.onInput = { data in
            guard String(data: data, encoding: .utf8)?
                .contains("release-check\r") == true else {
                return
            }
            inputReceived.fulfill()
        }
        server.onResize = { request in
            guard request.terminalCharacterWidth == 101,
                  request.terminalRowHeight == 41,
                  request.terminalPixelWidth == 1_170,
                  request.terminalPixelHeight == 2_100 else {
                return
            }
            resizeReceived.fulfill()
        }

        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let host = SSHHost(
            name: "Integration Server",
            hostname: "127.0.0.1",
            port: server.port,
            username: "release"
        )
        let configuration = SSHConnectionConfiguration(
            host: host,
            credential: .password("integration-secret"),
            term: "xterm-256color",
            environment: ["LANG": "en_US.UTF-8"],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )

        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { key, completion in
                XCTAssertTrue(key.hasPrefix("ssh-ed25519 "))
                hostKeyReceived.fulfill()
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .connected:
                    connected.fulfill()
                case .disconnected:
                    disconnected.fulfill()
                case .failed(let message):
                    XCTFail("Integration SSH connection failed: \(message)")
                default:
                    break
                }
            }
        )

        connection.connect()
        await fulfillment(
            of: [hostKeyReceived, connected],
            timeout: 8
        )

        connection.send(Data("release-check\r".utf8))
        connection.resize(
            SSHWindowSize(
                columns: 101,
                rows: 41,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        await fulfillment(
            of: [inputReceived, resizeReceived],
            timeout: 5
        )

        connection.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
    }

    func testRejectedPasswordReportsAuthenticationFailure() async throws {
        let server = TestSSHServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let failed = expectation(
            description: "Rejected password produced a useful failure"
        )
        var failureMessage: String?
        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Rejected Password Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release"
            ),
            credential: .password("incorrect-password"),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .failed(let message):
                    failureMessage = message
                    failed.fulfill()
                case .connected:
                    XCTFail("A rejected password must not connect.")
                default:
                    break
                }
            }
        )

        connection.connect()
        await fulfillment(of: [failed], timeout: 8)
        XCTAssertEqual(
            failureMessage,
            "Authentication failed. Check the username and password or SSH key."
        )
    }

    func testSilentServerReportsHandshakeTimeout() async throws {
        let server = TestSilentTCPServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let failed = expectation(
            description: "Silent server produced a handshake timeout"
        )
        var failureMessage: String?
        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Silent Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release"
            ),
            credential: .password("integration-secret"),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            connectionTimeout: .milliseconds(250),
            onStateChange: { state in
                guard case .failed(let message) = state else {
                    return
                }
                failureMessage = message
                failed.fulfill()
            }
        )

        connection.connect()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(
            failureMessage,
            "The SSH handshake timed out. Check the server address, network access, and authentication settings."
        )
    }

    func testEd25519SSHAuthentication() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let privateKey = NIOSSHPrivateKey(ed25519Key: signingKey)
        let server = TestSSHServer(
            authentication: .publicKey(
                username: "release",
                key: privateKey.publicKey
            )
        )
        try server.start()
        defer {
            try? server.stop()
        }

        let connected = expectation(
            description: "Ed25519-authenticated shell became ready"
        )
        let disconnected = expectation(
            description: "Ed25519 SSH client disconnected cleanly"
        )

        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Key Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release",
                authentication: .identity
            ),
            credential: .privateKey(privateKey),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .connected:
                    connected.fulfill()
                case .disconnected:
                    disconnected.fulfill()
                case .failed(let message):
                    XCTFail("Ed25519 SSH connection failed: \(message)")
                default:
                    break
                }
            }
        )

        connection.connect()
        await fulfillment(of: [connected], timeout: 8)
        connection.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
    }
}
