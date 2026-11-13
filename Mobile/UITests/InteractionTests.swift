import XCTest

/// Stage 2 phone controls: agent questions and forms, messages for a working chat, roles and add-ons.
final class InteractionTests: XCTestCase {
    @MainActor private func launch(_ arguments: [String], language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobile-preview", "-preview-chat"] + arguments + ["-interfaceLanguage", language]
        app.launch()
        return app
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func waitUntil(_ timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) {
        expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        waitForExpectations(timeout: timeout)
    }

    @MainActor func testPushSettingsStatesInBothLanguages() {
        for (language, states) in [
            ("en", [("notAsked", "Permission has not been requested"), ("allowed", "Notifications connected"),
                    ("denied", "Allow notifications in iOS Settings"), ("schema", "Update the Supabase schema and Mac app")]),
            ("ru", [("notAsked", "Разрешение ещё не запрошено"), ("allowed", "Уведомления подключены"),
                    ("denied", "Разреши уведомления в настройках iOS"), ("schema", "Обнови схему Supabase и приложение на Mac")])
        ] {
            for (state, expected) in states {
                let app = XCUIApplication()
                app.launchArguments = ["-mobile-preview", "-preview-push", state, "-interfaceLanguage", language]
                app.launch()
                let settings = app.buttons["open-settings"]
                XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
                let status = app.staticTexts["push-status"]
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                XCTAssertEqual(status.label, expected)
                XCTAssertTrue(app.switches["push-toggle"].exists)
                app.terminate()
            }
        }
    }
    @MainActor func testPushMarkerRoutesToPublishedChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobile-preview", "-preview-push-route", "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Mobile app"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testAnsweringQuestionWithOptionAndOtherInBothLanguages() throws {
        for (language, first, second, waiting, needs) in [("ru", "1 из 2", "2 из 2", "Ожидает Mac", "Ждут ответа: 2"),
                                                          ("en", "1 of 2", "2 of 2", "Waiting for Mac", "Waiting for you: 2")] {
            let app = launch(["-preview-question"], language: language)
            let card = app.descendants(matching: .any)["question-card"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(card.staticTexts[first].exists)
            // The card replaces the activity line and stays above the composer.
            XCTAssertFalse(app.descendants(matching: .any)["running-activity"].firstMatch.exists)
            let send = app.buttons["send-answer"]
            XCTAssertFalse(send.isEnabled, "Nothing chosen yet")
            XCTAssertLessThan(send.frame.maxY, app.descendants(matching: .any)["message-input"].firstMatch.frame.minY)
            let option = app.buttons["question-option-database-0"]
            option.tap()
            XCTAssertTrue(option.isSelected)
            XCTAssertTrue(send.isEnabled)
            XCTAssertTrue(app.descendants(matching: .any)["question-preview"].firstMatch.exists, "The chosen option shows its preview")
            // Free text replaces the chosen option.
            let other = app.descendants(matching: .any)["question-other-database"].firstMatch
            other.tap(); other.typeText("MySQL")
            XCTAssertFalse(option.isSelected)
            XCTAssertTrue(send.isEnabled)
            shot(app, "Question card " + language)
            send.tap()
            // The next request (a form) follows; its optional field may stay empty, the required one may not.
            XCTAssertTrue(card.staticTexts[second].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["decline-question"].exists)
            XCTAssertFalse(send.isEnabled)
            let branch = app.descendants(matching: .any)["question-other-branch"].firstMatch
            branch.tap(); branch.typeText("release/1.4")
            XCTAssertTrue(send.isEnabled)
            shot(app, "Form card " + language)
            send.tap()
            // With every request answered the first one comes back with its status, and nothing can be sent twice.
            let status = app.staticTexts["question-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 8))
            XCTAssertEqual(status.label, waiting)
            XCTAssertFalse(send.isEnabled)
            app.navigationBars.buttons.firstMatch.tap()
            let row = app.buttons["needs-row-preview-chat"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.label.contains(needs), row.label)
            app.terminate()
        }
    }

    @MainActor func testMacOnlyFormOffersOnlyDeclineInBothLanguages() throws {
        for (language, message, waiting) in [("ru", "Запрос просит секрет. Ответь на Mac: секреты не передаются через облако.", "Ожидает Mac"),
                                             ("en", "The request asks for a secret. Answer on the Mac: secrets are never sent through the cloud.", "Waiting for Mac")] {
            let app = launch(["-preview-form-maconly"], language: language)
            let note = app.descendants(matching: .any)["question-mac-only"].firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 10))
            XCTAssertEqual(note.label, message)
            XCTAssertFalse(app.buttons["send-answer"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["question-other-token"].firstMatch.exists, "A secret is never asked for on the phone")
            let decline = app.buttons["decline-question"]
            XCTAssertTrue(decline.isEnabled)
            shot(app, "Mac-only form " + language)
            decline.tap()
            let status = app.staticTexts["question-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 8))
            XCTAssertEqual(status.label, waiting)
            XCTAssertFalse(decline.isEnabled)
            app.terminate()
        }
    }

    @MainActor func testQueueAndInterruptWhileRunningInBothLanguages() throws {
        for (language, queued, more, waiting, interrupt) in [("ru", "В очереди: 5", "Ещё 2", "Ожидает Mac", "Прервать и отправить"),
                                                             ("en", "Queued: 5", "+2 more", "Waiting for Mac", "Interrupt and send")] {
            let app = launch(["-preview-queue"], language: language)
            let list = app.descendants(matching: .any)["queue-list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            XCTAssertTrue(list.staticTexts[queued].exists)
            XCTAssertEqual(app.staticTexts["queue-more"].label, more)
            // An empty draft keeps Stop; a draft turns the button into Queue.
            XCTAssertTrue(app.buttons["stop-agent"].exists)
            let input = app.descendants(matching: .any)["message-input"].firstMatch
            input.tap(); input.typeText("Queued from the phone")
            let queue = app.buttons["queue-message"]
            XCTAssertTrue(queue.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["stop-agent"].exists)
            shot(app, "Queue composer " + language)
            queue.tap()
            let mine = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "queued-command:"))
            waitUntil { mine.count == 1 }
            XCTAssertTrue(mine.firstMatch.label.contains(waiting), mine.firstMatch.label)
            XCTAssertFalse((input.value as? String ?? "").contains("Queued from the phone"), "The draft clears after the command is stored")
            XCTAssertTrue(app.buttons["stop-agent"].exists)
            // Interrupt and send sits behind a long press on Queue.
            input.tap(); input.typeText("Stop and do this instead")
            queue.press(forDuration: 1.2)
            let action = app.buttons[interrupt]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            shot(app, "Interrupt menu " + language)
            action.tap()
            waitUntil { mine.count == 2 }
            XCTAssertFalse((input.value as? String ?? "").contains("Stop and do this instead"))
            app.terminate()
        }
    }

    @MainActor func testRoleAndAddOnChoicesInBothLanguages() throws {
        for (language, developer, editor, chrome, beyond, pending) in [
            ("ru", "Разработчик", "Редактор", "Мой Chrome", "Включено на Mac сверх настроек проекта", "Настройки ожидают Mac"),
            ("en", "Developer", "Editor", "My Chrome", "Turned on at the Mac beyond the project default", "Settings waiting for Mac")
        ] {
            let app = launch(["-preview-roles"], language: language)
            let chip = app.buttons["chat-role-chip"]
            XCTAssertTrue(chip.waitForExistence(timeout: 10))
            XCTAssertTrue(chip.label.contains(developer) && chip.label.contains(chrome), chip.label)
            XCTAssertFalse(app.buttons["chat-access-chip"].exists, "The role replaces the access chip")
            chip.tap()
            let role = app.buttons["chat-role"]
            XCTAssertTrue(role.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["chat-access"].exists)
            let save = app.buttons["save-chat-settings"]
            XCTAssertFalse(save.isEnabled)
            let addOn = app.switches["chat-add-on-userChrome"]
            if !addOn.isHittable { app.swipeUp() }
            XCTAssertEqual(addOn.value as? String, "1")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", beyond)).firstMatch.exists)
            shot(app, "Role settings " + language)
            addOn.switches.firstMatch.tap()
            waitUntil(3) { addOn.value as? String == "0" }
            if !role.isHittable { app.swipeDown() }
            role.tap(); app.buttons[editor].tap()
            if !save.isHittable { app.swipeUp() }
            XCTAssertTrue(save.isEnabled)
            save.tap()
            let status = app.staticTexts["chat-settings-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 8))
            XCTAssertEqual(status.label, pending)
            app.terminate()
        }
    }

    @MainActor func testNewChatOffersRolesAndProjectAddOns() throws {
        let app = launch(["-preview-roles"], language: "en")
        XCTAssertTrue(app.buttons["chat-role-chip"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let create = app.buttons["new-chat"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let role = app.buttons["chat-role"]
        XCTAssertTrue(role.waitForExistence(timeout: 5))
        XCTAssertTrue(role.label.contains("Developer · default"), role.label)
        let mail = app.switches["chat-add-on-mail"]
        if !mail.isHittable { app.swipeUp() }
        XCTAssertEqual(mail.value as? String, "1", "A new chat starts with the project's add-ons")
        XCTAssertFalse(app.switches["chat-add-on-userChrome"].exists, "Only add-ons within the project default are offered")
        shot(app, "New chat roles en")
        app.terminate()
    }
}
