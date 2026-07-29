import XCTest

@MainActor
final class KeroMobileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        if environment["KERO_LIVE_SSH_TEST_MODE"] != nil {
            app.launchArguments = ["-live-ssh-testing"]
            for key in [
                "KERO_LIVE_SSH_HOST",
                "KERO_LIVE_SSH_PORT",
                "KERO_LIVE_SSH_USERNAME",
                "KERO_LIVE_SSH_PASSWORD",
                "KERO_LIVE_SSH_USER_PRESENCE",
            ] {
                app.launchEnvironment[key] = environment[key]
            }
        } else {
            app.launchArguments = ["-ui-testing"]
        }
        app.launch()
    }

    func testLiveSSHConnectionOutcome() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["KERO_LIVE_SSH_TEST_MODE"] else {
            throw XCTSkip("Run only when explicitly testing a live SSH server.")
        }

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        let hostButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Live SSH Test,'")
        ).firstMatch
        XCTAssertTrue(hostButton.waitForExistence(timeout: 3))
        hostButton.tap()

        let requiresUserPresence =
            environment["KERO_LIVE_SSH_USER_PRESENCE"] == "1"
        XCTAssertTrue(
            app.buttons["Trust and Connect"].waitForExistence(
                timeout: requiresUserPresence ? 30 : 10
            )
        )
        app.buttons["Trust and Connect"].tap()

        switch mode {
        case "authentication-failure":
            let alert = app.alerts["SSH connection failed"]
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            XCTAssertTrue(
                alert.staticTexts[
                    "Authentication failed. Check the username and password or SSH key."
                ].exists
            )
            alert.buttons["OK"].tap()
            XCTAssertTrue(
                app.staticTexts["Connection ended"].waitForExistence(timeout: 3)
            )
        case "connected":
            assertSessionConnected()
            app.navigationBars.buttons["Hosts"].tap()

            let activeSession = app.buttons["active-session-card"]
            XCTAssertTrue(activeSession.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["close-active-session"].exists)
            capture("Live Active Session")
            activeSession.tap()

            XCTAssertTrue(
                app.textViews["ssh-terminal"].waitForExistence(timeout: 3)
            )
            XCTAssertFalse(app.buttons["Trust and Connect"].exists)
            assertSessionConnected()
        default:
            XCTFail("Unknown live SSH test mode: \(mode)")
        }
    }

    func testLiveSSHReconnectAfterBackgrounding() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KERO_LIVE_SSH_TEST_MODE"] == "reconnect" else {
            throw XCTSkip("Run only when explicitly testing live SSH reconnect.")
        }

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        let hostButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Live SSH Test,'")
        ).firstMatch
        XCTAssertTrue(hostButton.waitForExistence(timeout: 3))
        hostButton.tap()

        XCTAssertTrue(
            app.buttons["Trust and Connect"].waitForExistence(timeout: 10)
        )
        app.buttons["Trust and Connect"].tap()
        assertSessionConnected()

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            app.staticTexts["Session ended"].waitForExistence(timeout: 5)
        )
        let reconnectButton = app.buttons["reconnect-session"]
        XCTAssertTrue(reconnectButton.exists)
        let requiresUserPresence =
            environment["KERO_LIVE_SSH_USER_PRESENCE"] == "1"
        if !requiresUserPresence {
            reconnectButton.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
        }
        // A protected run drives the reconnect tap and biometric response
        // externally so it can exercise the real system Face ID interruption.
        XCTAssertTrue(
            reconnectButton.waitForNonExistence(
                timeout: requiresUserPresence ? 30 : 2
            ),
            "Reconnect must immediately replace the ended-session overlay."
        )
        assertSessionConnected()
    }

    func testHostKeyAndSettingsWorkflow() throws {
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Hosts"].exists)

        app.buttons.matching(identifier: "Add Host").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 2))

        type("Test Server", into: app.textFields["host-name-field"])
        type("203.0.113.1", into: app.textFields["host-hostname-field"])
        type("demo", into: app.textFields["host-username-field"])

        app.swipeUp()
        type("not-a-real-password", into: app.secureTextFields["host-password-field"])
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Test Server"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["demo@203.0.113.1"].exists)
        XCTAssertFalse(
            app.buttons["Not Now"].waitForExistence(timeout: 1),
            "SSH credentials must not trigger the system website-password prompt."
        )
        capture("Host List")

        let hostButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Test Server,'")
        ).firstMatch
        hostButton.tap()
        let terminalNavigationBar = app.navigationBars["Test Server"]
        if !terminalNavigationBar.waitForExistence(timeout: 2) {
            hostButton.tap()
        }
        XCTAssertTrue(terminalNavigationBar.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Escape"].exists)
        XCTAssertTrue(app.buttons["Control C"].exists)
        capture("Terminal")

        app.navigationBars.buttons["Hosts"].tap()
        let activeSession = app.buttons["active-session-card"]
        XCTAssertTrue(activeSession.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["close-active-session"].exists)
        capture("Active Session")
        app.buttons["close-active-session"].tap()
        XCTAssertTrue(activeSession.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Test Server"].exists)

        tapTab("Keys")
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 2))

        app.buttons.matching(identifier: "Generate Key").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Generate Key"].waitForExistence(timeout: 2))
        app.buttons["Generate"].tap()

        XCTAssertTrue(app.staticTexts["Kero"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'SHA256:'")
            ).firstMatch.exists
        )
        app.staticTexts["Kero"].tap()
        XCTAssertTrue(app.navigationBars["SSH Key"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Copy Public Key"].exists)
        XCTAssertTrue(app.buttons["Share Public Key"].exists)
        XCTAssertTrue(app.staticTexts["identity-public-key"].exists)
        capture("SSH Key Detail")

        app.navigationBars.buttons["Keys"].tap()

        tapTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Font Size"].exists)
        XCTAssertTrue(app.staticTexts["No server identities have been trusted yet."].exists)
        capture("Settings")

        app.buttons["Privacy Policy"].tap()
        XCTAssertTrue(
            app.navigationBars["Privacy Policy"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["No analytics or telemetry"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Kero does not proxy terminal traffic through a Kero service."
            ].exists
        )
        capture("Privacy Policy")

        app.navigationBars.buttons["Settings"].tap()
        app.swipeUp()
        let eraseButton = app.buttons["Erase All Data…"]
        XCTAssertTrue(eraseButton.waitForExistence(timeout: 2))
        eraseButton.tap()
        XCTAssertTrue(
            app.alerts["Erase all Kero data?"].waitForExistence(timeout: 2)
        )
        app.alerts.buttons["Erase All Data"].tap()

        tapTab("Hosts")
        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 2))
        tapTab("Keys")
        XCTAssertTrue(app.staticTexts["No SSH Keys"].waitForExistence(timeout: 2))
    }

    func testEmptyStatesAndPrimaryNavigation() {
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Hosts"].exists)
        XCTAssertTrue(app.buttons["Add Host"].exists)
        capture("Empty Hosts")

        tapTab("Keys")
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No SSH Keys"].exists)
        XCTAssertTrue(app.buttons["Generate Key"].exists)
        capture("Empty Keys")

        tapTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Font Size"].exists)
        for _ in 0..<4 where !app.buttons["Privacy Policy"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            app.buttons["Privacy Policy"].waitForExistence(timeout: 2)
        )
        capture("Settings Overview")
    }

    func testActiveSessionsUseTwoColumnGrid() {
        app.terminate()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-active-sessions",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        let sessions = app.buttons.matching(
            identifier: "active-session-card"
        )
        let firstSession = sessions.element(boundBy: 0)
        let secondSession = sessions.element(boundBy: 1)
        XCTAssertTrue(firstSession.waitForExistence(timeout: 3))
        XCTAssertTrue(secondSession.waitForExistence(timeout: 3))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(
            app.buttons.matching(identifier: "close-active-session").count,
            2
        )

        XCTAssertEqual(
            firstSession.frame.minY,
            secondSession.frame.minY,
            accuracy: 2
        )
        XCTAssertEqual(
            firstSession.frame.width,
            secondSession.frame.width,
            accuracy: 2
        )
        XCTAssertLessThan(firstSession.frame.maxX, secondSession.frame.minX)
        capture("Two Column Active Sessions")
    }

    func testSingleActiveSessionKeepsHalfWidthAndFullThumbnail() {
        app.terminate()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-single-active-session",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        let sessions = app.buttons.matching(
            identifier: "active-session-card"
        )
        let session = sessions.firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 3))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            app.buttons.matching(identifier: "close-active-session").count,
            1
        )

        XCTAssertLessThan(session.frame.width, app.frame.width * 0.55)
        XCTAssertGreaterThanOrEqual(session.frame.minX, 0)
        XCTAssertLessThanOrEqual(session.frame.maxX, app.frame.width)
        capture("Single Active Session")
    }

    func testSessionActionsMenuIsCompact() {
        app.terminate()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-single-active-session",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))
        app.buttons["active-session-card"].tap()

        let connectionAlert = app.alerts["Couldn’t connect"]
        if connectionAlert.waitForExistence(timeout: 3) {
            connectionAlert.buttons["OK"].tap()
        }

        let menu = app.buttons["Session actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()

        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Close Session"].exists)
        XCTAssertFalse(app.staticTexts["Status"].exists)
        XCTAssertFalse(app.staticTexts["Server"].exists)
        XCTAssertFalse(app.staticTexts["builder@192.0.2.10"].exists)
        capture("Session Actions Menu")
    }

    private func tapTab(_ name: String) {
        let tabBarButton = app.tabBars.buttons[name]
        if tabBarButton.waitForExistence(timeout: 1) {
            tabBarButton.tap()
            return
        }

        // The adaptive floating tab bar on iPad is currently exposed by
        // XCTest as a cell instead of a conventional tab-bar button.
        let adaptiveTab = app.cells[name]
        if adaptiveTab.waitForExistence(timeout: 1) {
            adaptiveTab.tap()
            return
        }

        let fallback = app.buttons[name].firstMatch
        XCTAssertTrue(
            fallback.waitForExistence(timeout: 1),
            "Could not find the \(name) app tab."
        )
        fallback.tap()
    }

    private func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        element.tap()
        element.typeText(text)
    }

    private func assertSessionConnected() {
        let sessionButton = app.buttons["Session"]
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 10))
        let connected = NSPredicate(format: "value == %@", "Connected")
        expectation(for: connected, evaluatedWith: sessionButton)
        waitForExpectations(timeout: 10)
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
