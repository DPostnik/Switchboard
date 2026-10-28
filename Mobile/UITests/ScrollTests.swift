import XCTest
import UIKit

final class ScrollTests: XCTestCase {
    @MainActor func testProjectChatDisclosureAndHiddenSearchInBothLanguages() throws {
        let project = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        for (language, more, fewer, remaining, attention) in [
            ("ru", "Показать ещё", "Свернуть", "Осталось: 7", "Скрытые чаты ждут ответа: 1"),
            ("en", "Show more", "Show fewer", "Remaining: 7", "Hidden chats needing your attention: 1")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-project-list", "-interfaceLanguage", language]
            app.launch()
            let expand = app.buttons["more-chats-" + project]
            XCTAssertTrue(expand.waitForExistence(timeout: 10))
            func reveal(_ element: XCUIElement, up: Bool = true) {
                for _ in 0..<12 where !element.isHittable {
                    if up { app.swipeUp() } else { app.swipeDown() }
                }
                XCTAssertTrue(element.isHittable)
            }
            reveal(expand)
            XCTAssertTrue(expand.label.contains(more))
            XCTAssertTrue(expand.label.contains(remaining))
            XCTAssertFalse(app.buttons["chat-row-" + project + "-6"].exists)
            XCTAssertEqual(app.staticTexts["hidden-approvals-" + project].label, attention)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Five project chats " + language; screenshot.lifetime = .keepAlways; add(screenshot)
            expand.tap()
            XCTAssertTrue(app.buttons["chat-row-" + project + "-6"].waitForExistence(timeout: 5))
            reveal(expand)
            XCTAssertFalse(app.buttons["chat-row-" + project + "-11"].exists, "Disclosure adds one page of five")
            let second = app.buttons["more-chats-second-project"]
            reveal(second)
            XCTAssertTrue(second.label.contains(remaining), "Expanding one project must not expand another")
            XCTAssertFalse(app.buttons["chat-row-second-project-6"].exists)
            let collapse = app.buttons["fewer-chats-" + project]
            reveal(collapse, up: false)
            XCTAssertTrue(collapse.label.contains(fewer))
            collapse.tap()
            XCTAssertFalse(app.buttons["chat-row-" + project + "-6"].exists)

            let search = app.searchFields.firstMatch
            reveal(search, up: false)
            search.tap(); search.typeText("chat 12")
            let hidden = app.buttons["chat-row-" + project + "-12"]
            XCTAssertTrue(hidden.waitForExistence(timeout: 5), "Search includes undisclosed chats")
            XCTAssertTrue(app.buttons["chat-row-second-project-12"].exists)
            XCTAssertFalse(expand.exists)
            hidden.tap()
            XCTAssertTrue(app.textViews["message-text-list-message"].waitForExistence(timeout: 5), "Disclosed/search rows open the live chat")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            XCTAssertTrue(expand.label.contains(remaining), "Clearing search restores the collapsed limit")
            app.terminate()
        }
    }

    @MainActor func testChatModelAndAccessChoicesInBothLanguages() throws {
        for (language, full, ask, pending) in [("ru", "Полный доступ", "С подтверждениями", "Настройки ожидают Mac"),
                                              ("en", "Full access", "Ask for approval", "Settings waiting for Mac")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-actions", "-preview-settings", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            XCTAssertTrue(app.buttons["chat-settings"].waitForExistence(timeout: 10))
            app.buttons["chat-settings"].tap()
            XCTAssertTrue(app.buttons["chat-model"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["save-chat-settings"].isEnabled)
            app.buttons["chat-model"].tap(); app.buttons["Model B"].tap()
            app.buttons["chat-access"].tap(); app.buttons[full].tap()
            XCTAssertTrue(app.buttons["save-chat-settings"].isEnabled)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Chat settings " + language; screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["chat-access"].tap(); app.buttons[ask].tap()
            app.buttons["save-chat-settings"].tap()
            XCTAssertTrue(app.staticTexts["chat-settings-status"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["chat-settings-status"].label, pending)
            XCTAssertFalse(app.buttons["save-chat-settings"].isEnabled)
            app.terminate()
        }
    }

    @MainActor func testNewChatAndPermissionReplyInBothLanguages() throws {
        for (language, empty, waiting) in [("ru", "Пустой проект", "Ожидает Mac"), ("en", "Empty project", "Waiting for Mac")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-actions", "-interfaceLanguage", language]
            app.launch()
            XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 10))
            app.buttons["new-chat"].tap()
            let input = app.descendants(matching: .any)["new-chat-message"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            app.buttons["new-chat-project"].tap()
            app.buttons[empty + " · Mac"].tap()
            // Models from every ready agent are offered; the choice names the agent that will run the chat.
            app.buttons["chat-model"].tap(); app.buttons["Claude Model"].tap()
            XCTAssertEqual(app.staticTexts["chat-agent"].label, language == "ru" ? "Агент: Claude" : "Agent: Claude")
            let agents = XCTAttachment(screenshot: app.screenshot())
            agents.name = "New chat agent " + language; agents.lifetime = .keepAlways; add(agents)
            app.buttons["chat-model"].tap(); app.buttons["Model B"].tap()
            XCTAssertEqual(app.staticTexts["chat-agent"].label, language == "ru" ? "Агент: Codex" : "Agent: Codex")
            app.buttons["chat-access"].tap()
            app.buttons[language == "ru" ? "Полный доступ" : "Full access"].tap()
            XCTAssertFalse(app.buttons["create-chat"].isEnabled)
            input.tap(); input.typeText("New conversation fixture")
            let create = app.buttons["create-chat"]
            if !create.isHittable { app.swipeUp() }
            XCTAssertTrue(create.isEnabled)
            create.tap()
            XCTAssertTrue(app.staticTexts["new-chat-status"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.staticTexts["new-chat-status"].label, waiting)
            XCTAssertFalse(app.buttons["create-chat"].exists)
            app.terminate()

            app.launchArguments += ["-preview-chat", "-preview-long"]
            app.launch()
            let banner = app.buttons["show-approvals"]
            XCTAssertTrue(banner.waitForExistence(timeout: 10))
            banner.tap()
            let allow = app.buttons["allow-approval"], deny = app.buttons["deny-approval"]
            XCTAssertTrue(allow.isHittable && deny.isHittable)
            allow.tap()
            let acknowledged = NSPredicate { _, _ in !allow.isEnabled && !deny.isEnabled }
            expectation(for: acknowledged, evaluatedWith: nil)
            waitForExpectations(timeout: 8)
            XCTAssertTrue(app.staticTexts[waiting].firstMatch.exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Permission reply " + language; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }

    @MainActor func testOfflineConnectionStatusInBothLanguagesPreservesChat() throws {
        for (language, status) in [("ru", "Нет сети. Подключимся после её восстановления."),
                                   ("en", "Offline. Will reconnect when the network returns.")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-chat", "-preview-offline", "-interfaceLanguage", language]
            app.launch()
            XCTAssertTrue(app.staticTexts[status].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.textViews["message-text-m2"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["message-input"].firstMatch.exists)
            app.terminate()
        }
    }

    @MainActor func testPhotoComposerDoesNotOverlapKeyboardInBothLanguages() throws {
        for (language, hide, done) in [("ru", "Скрыть клавиатуру", "Готово"), ("en", "Hide keyboard", "Done")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            let input = app.descendants(matching: .any)["message-input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap()
            input.typeText("Photo test")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let send = app.buttons["send-message"]
            let photos = app.buttons["add-photos"]
            XCTAssertTrue(send.isHittable)
            XCTAssertTrue(photos.isHittable)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1)
            XCTAssertFalse(app.buttons[done].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Photo composer " + language; screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons[hide].tap()
            photos.tap()
            // The system picker opens without requesting broad library access.
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5) || app.buttons["Отменить"].exists)
            app.terminate()
        }
    }

    @MainActor func testNativeJumpCancelsInFlightScrolling() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: root.view.bounds)
        root.view.addSubview(scroll)
        scroll.contentSize = CGSize(width: 320, height: 12_000)
        scroll.contentInset.bottom = 40
        let controller = TranscriptScrollController()
        controller.scrollView = scroll
        XCTAssertTrue(controller.jumpToBottom())
        let bottom = scroll.contentOffset.y
        scroll.setContentOffset(.zero, animated: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertLessThan(scroll.contentOffset.y, bottom, "The test must interrupt actual movement")
        XCTAssertTrue(controller.jumpToBottom())
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1, "Old motion must not resume after the jump")
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
    }

    @MainActor func testOpeningLongChatAndRepeatedJumpToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mobile-preview", "-preview-chat", "-preview-long", "-interfaceLanguage", "en"]
        app.launch()
        let tail = app.textViews["message-text-long-19"]
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        XCTAssertTrue(tail.isHittable, "Opening a long chat must show the last message")
        let scroll = app.scrollViews["conversation-scroll"]
        let jump = app.buttons["jump-to-latest"]
        for velocity in [XCUIGestureVelocity.slow, .fast, .fast] {
            scroll.swipeDown(velocity: velocity)
            scroll.swipeDown(velocity: velocity)
            XCTAssertTrue(jump.waitForExistence(timeout: 3))
            jump.tap()
            let reachedBottom = NSPredicate { _, _ in tail.isHittable && !jump.exists }
            expectation(for: reachedBottom, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        app.buttons["Hide keyboard"].tap()
        let hidden = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        expectation(for: hidden, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(tail.isHittable)
    }
}

final class AnswerControlTests: XCTestCase {
    @MainActor func testFilePathOpensReadOnlyViewerInBothLanguages() throws {
        for (language, truncated, done) in [("ru", "Показано начало файла", "Готово"), ("en", "Showing the start of the file", "Done")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-rich", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            app.scrollViews["conversation-scroll"].swipeDown(velocity: .fast)
            app.scrollViews["conversation-scroll"].swipeDown(velocity: .fast)
            let path = app.links["Sources/ContextCore/MobileRemote.swift"].firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 5))
            path.tap()
            let content = app.textViews["file-content"].firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            let text = content.value as? String ?? ""
            XCTAssertTrue(text.contains("let line1 = 1"), text)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", truncated)).firstMatch.exists)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "File viewer " + language; shot.lifetime = .keepAlways; add(shot)
            app.buttons[done].firstMatch.tap()
            XCTAssertTrue(app.scrollViews["conversation-scroll"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor func testSelectionQuotesIntoReplyInBothLanguages() throws {
        for (language, quote) in [("ru", "Цитировать в ответ"), ("en", "Quote in reply")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            // Long press selects one word of the answer, not the whole message.
            let answer = app.textViews["message-text-m2"]
            XCTAssertTrue(answer.waitForExistence(timeout: 10))
            answer.press(forDuration: 1.0)
            let action = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", quote)).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Selection menu " + language; shot.lifetime = .keepAlways; add(shot)
            action.tap()
            let input = app.descendants(matching: .any)["message-input"].firstMatch
            let quoted = NSPredicate { _, _ in (input.value as? String)?.hasPrefix("> ") == true }
            expectation(for: quoted, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let draft = input.value as? String ?? ""
            XCTAssertLessThan(draft.count, 40, "Only the selected fragment is quoted: " + draft)
            app.terminate()
        }
    }

    @MainActor func testRichAnswerControlsInBothLanguages() throws {
        for (language, copied, commands, cut, access) in [
            ("ru", "Скопировано", "Копировать команды", "Сокращено · полный текст на Mac", "С подтверждениями"),
            ("en", "Copied", "Copy commands", "Shortened · full text on Mac", "Ask for approval")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-rich", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            let running = app.descendants(matching: .any)["running-activity"].firstMatch
            XCTAssertTrue(running.waitForExistence(timeout: 10))
            XCTAssertTrue(running.label.contains("Bash · zsh scripts/test.sh --changed"), running.label)
            XCTAssertTrue(app.staticTexts[cut].exists)
            XCTAssertTrue(app.buttons["chat-settings"].exists)
            XCTAssertTrue(app.buttons["chat-access-chip"].label.contains(access))
            let shell = app.buttons.matching(identifier: "copy-code").matching(NSPredicate(format: "label CONTAINS %@", commands)).firstMatch
            XCTAssertTrue(shell.exists)
            shell.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "copy-code").matching(NSPredicate(format: "label CONTAINS %@", copied)).firstMatch.waitForExistence(timeout: 2))
            let bottom = XCTAttachment(screenshot: app.screenshot())
            bottom.name = "Rich answer bottom " + language; bottom.lifetime = .keepAlways; add(bottom)
            app.scrollViews["conversation-scroll"].swipeDown(velocity: .fast)
            app.scrollViews["conversation-scroll"].swipeDown(velocity: .fast)
            XCTAssertTrue(app.textViews["message-text-rich"].waitForExistence(timeout: 3))
            let top = XCTAttachment(screenshot: app.screenshot())
            top.name = "Rich answer top " + language; top.lifetime = .keepAlways; add(top)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["chat-row-preview-chat"].waitForExistence(timeout: 5))
            let list = XCTAttachment(screenshot: app.screenshot())
            list.name = "Chat list " + language; list.lifetime = .keepAlways; add(list)
            app.terminate()
        }
    }
}
