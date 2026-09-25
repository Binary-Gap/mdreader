import XCTest

/// Initial XCUITest coverage for MDReader's navigation chrome (address bar,
/// sidebar, back/forward pill). Elements are matched by accessibilityIdentifier
/// (added minimally to the app views) rather than by fragile labels/coordinates.
final class MDReaderUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The session-restore test drives its own app instance (no file arg,
        // seeded session), so don't pre-launch the shared fixture app for it.
        if name.contains("testSessionRestoreReopensSavedFile") { return }
        // The live-reload test drives its own app against a temp file it mutates.
        if name.contains("testLiveReloadOnDiskChange") { return }
        app = XCUIApplication()
        // Launch against the repo's sample fixture so a real document is shown.
        // SRCROOT is exported into the test target's environment by the scheme so
        // the fixture path is stable regardless of the run's working directory.
        let srcroot = ProcessInfo.processInfo.environment["MDREADER_SRCROOT"]
        if let srcroot {
            app.launchArguments = ["\(srcroot)/test/sample.md"]
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// The app launches and presents a main window.
    func testAppLaunchesWithMainWindow() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "Expected a main window after launch")
    }

    /// Cmd+L reveals the docked address bar (its text field becomes hittable);
    /// Esc dismisses the field and hides the bar again.
    func testAddressBarRevealAndDismiss() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let addressField = app.textFields["nav-address-field"]
        // Hidden by default (the bar starts collapsed / offscreen, so the field
        // is not hittable even if it exists in the tree).
        XCTAssertFalse(addressField.isHittable,
                       "Address field should not be hittable before Cmd+L")

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(addressField.waitForHittable(timeout: 5),
                      "Cmd+L should reveal a hittable address field")

        // Esc dismisses (the field is first responder, so cancelOperation fires).
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(addressField.waitForNotHittable(timeout: 5),
                      "Esc should hide the address field again")
    }

    /// When revealed, the address field docks near the window top (the bar is
    /// flush with the window top, keeping a small traffic-light band above the
    /// field). Guards against the bar drifting down / detaching from the top.
    func testAddressFieldDocksNearWindowTop() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        app.typeKey("l", modifierFlags: .command)
        let addressField = app.textFields["nav-address-field"]
        XCTAssertTrue(addressField.waitForHittable(timeout: 5))

        // Field top should sit within the reserved traffic-light band plus the
        // control strip's own height — i.e. comfortably inside the top ~90px of
        // the window, not floating in the middle.
        let offsetFromWindowTop = addressField.frame.minY - window.frame.minY
        XCTAssertLessThan(offsetFromWindowTop, 90,
                          "Address field should be docked near the window top")
        XCTAssertGreaterThanOrEqual(offsetFromWindowTop, 0,
                                    "Address field should be below the window top")
    }

    // NOTE (uncovered, verify manually): picking a different file in the sidebar
    // while the address bar is OPEN must update the field's text to the newly
    // opened document (syncChromeFromURL -> NavBarView.setAddressText). Driving
    // this synthetically needs two persisted recent-files rows, and recent-files
    // state bleeds across tests in a suite run (UserDefaults-backed), making the
    // setup flaky; the sidebar rows carry "sidebar-row-<filename>" identifiers if
    // a future harness isolates that state. Verify by hand: open a file, Cmd+L,
    // click another recent row -> the field should switch to the picked file.

    /// Backslash toggles the sidebar; its "RECENT FILES" header becomes hittable
    /// when open and stops being hittable when toggled closed again.
    func testSidebarToggle() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let header = app.staticTexts["sidebar-recent-files-header"]
        XCTAssertFalse(header.isHittable,
                       "Sidebar header should not be hittable before opening")

        app.typeKey("\\", modifierFlags: [])
        XCTAssertTrue(header.waitForHittable(timeout: 5),
                      "Backslash should open the sidebar and reveal its header")

        app.typeKey("\\", modifierFlags: [])
        XCTAssertTrue(header.waitForNotHittable(timeout: 5),
                      "Backslash again should collapse the sidebar")
    }

    /// At the initial state the back button is disabled (no history to go back to).
    /// The back/forward buttons live in the address bar's pill, so reveal the bar
    /// first, then assert the back button exists and is not enabled.
    func testBackButtonDisabledAtInitialState() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("l", modifierFlags: .command)
        let addressField = app.textFields["nav-address-field"]
        XCTAssertTrue(addressField.waitForHittable(timeout: 5))

        // The back button identifier is shared by two clusters (the floating pill
        // and the address bar), so query all matches rather than a single element.
        let backButtons = app.buttons.matching(identifier: "nav-back-button")
        XCTAssertGreaterThan(backButtons.count, 0,
                             "At least one back button should exist")
        // With no history, canGoBack is false, so every back button is disabled.
        for index in 0..<backButtons.count {
            XCTAssertFalse(backButtons.element(boundBy: index).isEnabled,
                           "Back button should be disabled with no history (canGoBack == false)")
        }
    }
    /// Cmd+/ opens the keyboard-shortcuts modal (its "Keyboard Shortcuts" title
    /// surfaces as static text inside the WKWebView); Esc dismisses it and a repeat
    /// Cmd+/ toggles it closed again.
    func testKeyboardShortcutsModalToggle() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let title = app.staticTexts["Keyboard Shortcuts"]
        XCTAssertFalse(title.exists,
                       "Shortcuts modal should not be present before Cmd+/")

        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "Cmd+/ should open the shortcuts modal")

        // Esc dismisses (overlay JS captures keydown at document level).
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(title.waitForNonExistence(timeout: 5),
                      "Esc should dismiss the shortcuts modal")

        // Repeat Cmd+/ toggles it back open, then closed.
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "Cmd+/ should reopen the shortcuts modal")
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5),
                      "Repeat Cmd+/ should toggle the shortcuts modal closed")
    }

    /// Launching with no file argument but a saved session restores the previous
    /// window: a session.json pointing at the fixture makes the app reopen that
    /// file even though nothing is passed on the command line.
    func testSessionRestoreReopensSavedFile() throws {
        guard let srcroot = ProcessInfo.processInfo.environment["MDREADER_SRCROOT"] else {
            throw XCTSkip("MDREADER_SRCROOT not set; cannot locate the fixture")
        }
        let filePath = "\(srcroot)/test/sample.md"

        // Seed a session file in a temp location so the real ~/.config is untouched.
        let sessionFile = NSTemporaryDirectory() + "mdreader-restore-\(UUID().uuidString).json"
        // CGRect encodes as nested [[x,y],[w,h]] arrays (Codable's default).
        let json = """
        {"windows":[{"filePath":"\(filePath)","frame":[[120,120],[640,720]],"sidebarVisible":false}]}
        """
        try json.write(toFile: sessionFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: sessionFile) }

        // Fresh app instance launched WITHOUT a file arg -> restore path fires.
        let restored = XCUIApplication()
        restored.launchEnvironment["MDREADER_SESSION_FILE"] = sessionFile
        restored.launch()
        defer { restored.terminate() }

        let window = restored.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Restored session should reopen a window")
        // The title is "<filename> - <abbreviated path>"; assert the fixture name is in it.
        XCTAssertTrue(window.title.contains("sample.md"),
                      "Restored window should show the saved file (title: \(window.title))")
    }

    /// Editing the open file on disk live-reloads the rendered view: after the
    /// app shows the original content, rewriting the file makes the new content
    /// appear without any manual reload. Drives its own app against a temp file so
    /// it can mutate it freely.
    func testLiveReloadOnDiskChange() throws {
        let filePath = NSTemporaryDirectory() + "mdreader-livereload-\(UUID().uuidString).md"
        try "# Live Reload\n\nMarker ALPHATOKEN here.\n"
            .write(toFile: filePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let app = XCUIApplication()
        app.launchArguments = [filePath]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // The rendered markdown surfaces as static text inside the WKWebView.
        let original = app.staticTexts["Marker ALPHATOKEN here."]
        XCTAssertTrue(original.waitForExistence(timeout: 10),
                      "Original file content should render")

        // Rewrite the file on disk; the watcher should reload the view.
        try "# Live Reload\n\nMarker BRAVOTOKEN now.\n"
            .write(toFile: filePath, atomically: true, encoding: .utf8)

        let updated = app.staticTexts["Marker BRAVOTOKEN now."]
        XCTAssertTrue(updated.waitForExistence(timeout: 10),
                      "Edited file content should live-reload into the view")
    }
}

private extension XCUIElement {
    /// Poll until the element is hittable or the timeout elapses.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHittable { return true }
            usleep(100_000)
        }
        return isHittable
    }

    /// Poll until the element is no longer hittable or the timeout elapses.
    func waitForNotHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isHittable { return true }
            usleep(100_000)
        }
        return !isHittable
    }

    /// Poll until the element stops existing or the timeout elapses.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            usleep(100_000)
        }
        return !exists
    }
}
