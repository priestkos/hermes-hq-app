// Send, Stop, queue and steer races found in the build 863 audit (chat logic): a refusal or a steer answer landing after
// Stop, a stop hold that runs out, a second Stop while the first interrupt is out, a goal continuation overtaken by Stop,
// sends made before a task's chat opened, a queue kept from an earlier visit, and a lost send's "Not Delivered" mark.
// Driven like the live-session suite: FakeGatewayClient with scripted RPC answers and events.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("Stop and send races (audit 863)", .serialized)
@MainActor
struct StopSendRaceTests {
    private func submitted(_ h: ChatHarness) -> [String] {
        h.client.calls("prompt.submit").compactMap { $0.params["text"]?.string }
    }

    /// A steer that is turned down after Stop waits in the paused queue; it and nothing queued before it goes out.
    @Test func aSteerTurnedDownAfterStopWaitsInThePausedQueue() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect":
                try await Task.sleep(for: .milliseconds(150))
                return ["status": "rejected"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("long one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working"])])
        s.send("also this")                                                   // steered into the reply
        #expect(await waitUntil { !h.client.calls("session.redirect").isEmpty })
        s.stop()
        #expect(await waitUntil { s.queuedMessages.count == 1 })
        #expect(s.queuedMessages.first?.text == "also this")
        #expect(s.isQueueParked)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(submitted(h) == ["long one"])                                 // nothing sent on its own
    }

    /// A refusal for the stopped message that lands after the next one began never ends that next message's turn: the
    /// stopped words come back as stopped, with no "Couldn't Send" card.
    @Test func aRefusalAfterStopLeavesTheNextMessagesTurnAlone() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .milliseconds(800)
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit":
                if params["text"] == "first" {
                    try await Task.sleep(for: .milliseconds(150))
                    throw RPCError(code: 4099, message: "Not now.")
                }
                return ["status": "streaming", "user_row_id": 4200]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("first")
        #expect(await waitUntil { !h.client.calls("prompt.submit").isEmpty })
        s.stop()
        s.send("second")                                                      // waits out the stop hold
        #expect(await waitUntil { !h.drafts.isEmpty })
        s.flushChanges()
        #expect(h.drafts.first?.0 == "first")
        #expect(h.drafts.first?.1 == "Stopped before sending")
        #expect(s.sendFailure == nil)
        #expect(s.isRunning)                                                  // "second" still owns the turn
        #expect(s.turn.submitHeld)                                            // …and its hold behind the Stop
        #expect(h.lastUser?.plainText == "second")
        #expect(await waitUntil { submitted(h) == ["first", "second"] })
    }

    /// Stop while a send waits for another Hermes run to let go of the chat hands the words back at once, not when the
    /// wait's next pause (up to 8 s) ends.
    @Test func stopDuringTheOwnerWaitHandsTheWordsBackAtOnce() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .seconds(2)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit":
                throw RPCError(code: 4090, message: "This chat is open in another Hermes window/terminal.\n"
                               + "Details: session 20260101_090000_aa0001 opened by cli 9m ago.", data: ["reason": "SESSION_NOT_OWNED"])
            case "session.interrupt": return ["status": "interrupted"]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send("waiting one")
        #expect(await waitUntil { s.ownerWaitNotice != nil })
        let start = ContinuousClock.now
        s.stop()
        #expect(await waitUntil(timeout: .seconds(1)) { !h.drafts.isEmpty })
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(h.drafts.first?.0 == "waiting one")
        #expect(h.drafts.first?.1 == "Stopped before sending")
        #expect(h.client.calls("prompt.submit").count == 1)
    }

    /// The stopped turn outlives the 6 s hold: the next message goes out queued, and the stopped turn's late text and end
    /// are never drawn as its answer. Its own turn shows once the stopped one ended.
    @Test func aStoppedTurnOutlivingTheHoldIsNotTheNextMessagesAnswer() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .milliseconds(100)
        s.turnEndReadDelay = .seconds(10)                                     // no reads in the middle of this
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit":
                return params["text"] == "one" ? ["status": "streaming", "user_row_id": 4300] : ["status": "queued", "user_row_id": 4302]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Partial"])])
        s.stop()
        s.send("two")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == true)
        #expect(await waitUntil { h.lastUser?.rowId == 4302 })
        // The stopped turn, still unwinding: its late words and its end.
        await h.emit([h.event("message.delta", ["text": " and late words"]),
                      h.event("message.complete", ["text": "Partial and late words", "status": "interrupted",
                                                   "persisted_turn": ["user_row_id": 4300]])])
        s.flushChanges()
        let two = try #require(s.messages.lastIndex { $0.role == .user && $0.plainText == "two" })
        #expect(!s.messages[(two + 1)...].contains { $0.role == .assistant })
        #expect(s.isRunning)
        #expect(!s.turn.interrupted)                                          // the stopped turn ended: let go
        // "two"'s own turn, run by the gateway's queue.
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Answer to two"]),
                      h.event("message.complete", ["text": "Answer to two", "status": "complete",
                                                   "persisted_turn": ["user_row_id": 4302]])])
        s.flushChanges()
        let after = Array(s.messages[(two + 1)...])
        #expect(after.filter { $0.role == .assistant }.map(\.plainText) == ["Answer to two"])
        #expect(!s.isRunning)
    }

    /// Stop catching an Edit before it went out puts back the messages the Edit took off the screen.
    @Test func stopBeforeAnEditGoesOutPutsTheTranscriptBack() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .milliseconds(200)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": 4400]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("go")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working"])])
        let target = try #require(s.messages.first { $0.role == .user && s.canRewind($0.id) })
        var failed: [String] = []
        #expect(s.edit(target.id, to: "changed words") { failed.append($0) })   // stops the reply, cuts, holds behind it
        let held = try #require(h.lastUser)
        #expect(held.plainText == "changed words")
        let before = s.messages.count
        #expect(!s.messages.contains { $0.id == target.id })
        s.stop()                                                              // Stop again before it goes out
        #expect(await waitUntil { s.messages.contains { $0.id == target.id } })
        s.flushChanges()
        #expect(!s.messages.contains { $0.id == held.id })
        #expect(s.messages.count > before)
        #expect(s.messages.contains { $0.role == .user && $0.plainText == "go" })
        #expect(s.menus.rewinds.isEmpty)
        #expect(failed.isEmpty)
        #expect(h.drafts.isEmpty)
        #expect(submitted(h) == ["go"])
    }

    /// A second Stop while the first interrupt is still out (a slow link) interrupts again once that one answers: a
    /// message sent in between, queued on the gateway, does not run unseen.
    @Test func aSecondStopWhileTheInterruptIsOutInterruptsAgain() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .milliseconds(50)
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return params["text"] == "one" ? ["status": "streaming"] : ["status": "queued"]
            case "session.interrupt":
                try await Task.sleep(for: .milliseconds(300))
                return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "x"])])
        s.stop()
        s.send("two")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(s.isRunning)
        s.stop()                                                              // the first interrupt is still out
        #expect(h.client.calls("session.interrupt").count == 1)               // never two in flight
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 2 })
    }

    /// A hidden goal continuation that Stop overtook on its way is interrupted again once the gateway took it.
    @Test func aGoalContinuationAcceptedAfterStopIsInterruptedAgain() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit":
                try await Task.sleep(for: .milliseconds(150))
                return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.sendHidden("Continue toward the goal.", display: nil)
        #expect(await waitUntil { !h.client.calls("prompt.submit").isEmpty })
        s.stop()
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 2 })
    }

    /// …and one Stop overtook before it went out never goes.
    @Test func aGoalContinuationStoppedBeforeItGoesOutNeverGoes() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        s.runtimeSessionId = nil
        h.client.onCall { method, _ in
            switch method {
            case "session.resume":
                try await Task.sleep(for: .milliseconds(150))
                return try ChatFixtures.json("perf-resume.json")["result"]!
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.sendHidden("Continue toward the goal.", display: nil)
        try? await Task.sleep(for: .milliseconds(20))
        s.stop()
        #expect(await waitUntil { s.runtimeSessionId != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.client.calls("prompt.submit").isEmpty)
        #expect(!s.isRunning)
    }

    /// A send Stop overtook while its pre-send resume was failing comes back as stopped, not as "Couldn’t reach this
    /// chat" (the send-while-reconnecting retry must not swallow the withdraw).
    @Test func aSendStoppedWhileItsResumeFailsComesBackStopped() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.keepQueue()
        #expect(await h.open())
        s.runtimeSessionId = nil
        h.client.onCall { method, _ in
            switch method {
            case "session.resume":
                try await Task.sleep(for: .milliseconds(150))
                throw RPCError(code: 5000, message: "Resume failed.")
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("stopped words")
        try? await Task.sleep(for: .milliseconds(20))
        s.stop()
        #expect(await waitUntil { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "stopped words")
        #expect(h.drafts.first?.1 == "Stopped before sending")
        #expect(s.sendFailure == nil)
        #expect(h.client.calls("prompt.submit").isEmpty)
    }

    /// Messages typed before a task's chat was made go out in the order they were typed, also one sent just as the chat
    /// opened while the first still waited.
    @Test func sendsBeforeTheTaskChatOpensGoInOrder() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let stored = h.stored
        let s = LiveChatSession(client: h.client, account: h.client.account, profile: h.profile, storedSessionId: nil,
                                title: "Task", head: nil, cache: h.cache,
                                resolveSessionId: {
                                    try await Task.sleep(for: .milliseconds(120))
                                    return stored
                                },
                                lastActive: nil, frameMode: .manual)
        h.session = s
        s.opensOnFirstSend = true
        h.client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate": return try ChatFixtures.json("perf-resume.json")["result"]!
            case "prompt.submit": return ["status": "streaming"]
            default: return [:]
            }
        }
        s.start()
        s.redirectUnsupported = true                                          // typed words queue behind the reply
        s.send("one")
        s.send("two")
        #expect(await waitUntil { s.openSettled })
        s.send("three")
        #expect(await waitUntil { submitted(h).count == 1 && s.queuedMessages.count == 2 })
        #expect(submitted(h) == ["one"])
        #expect(s.queuedMessages.map(\.text) == ["two", "three"])
    }

    /// A queue kept from an earlier visit is taken over when the chat's stored id comes in late, after the messages
    /// queued meanwhile, which stay.
    @Test func aKeptQueueJoinsTheOneMadeBeforeTheChatsIdCame() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        QueueStash.shared.purge(accountId: h.client.account.id)
        defer { QueueStash.shared.purge(accountId: h.client.account.id) }
        // An earlier visit left "kept" parked in the stash.
        let earlier = h.make()
        earlier.keepQueue()
        earlier.adoptStashedQueue([QueuedMessage(id: earlier.nextQueuedId(), text: "kept")], parked: true)
        earlier.releaseStashedQueue()
        #expect(QueueStash.shared.items(accountId: h.client.account.id, scope: earlier.layoutScope).map(\.text) == ["kept"])
        // This visit queued "new" before the stored id was known.
        let s = LiveChatSession(client: h.client, account: h.client.account, profile: h.profile, storedSessionId: nil,
                                title: "Hermes", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        s.keepQueue()
        s.adoptStashedQueue([QueuedMessage(id: s.nextQueuedId(), text: "new")], parked: false)
        s.storedSessionId = h.stored
        s.queueScopeResolved()
        #expect(s.queuedMessages.map(\.text) == ["kept", "new"])
        #expect(!s.isQueueParked)                                             // the fresh message's unpark stands
        #expect(QueueStash.shared.items(accountId: h.client.account.id, scope: s.layoutScope).map(\.text) == ["kept", "new"])
    }

    /// A lost send in a chat whose earlier messages have no stored row numbers yet is not taken as arrived by an older
    /// message with the same words.
    @Test func aLostSendIsNotClearedByAnOlderMessageWithTheSameWords() throws {
        let h = try ChatHarness()
        let s = h.make()
        let lost = LostSends(base: FileManager.default.temporaryDirectory.appending(path: "lost-\(UUID().uuidString)"))
        s.lostSends = lost
        s.appendMessage(ChatMessage(id: "local-user-earlier", role: .user, parts: [.text("yes")],
                                    timestamp: Date(timeIntervalSinceNow: -3600), rowId: nil))
        var mine = ChatMessage(id: "local-user-mine", role: .user, parts: [.text("yes")], timestamp: Date(), rowId: nil)
        mine.error = LiveChatSession.unconfirmedMark
        s.appendMessage(mine)
        s.noteLostSend("local-user-mine", memo: false)
        let entry = try #require(lost.entries(accountId: h.client.account.id, profile: h.profile, chatId: h.stored).first)
        #expect(entry.after == nil)                                           // judged by its time, not "after row 0"
        // A read numbers the earlier "yes" (an hour old); the marked bubble is gone from the screen meanwhile.
        s.removeMessage("local-user-mine")
        s.updateMessage("local-user-earlier") { $0.rowId = 41 }
        s.settleLostSends()
        #expect(lost.entries(accountId: h.client.account.id, profile: h.profile, chatId: h.stored).count == 1)
        // In a new chat (nothing before it) row 0 still holds.
        let fresh = LiveChatSession(client: h.client, account: h.client.account, profile: h.profile, storedSessionId: "new-chat",
                                    title: "Hermes", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        fresh.lostSends = lost
        fresh.appendMessage(mine)
        fresh.noteLostSend("local-user-mine", memo: false)
        #expect(lost.entries(accountId: h.client.account.id, profile: h.profile, chatId: "new-chat").first?.after == 0)
    }
}
