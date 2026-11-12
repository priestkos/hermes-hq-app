// The open chat (contract `ChatSessionModel`): cached paint on init, the open sequence (spec 03 §4), send (04 §2),
// the live turn fold (04 §4, in LiveChatSession+Events.swift), Stop (04 §5, §5.6), refresh / paging / reconnect
// catch-up (03 §5, §7.6; 04 §7, in LiveChatSession+Sync.swift). Main actor. Changes reach the screen through
// `onChange`, coalesced to one delivery per display frame.

import Foundation

/// Per-turn client state (04 §4 `ClientSessionState`).
struct TurnState {
    var busy = false
    var awaitingResponse = false
    var sawAssistantPayload = false
    var turnLive = false
    var interrupted = false
    var stopPending = false            // the interrupt did not reach the turn (5032 / timeout), §5.6 step 4
    var stopRetried = false
    var stopTerminalPending = false    // Stop sent; terminal frame not seen yet (holds the next send ≤ 6 s, §5.4)
    var interimBoundaryPending = false
    var streamId: String?              // the live assistant message
    var openPart: (index: Int, reasoning: Bool)?
    var heartbeatSettledStreamId: String?
    var turnStartedAt: Date?
    var armedAt: Date?
    var generatingTool: String?
    var providerWait: String?
    var compacting = false
    var lastEventAt: Date?
    /// The turn's own user bubble (displayed id): set by our send, by the inflight graft on a mid-turn open, nil for a
    /// turn this phone didn't start (another device, a server-drained queue). Scopes the turn instead of "last user row".
    var userAnchorId: String?
    /// The display key of the prompt that anchored turn actually submitted: a skill, titled request or attachment send
    /// shows other text in its bubble than it sent, and a resume snapshot's `inflight.user` names the sent text.
    var anchorPromptKey: String?
    /// The running turn's prompt (display key) as a resume snapshot's `inflight.user` names it: finds that turn's user
    /// row in a page when no bubble of ours anchors it (`liveTurnUserIndex`).
    var inflightUserKey: String?
    /// The stopped turn's user bubble, for its late interrupted partial (04 §5.4) after a new send moved the anchor.
    var stoppedAnchorId: String?
    /// `session.info running:false` (or a snapshot saying not running) seen since the turn settled.
    var idleConfirmed = false
    /// [desktop-forward] The send went into the gateway's queue (`prompt.submit` answered `forwarded`: the chat is open
    /// in the desktop app, or the gateway is running a turn there; add-on 0.9.16, Hermes owner_forward). Its turn runs
    /// in the gateway, maybe after the desktop's own reply; this runtime relays only its `message.start` and
    /// `message.complete` and runs nothing itself, so silence and "not running" here say nothing about it.
    var forwarded = false
    /// A send waits for the stopped turn's terminal frame (04 §5.4); until it goes out, frames are the stopped turn's.
    var submitHeld = false
    /// The held send's 6 s hold ran out and it went to the gateway `queued` behind the stopped turn, still held: that
    /// turn's late frames are not its reply. The stopped turn's terminal frame lets it go (`releaseSendPastStop`).
    var sentPastStop = false
    /// [attachments] The send (its local bubble id) still uploading and attaching its photos and files
    /// (docs/spec/1x-attachments.md §6.4 steps 3–5): nothing reached the gateway yet, so the silence watchdog and a
    /// `running:false` heartbeat must not settle its turn (a 32 MB video over a relay takes well over 45 s).
    var preparingSendId: String?
    /// The send was refused `4090 SESSION_NOT_OWNED`: another Hermes process (a cron job's or a background delivery's
    /// one-shot `hermes chat`) holds this chat for its run. The send waits and goes out when the chat is free; meanwhile
    /// `preparingSendId` names it (nothing reached the gateway), and the status and a card above the composer say so.
    var waitingForOwner: OwnerWait?
    /// Messages steered into this turn while it ran (`beginSteer`): user bubbles inside the turn's rows, not the next
    /// prompt, so its end still finds the reply that answers them below them.
    var correctionIds: Set<String> = []
    /// When this turn's send went out behind a stopped turn: that turn's own end-of-turn snapshot may still land after
    /// this one started, and is not about it (`onSessionInfo`).
    var followsStopAt: Date?
}

/// [owner-wait] Who holds the chat a send is waiting for (`LiveChatSession.submit`, 4090 SESSION_NOT_OWNED).
nonisolated enum OwnerWait: Equatable, Sendable {
    /// A one-shot `hermes chat` on the gateway computer: a scheduled job, or a message from another bot.
    case backgroundTask
    /// Any other live runtime: a short wait, then "Couldn't Send". Never named as "your computer": this app opens its
    /// chats as surface "desktop" too, so "opened by desktop" is as often an earlier connection of this phone's as the
    /// desktop app.
    case otherWindow
    /// `4090 SESSION_OWNER_BUSY`: the gateway is running a turn in this chat and couldn't queue yours behind it. That
    /// turn ends on its own, so the send waits as long as for a background task (build 337 feedback).
    case runningReply
    /// A turn the messaging gateway runs in this chat for a message from Telegram, Discord or another platform (its
    /// holder is "gateway:<platform>"). It lets go when that turn ends, so the send waits as long as for a background
    /// task. The platform's name ("Telegram"), or nil when the holder doesn't name one. A tester 2026-10-30: that
    /// wait read as "an earlier connection" and gave up after a few seconds.
    case messagingTurn(String?)

    var status: String {
        switch self {
        case .backgroundTask: "Waiting for a background task…"
        case .messagingTurn(let app): "Waiting while Hermes answers \(app ?? "another app")…"
        case .otherWindow: "Waiting for this chat to free up…"
        case .runningReply: "Waiting for the current reply…"
        }
    }
    /// [diagnostics] The holder in a send's trace line.
    var logWord: String {
        switch self {
        case .backgroundTask: "one-shot run"
        case .otherWindow: "elsewhere"
        case .runningReply: "busy"
        case .messagingTurn(let app): "messaging turn \(app ?? "?")"
        }
    }
    static let cardTitle = "Your message is waiting"
    var cardBody: String {
        switch self {
        case .backgroundTask:
            "Hermes is running a scheduled job or a message from another bot in this chat. Yours sends as soon as it’s done. You can keep typing."
        case .otherWindow:
            "Hermes has this chat open somewhere else, like the Hermes desktop app or an earlier connection. Yours sends if it frees up in the next few seconds."
        case .runningReply:
            "Hermes is still running a reply in this chat. Yours sends as soon as it’s done. You can keep typing."
        case .messagingTurn(let app):
            "Hermes is answering a message from \(app ?? "another app") in this chat. Yours sends as soon as it’s done. You can keep typing."
        }
    }
    static let cancelTitle = "Cancel Message"
}

/// A message waiting for the running reply to finish (04 §6.2 M1: a local FIFO shown as a queue card, never as
/// transcript rows; drained with `queued:true` after the turn ends).
nonisolated struct QueuedMessage: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let text: String
    /// [attachments] Photos and files sent with it (docs/spec/1x-attachments.md §6.4 step 1); they keep uploading.
    var attachments: [DraftAttachment] = []
    /// VOICE: a voice memo waiting with `text` typed beside it (nil for text), spec 1x-voice §4.4.
    var memo: MemoFile? = nil
    // [activity] A goal continuation queued behind a running reply (docs/spec/1x-activity.md §6.4): sent with
    // `display_kind: "hidden"` (no bubble); the queue card shows `display ?? "Continue toward goal"`.
    var hidden = false
    // MENUS (spec 1x §8.3): a skill send's bubble shows its invocation; `text` (the expanded body) goes on the wire.
    // [activity] For a hidden continuation, the words Hermes gave it.
    var display: String? = nil
}

final class LiveChatSession: ChatSessionModel {
    /// [presence] Requests sent with a title for their bubble (`MainBotRequest.queue`): the title outlives the reply's
    /// transcript read (HermesKit/Presence/SentTitles.swift).
    static var sentTitles = SentTitles()

    // MARK: ChatSessionModel

    var title: String
    /// The app's own short title was tried for this chat (`ShortTitle`); once per open.
    var shortTitleTried = false
    let profile: String
    /// The bot's head record; the app model updates it when the bot is edited while its chat is open.
    var head: JSONValue?
    var messages: [ChatMessage] = []
    var isRunning: Bool { turn.busy }
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .connecting
    var statusText: String?
    var onChange: ((ChatChange) -> Void)?

    // MARK: Extra API for the chat screen / app model

    /// A refused send hands its text back to the composer with the gateway's reason (04 §2.4.1: refused, not lost).
    var onDraftReturned: ((_ text: String, _ reason: String) -> Void)?
    /// One-line toasts ("Couldn't stop — Hermes finished the reply.", chat-level errors).
    var onNotice: ((String) -> Void)?
    /// `4064 Profile '<name>' does not exist.`: the roster is stale — refetch `/api/profiles`, never retry (04 §1.4).
    var onRosterStale: (() -> Void)?
    /// The open failed with nothing to show (03 §4.7): the screen shows an error state with Retry (`start()` again).
    var openError: String?
    /// The id this chat was opened with (the cache key). REST/RPC reads use the resolved tip when it differs.
    var storedSessionId: String?
    var runtimeSessionId: String?

    // MARK: App-model hooks (integration)

    /// The bot's display name for the screen's words ("Message Ivy"); the title until the app model sets it.
    var botName: String
    /// The model answering ("Waiting for <model>"), from the roster; nil when unknown.
    var modelName: String?
    /// The screen began (true) or stopped (false) observing this chat.
    var onObservingChange: ((Bool) -> Void)?
    /// The open finished: `true` when fresh history from the gateway was applied (a cached paint alone is `false`).
    var onOpenSettled: ((Bool) -> Void)?
    /// A turn started or ended (`isRunning` flipped), reported with the frame that shows it.
    var onRunningChange: ((Bool) -> Void)?
    /// The chat was bound to a runtime id it did not have (`old` nil on the first bind): a turn already reported running
    /// is then heard under the new id when the chat is off screen.
    var onRuntimeBound: ((_ old: String?, _ new: String) -> Void)?
    /// The chat got its stored id (a new chat, after `session.create`).
    var onStoredIdResolved: ((String) -> Void)?
    /// The chat was left while the read owed for a turn that ended on screen (03 §4.6, 1.2 s after the turn) was still
    /// pending: once it lands, the gateway's time of the newest stored row it saw (the turn's end). The bot's unread
    /// baseline then covers the user's own exchange even when Back came before the read (spec 02 §6.7).
    var onSeenAfterLeaving: ((Date) -> Void)?
    private var reportedRunning = false
    /// What `onRunningChange` last said (`turn.busy` can be ahead of it until the next flush).
    var reportsRunning: Bool { reportedRunning }
    /// [questions] This chat's tie to the account's server requests (LiveChatSession+Prompts.swift, spec 1x §3.6).
    var promptLink: PromptChatLink?
    // MENUS (spec 1x): model state, slash hooks, rename/share hooks (LiveChatSession+Menus.swift).
    var menus = ChatMenusState()
    /// [sessions-m9] Where a send that may never have arrived is kept for its Sessions row (LostSends.swift); the app
    /// gives every chat the account's one store. Nil: nothing is kept.
    var lostSends: LostSends?

    /// Messages waiting for a reply to finish or for the gateway to reconnect, oldest first.
    /// VOICE: settable from LiveChatSession+Memo.swift (memos queue too). Verify round 3: kept beyond the screen in the
    /// account's `QueueStash` (written through while this chat owns it; LiveChatSession+Away.swift).
    /// [m9/composer] Rows being steered into the running reply (the lock, spec §15.4), and a chat whose gateway said it
    /// cannot redirect (4010, -32601): Send Now is not offered while busy from then on.
    var steeringIds: Set<String> = []
    var redirectUnsupported = false
    /// [composer] The queued row being edited (spec 3x-composer §15.5, LiveChatSession+QueueEdit.swift): it doesn't
    /// send, nor do the rows behind it, until Save or Cancel.
    var queueEditingId: String?
    /// Typed steers go out one after another, in typing order (`steerTyped`).
    var typedSteerChain: Task<Void, Never>?
    /// ⌘Return: the next send queues behind a running reply instead of going into it (read once by `send`).
    var queuesNextSend = false
    var queuedMessages: [QueuedMessage] = [] {
        didSet { if queuedMessages != oldValue { stashQueue() } }
    }
    /// Stop parks the queue (it no longer drains by itself); Send Now, a send while idle or queueing a fresh message
    /// resumes it (the web: `enqueueQueuedPrompt` unparks, store/composer-queue.ts).
    private(set) var isQueueParked = false {
        didSet { if isQueueParked != oldValue { stashQueue() } }
    }

    /// Verify round 3: the queue this chat found waiting in the stash (at init, or on screen again), taken over before
    /// the first frame; it replaces what the chat held (the same items when it is the chat that left them there).
    func adoptStashedQueue(_ items: [QueuedMessage], parked: Bool) {
        guard queuedMessages != items || isQueueParked != parked else { return }
        queuedMessages = items
        isQueueParked = parked
        changes.markState()
    }

    /// A queued message's id: unique across runs too (a queue kept from an earlier run sits beside this chat's own).
    func nextQueuedId() -> String {
        localCounter += 1
        return "queued-\(localCounter)-\(UInt32.random(in: 0...UInt32.max))"
    }

    /// Side data for a message (row span, lifted attachment refs, notice flag, tool details).
    func meta(for messageId: String) -> MessageMeta? { metaById[messageId] }
    /// Step-sheet detail for one tool call.
    func toolDetail(messageId: String, toolId: String) -> ToolDetail? { metaById[messageId]?.tools[toolId] }
    /// Delivers pending changes now instead of at the next frame.
    func flushChanges() { ticker.isScheduled ? ticker.fire() : deliver() }

    // MARK: Dependencies

    let client: any GatewayClient
    let account: GatewayAccount
    let cache: TranscriptCache
    private let resolveSessionId: (() async throws -> String)?
    /// A chat this screen starts (`session.create` as it opens). The gateway writes its row only with the first prompt,
    /// so there is no history to read: an empty open is the bot's intro at once, never a skeleton that ends in
    /// "Couldn't load this chat."
    let startsNew: Bool
    private let lastActive: Date?
    var ticker: FrameTicker!

    // MARK: Tunables (tests shorten them)

    var silenceTimeout: Duration = .seconds(45)
    var activeListTimeout: Duration = .seconds(15)
    var resumeTimeout: Duration = .seconds(120)
    // [transcript] The status grace (§6.4) and the waking words (§6.5).
    /// The grace is the session's own setting (the app sets `StatusGrace.standard` in `AppModel.wire`); zero, the
    /// default, shows every status the moment its cause is set (what the session tests written before it expect).
    var statusGrace = StatusGrace(grace: .zero)
    var statusGraceDelay: Duration {
        get { statusGrace.grace }
        set { statusGrace.grace = newValue }
    }
    var statusRecheck: Task<Void, Never>?
    var resumeStartedAt: ContinuousClock.Instant?
    /// "Waking up…" becomes "Still waking up…" after this long.
    var stillWakingAfter: Duration = .seconds(20)
    /// [transcript] A problem with the chat itself (an `error` with no turn in flight, a resume that never came
    /// back): the card docked above the composer (docs/spec/3x-transcript.md §6.2, §6.5).
    var sessionProblem: SessionProblem? {
        didSet { if sessionProblem != oldValue { changes.markState(); scheduleFlush() } }
    }
    /// [transcript] How long each turn took (§6.6): remembered per chat, so a resync or a relaunch keeps the mark and
    /// another chat with the same message ids never gets it.
    var turnMarks: TurnMarkStore = .shared
    var turnMarksPending: Set<String> = []
    /// [transcript] The last read of earlier messages failed (§4.2): "Couldn’t load earlier messages", Try again.
    var olderFailed = false
    /// [transcript] A send the gateway refused or that never left: the "Couldn’t Send" card (§6.3).
    var sendFailure: SendFailure? {
        didSet { if sendFailure != oldValue { changes.markState(); scheduleFlush() } }
    }
    var interruptTimeout: Duration = .seconds(40)
    var submitTimeout: Duration = .seconds(1800)
    var busyRetryWindow: Duration = .seconds(6)
    var busyRetryInterval: Duration = .milliseconds(150)
    /// [owner-wait] The waiting card's ✕ was tapped for this send (the next send's wait shows it again).
    var ownerWaitCardDismissed = false
    /// A send refused because another Hermes process has this chat open: retried this often, for this long when the
    /// holder is a one-shot `hermes chat` run (cron jobs, background deliveries: they let go when their reply is done),
    /// for the short window when it is a window or terminal someone keeps open.
    var ownerRetryInterval: Duration = .seconds(2)
    var ownerWaitWindow: Duration = .seconds(1200)
    var ownerWaitShortWindow: Duration = .seconds(30)
    /// [locked-chat] How long a send waits out "busy" refusals whose hand-off to the gateway's queue was itself refused
    /// before the chat is called locked. A restart's drain refuses the same way for up to a minute, so not at once.
    var lockedAfter: Duration = .seconds(120)
    var stopHoldWindow: Duration = .seconds(6)
    var turnEndReadDelay: Duration = .milliseconds(1200)
    /// [foreign-prompt] How long after another device's turn starts its prompt is read (Hermes stores it as the turn
    /// starts; the pause lets the start's own `sessions.changed` land first).
    var foreignPromptReadDelay: Duration = .milliseconds(600)
    var staleHold: Duration = .milliseconds(300)
    var changedPassGap: Duration = .seconds(10)
    /// After `message.complete`, how long the queue waits for `session.info running:false` before draining anyway.
    var queueDrainFallback: Duration = .milliseconds(1500)
    /// Messages kept in memory when the screen goes away (03 §5.4 bounding; older ones page back in).
    var retainedMessagesOffScreen = 240

    // [activity] The chat's link to the app-wide ActivityStore (docs/spec/1x-activity.md §3): subagents, tasks, goal,
    // reasoning timing, provider waits. All its state lives in that object (LiveChatSession+Activity.swift).
    let activityLink = ActivityLink()

    // MARK: State

    var metaById: [String: MessageMeta] = [:] {
        didSet { mediaRevision &+= 1 }                    // [attachments] `mediaSnapshot` is rebuilt only after a change
    }
    var indexById: [String: Int] = [:]
    var changes = ChangeSet()
    var turn = TurnState()
    var aliases: [String: String] = [:]            // canonical stored id → displayed id
    var doubledReply = DoubledReplyWatch()          // [doubled-reply] diagnostic only
    var pendingDeltas: [(reasoning: Bool, text: String)] = []
    var silentTools: [String: (name: String, args: [String: JSONValue], argsText: String?)] = [:]
    var lastEmittedStatus: String?
    var localCounter = 0

    var started = false
    var observing = false
    /// Verify round 3: left with messages still queued behind a reply, the chat keeps listening off screen until they
    /// are out (LiveChatSession+Away.swift); the app model holds it meanwhile and opens it again instead of a new one.
    var drainingAway = false
    /// The chat began (true) or ended (false) draining its queue off screen.
    var onDrainingAwayChange: ((Bool) -> Void)?
    // [talk] A live voice conversation keeps the chat listening off screen the same way (LiveChatSession+Talk.swift).
    var voiceHold = false { didSet { if voiceHold != oldValue { voiceHoldChanged() } } }
    var onVoiceChange: (() -> Void)?
    /// The app's chats keep their queue beyond the screen (the stash, the off-screen drain); set by the app model with
    /// `keepQueue()` before the first frame. Off for chats made by tests and previews.
    private(set) var keepsQueue = false
    var canQueueWhileDisconnected: Bool { keepsQueue && !chatGone }

    private var defersSendUntilReady: Bool {
        guard canQueueWhileDisconnected else { return false }
        switch connection {
        case .connecting, .reconnecting, .offline: return true
        case .ready, .signedOut: return false
        }
    }

    private var canDrainQueue: Bool {
        guard case .ready = connection else { return false }
        return isLive && !parking && !chatGone
    }

    private var retryQueuedOpenAfterFlight = false

    /// Verify round 3: this chat's queue outlives its screen; one left behind in it shows (and drains) again.
    func keepQueue() {
        keepsQueue = true
        claimStashedQueue()
    }
    /// The engine runs (events, link, watchdog, queue): on screen, or draining away.
    var isLive: Bool { observing || drainingAway }
    var openSettled = false
    var openFinished = false              // open() returned (settled or failed)
    var parking = false
    var parked: [GatewayEvent] = []
    var resumeHeld: [GatewayEvent] = []   // frames for a runtime id a pending resume may bind (bounded)
    var activating = false                // a reconnect's `session.activate` is out: it may rebind too (held like a resume)
    var foreignReadTask: Task<Void, Never>?
    var retiredRuntimeId: String?         // discarded by `session.resume_progress failed`; its `error` frame still lands
    var stopEpoch = 0                     // bumped by Stop; a send started before it never goes out (04 §5)
    var reconnectGeneration = 0
    var refreshGeneration = 0
    var tailReadSerial = 0                // each tail read's start order (`refreshTail`)
    var tailReadApplied = 0               // the newest-started tail read applied so far
    var lastSeq: Int?
    var heldEpoch: String?
    var everReady = false
    var perfFeatures: PerformanceFeatures?
    var changeEvents = true
    /// [attachments] Pixel sizes known by gateway path (docs/spec/1x-attachments.md §7.8).
    var knownMediaSizes: [String: (Int, Int)] = [:]
    /// [attachments] reply pictures the gateway can't serve: path → the words their row shows.
    var unavailableMedia: [String: String] = [:]
    /// [attachments] reply pictures' sizes learnt by loading them: message id → picture key → size.
    var replyMediaSizes: [String: [String: MediaPixelSize]] = [:]
    var knownMediaBytes: [String: Int64] = [:]
    /// [attachments] Bumped by every `metaById` change; the row builder's media snapshot is cached against it.
    var mediaRevision = 0
    var mediaSnapshotCache: (revision: Int, snapshot: ChatMediaSnapshot)?
    /// [attachments] The attachment ids each send's pipeline is waiting on (by local bubble id): Stop wakes them.
    var inFlightAttachments: [String: [String]] = [:]

    // Paging bookkeeping (03 §5.1): offsets count backend rows from the newest end.
    var nextOffset = 0
    var oldestRowId: Int?
    var loadedRowIds = Set<Int>()
    /// Raw rows of the partial turn at the top of what is loaded (rows before the oldest loaded user/system row), so the
    /// next older page is folded together with them and a turn that crosses a page boundary reads as one reply.
    var headRows: [JSONValue] = []
    /// [smooth-open] The saved copy's messages at the top of the transcript that no read has confirmed yet. The open's
    /// first page (24 rows) often reaches less far back than the saved copy that was painted: those older messages stay
    /// on screen instead of leaving and coming back with the next read (owner 2026-11-10: opening a bot "takes a second
    /// to load, and it's not as smooth as it should be"). Paging counts none of them: the read of the rows above the
    /// page puts the gateway's own in their place (`prependOlder`).
    var cachedOlderIds = Set<String>()
    var cachedOlderCount: Int {
        cachedOlderIds.isEmpty ? 0 : messages.prefix(while: { cachedOlderIds.contains($0.id) }).count
    }
    var newestSignature: String?
    var lastSyncAt: Date?
    var lastSyncIds: [String] = []
    var lastTurnEndReadAt: Date?
    var lastChangedPassAt: Date?
    var resolvedStoredId: String?
    var pageSessionId: String?            // the REST page's `session_id` (the lineage tip, 03 §1)
    var chatGone = false

    var heldPaint: TranscriptEntry?
    /// The gateway's time of the newest stored row any history read of this chat returned (server seconds). The live
    /// rows of a turn sent here keep their local ids after the end-of-turn read, and a folded turn carries its first
    /// row's time, so the messages alone understate how far the reader has seen (verification round 3).
    var newestStoredAt: Double?
    /// [external-turn] Another Hermes process (the messaging gateway) runs a turn in this chat now
    /// (LiveChatSession+External.swift): Working… without a turn of ours.
    var externalWork: ExternalTurn.Source?
    /// [owner-wait] Times the external-turn watch saw another run end (wakes a send waiting for the chat).
    var externalEnds = 0
    var externalWorkTask: Task<Void, Never>?
    var externalGeneration = 0
    /// [external-turn] The chat began (true) or stopped (false) showing another process's turn as Working….
    var onExternalWorkChange: ((Bool) -> Void)?
    /// Left with a turn-end read owed: `onSeenAfterLeaving` reports what it saw.
    var seenOwedAfterLeave = false
    /// The open's history read failed (03 §4.7): it is read again (after 2, 5 and 10 s, and at once on each reconnect)
    /// until it lands. With nothing to show meanwhile the screen keeps its skeleton, never the empty-chat intro; when
    /// every try failed it shows the failure with Retry.
    var firstPageOwed = false
    var firstPageTries = 0
    var firstPageTask: Task<Void, Never>?
    static let firstPageRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
    var firstPageRetryDelays = LiveChatSession.firstPageRetryDelays

    // Tasks
    var openTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var connectionTask: Task<Void, Never>?
    var resumeFlight: Task<JSONValue, any Error>?
    /// The one `resolveSessionId` a chat just made runs: its open and a send made at once (New Tile) both wait on it.
    var storedIdFlight: Task<String, any Error>?
    var interruptTask: Task<Void, Never>?
    /// Stop was pressed again while an interrupt was still out (it can take 40 s): one more goes when that one answers.
    var interruptOwed = false
    var watchdogTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var refreshAgain = false
    var refreshAgainForce = false
    var queueDrainTask: Task<Void, Never>?
    var changedPassTask: Task<Void, Never>?
    var turnEndTask: Task<Void, Never>?
    var foreignPromptTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var olderTask: Task<Void, Never>?
    var stopTerminalWaiters: [CheckedContinuation<Void, Never>] = []
    /// VOICE: memo sends in flight by their optimistic bubble's id (LiveChatSession+Memo.swift).
    var memoSends: [String: MemoSendContext] = [:]
    /// [gpt-live] Sends a GPT-Live delegation made, by local id: the spoken exchange that rides `voice_context`.
    var voiceLiveSends: [String: String] = [:]
    /// [gpt-live] A delegation's `prompt.submit` was refused: the voice says it could not reach Hermes.
    var onVoiceLiveRefused: (() -> Void)?

    var cacheKey: TranscriptCache.Key? {
        storedSessionId.map { TranscriptCache.key(account: account.id, profile: profile, storedId: $0) }
    }

    /// The stored id REST and RPC reads use: the lineage tip once known (resume or page), else the requested id.
    var readSessionId: String? { resolvedStoredId ?? pageSessionId ?? storedSessionId }

    /// [diagnostics] "#stored rt #runtime" for log lines (tags only, never raw ids).
    var logIds: String { "\(AppLog.tag(storedSessionId)) rt \(AppLog.tag(runtimeSessionId))" }

    /// [diagnostics] An error for a log line: an RPC error's code and reason (its message can name ids), else redacted.
    nonisolated static func logError(_ error: Error) -> String {
        if let rpc = error as? RPCError {
            let reason = rpc.data?["reason"]?.string.map { " \($0)" } ?? ""
            let why = rpc.isNotConnected ? " never went out" : ""
            return "\(rpc.code)\(reason)\(why)\(rpc.isTimeout ? " timeout" : "")\(rpc.isConnectionLost ? " link lost" : "")"
        }
        if error is CancellationError { return "cancelled" }
        return AppLog.scrub(String(describing: error))
    }

    /// `profile` param for RPCs / REST (04 §1.4): always named, except a nameless (`custom`) launch home → "".
    var profileParam: String? { profile.isEmpty ? nil : profile }

    // MARK: Init (synchronous cached paint)

    init(client: any GatewayClient, account: GatewayAccount, profile: String, storedSessionId: String?, title: String,
         head: JSONValue?, cache: TranscriptCache, resolveSessionId: (() async throws -> String)?,
         lastActive: Date? = nil, startsNew: Bool = false, frameMode: FrameTicker.Mode = .displayLink) {
        self.client = client
        self.account = account
        self.profile = profile
        self.storedSessionId = storedSessionId
        self.title = title
        self.botName = title
        self.head = head
        self.cache = cache
        self.resolveSessionId = resolveSessionId
        self.startsNew = startsNew && storedSessionId == nil
        self.lastActive = lastActive
        self.ticker = nil
        self.ticker = FrameTicker(mode: frameMode) { [weak self] in self?.deliver() }
        if let ready = client.latestReady {
            heldEpoch = ready["replay_epoch"]?.string
            perfFeatures = PerformanceFeatures(ready: ready)
            changeEvents = ready["change_events"]?.bool ?? true
            everReady = true
        }
        paintFromCache()
    }

    /// [smooth-open] The chat is about to be shown: its first page is asked for now, and the open takes the read over
    /// (`HistoryFlights`) instead of asking once its screen has been pushed.
    func readAhead() {
        guard !started, !startsNew, let stored = storedSessionId, !stored.isEmpty else { return }
        let client = self.client, profile = self.profile
        HistoryFlights.shared.start(HistoryFlights.Key(account: account.id, profile: profile, storedId: stored),
                                    { HistoryFlights.openRead(client: client, storedId: stored, profile: profile) }) { _ in }
    }

    isolated deinit {
        AppLog.trace("chat", "chat released \(logIds): rows=\(messages.count), queued=\(queuedMessages.count), busy=\(turn.busy)")
        for task in [openTask, eventTask, connectionTask, interruptTask, watchdogTask, refreshTask, changedPassTask, turnEndTask,
                     reconnectTask, olderTask, queueDrainTask, firstPageTask] { task?.cancel() }
        ticker?.invalidate()
        stopTerminalWaiters.forEach { $0.resume() }
        releaseStashedQueue()
    }

    /// Paints the saved copy of the chat (03 §4.2), all of it and at once.
    ///
    /// [right-open] Owner 2026-11-11, with a recording: "A chat MUST load the correct messages IMMEDIATELY when opened."
    /// Two older rules are gone. Only the newest 24 rows' worth was painted, which for a chat ending in a long turn is
    /// that one reply alone: it drew as a bubble, then as a line of updates once its neighbours loaded. And a copy
    /// saved before the chat's last activity was held back for up to 300 ms, a blank screen meanwhile; now it shows,
    /// and what is new joins under it when the first page lands (`landFirstPage`).
    private func paintFromCache() {
        guard let stored = storedSessionId,
              let entry = cache.loadEntry(account: account.id, profile: profile, storedId: stored) else { return }
        let behind = lastActive.map { entry.savedAt.addingTimeInterval(1) < $0 } ?? false
        AppLog.trace("chat", "cache paint for \(AppLog.tag(stored)): \(entry.messages.count) cached rows\(behind ? ", saved before the chat's last activity" : "")")
        applyCachedPaint(entry)
    }

    func applyCachedPaint(_ entry: TranscriptEntry) {
        // Only backend truth is painted (03 §7.2); local cards never come back from the cache.
        // [presence] a titled request shows its title from the first paint (the cache may hold the stored prompt)
        let saved = entry.messages.filter { !$0.isLocal }
        let window = LiveChatSession.sentTitles.applied(to: saved)
        var meta: [String: MessageMeta] = [:]
        for m in window { if let mm = entry.meta[m.id] { meta[m.id] = mm } }
        let old = messages
        messages = TranscriptMerge.diff(old: old, new: window, into: &changes)
        metaById = meta
        applyKnownMediaSizes()                                                                                 // [attachments]
        rebuildIndex()
        cachedOlderIds = Set(window.map(\.id))            // [smooth-open] all of it is the saved copy until a read lands
        // Earlier messages are known only when the copy is a shortened one; else the first page says. "Show earlier
        // messages" flashed over a four-message chat until the gateway answered, and could page nothing in before
        // then anyway (`loadOlder` waits for the open) (Mac polish #24).
        hasOlder = entry.partial
        if !old.isEmpty || started { scheduleFlush() } else { changes = ChangeSet() }
    }

    // MARK: Lifecycle

    func start() {
        // Retry after an open that showed nothing (03 §4.7) — also while the error screen is still observing.
        let failedOpen = started && openFinished && messages.isEmpty && (openError != nil || chatGone)
        if observing && !failedOpen { return }
        AppLog.trace("chat", "screen on \(logIds) profile \(profile): started=\(started) settled=\(openSettled) failedOpen=\(failedOpen) away=\(drainingAway) rows=\(messages.count) busy=\(turn.busy)")
        var wasAway = false
        if !observing {
            observing = true
            seenOwedAfterLeave = false
            ticker.revive()
            // Verify round 3: a chat that kept draining its queue off screen is still listening.
            wasAway = drainingAway
            if wasAway { drainingAway = false }
            if eventTask == nil { subscribe() }
            claimStashedQueue()
            if !changes.isEmpty || wasAway {
                // Changes made while away (late reads, releasing old rows) reach a screen that re-read `messages`.
                changes = ChangeSet()
                changes.markReset()
                changes.markState()
                scheduleFlush()
            }
            if wasAway { onDrainingAwayChange?(false) }
        }
        if let key = cacheKey { cache.setVisible(key) }
        onObservingChange?(true)
        // [questions] Back on a settled chat a reconnect runs below; it replays the approvals once the runtime is confirmed.
        promptsObserving(true, replay: !(started && !failedOpen && openSettled && !firstPageOwed))
        if !started, opensOnFirstSend, storedSessionId == nil {
            AppLog.trace("chat", "open \(logIds): waits for the first message (a task's chat not made yet)")
            changes.markState(); scheduleFlush()
            return
        }
        if !started || failedOpen {
            beginOpen(failedOpen: failedOpen)
        } else if openSettled && firstPageOwed {
            AppLog.trace("chat", "reopen \(logIds): first page still owed, reading it now")
            retryFirstPageSoon(after: .zero)
        } else if openSettled {
            AppLog.trace("chat", "reopen \(logIds): catch up (joins running reconnect=\(joinsRunningReconnect()))")
            // Back on screen: catch up like a reconnect (rebind, replay or REST).
            // [offline] §6.5: a `gateway.ready` reconnect that began under 400 ms ago is this one (one tail read, not two).
            if !joinsRunningReconnect() {
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in await self?.reconnect(reason: "reopen") }
            }
            if turn.busy { armWatchdog() }
            // A chat that kept sending its queue off screen is the same chat again: its open settled long ago, so once
            // it has caught up it says so again, and the bot list counts it as on screen (seen, not unread).
            if wasAway {
                let catchUp = reconnectTask
                Task { [weak self] in
                    await catchUp?.value
                    guard let self, self.observing else { return }
                    AppLog.trace("chat", "reopen \(self.logIds): back from its off-screen drain, open settled again")
                    self.onOpenSettled?(true)
                }
            }
        }
    }

    private func beginOpen(failedOpen: Bool) {
        started = true
        openError = nil
        chatGone = false
        firstPageTask?.cancel(); firstPageTask = nil
        firstPageOwed = false
        firstPageTries = 0
        openSettled = false
        openFinished = false
        parking = true
        changes.markState(); scheduleFlush()
        AppLog.trace("chat", "open \(logIds): \(failedOpen ? "retry after a failed open" : "first open"), startsNew=\(startsNew)")
        openTask = Task { [weak self] in await self?.open() }
    }

    /// [tasks] A task's chat not made yet (`opensOnFirstSend`) is made by its first message, which waits for it (up to
    /// 4 s). (Starting to write had made it, so a letter typed and deleted left an empty chat on the task.)
    func openIfWaiting() {
        guard opensOnFirstSend, !started, isLive else { return }
        opensOnFirstSend = false
        madeOnWriting = true
        beginOpen(failedOpen: false)
    }

    func stopObserving() {
        guard observing else { return }
        observing = false
        flushDeltas()
        deliver()
        LeftChatProbe.chatLeft(self)     // [diagnostics] what the screen showed as it left
        changedPassTask?.cancel(); changedPassTask = nil
        tailRecheckStopped()             // [offline] §6.3
        endExternalWork("screen off")    // [external-turn]
        // Verify round 3: messages still queued behind the reply go out when it ends, screen or not (the web drains a
        // chat left in the background, app/session/hooks/use-background-queue-drain.ts): the chat keeps listening and
        // the app model holds it until its queue is out (LiveChatSession+Away.swift). [owner-wait] So does a send still
        // waiting for the chat's owner: it goes out off screen, and opening the chat again shows it waiting instead of
        // an empty field that invites a second copy.
        let waiting = (!queuedMessages.isEmpty && !isQueueParked) || turn.waitingForOwner != nil
        // VOICE: queued memos ride the queue like typed messages (drained off screen, or kept in the stash for the next
        // open); only a chat that keeps no queue hands them back as drafts (spec 1x-voice §4.4).
        if !keepsQueue { memoQueueLeaving() }
        // A /btw or /bg still out keeps the chat listening too: its result lands while away (SideTasks.swift).
        let sideOut = sideTasksOut()
        drainingAway = (keepsQueue && waiting) || voiceHold || sideOut   // [talk] voiceHold
        AppLog.trace("chat", "screen off \(logIds): rows=\(messages.count) busy=\(turn.busy) queued=\(queuedMessages.count) parked=\(isQueueParked) ownerWait=\(turn.waitingForOwner != nil) sideOut=\(sideOut) voice=\(voiceHold) → \(drainingAway ? "keeps listening off screen" : "stops listening")")
        if sideOut { armSideTaskLimit() }
        if !drainingAway { stopListening() }
        firstPageTask?.cancel(); firstPageTask = nil
        // A turn that ended on screen still has its end read owed (or in flight): what it reads was seen here.
        let endReadRunning = refreshTask != nil && (lastTurnEndReadAt.map { Date().timeIntervalSince($0) < 5 } ?? false)
        seenOwedAfterLeave = !turn.busy && (turnEndTask != nil || endReadRunning)
        if olderTask != nil {
            olderTask?.cancel(); olderTask = nil
            isLoadingOlder = false
        }
        // An open, a refresh or a turn-end read still in flight finishes and saves the cache; the invalidated ticker
        // keeps their completions from scheduling frames for a screen that is gone (a draining chat keeps its frames:
        // they report the turns it starts to the app model).
        if !drainingAway { ticker.invalidate() }
        releaseOlderHistory(keepingNewest: retainedMessagesOffScreen)
        if let key = cacheKey { cache.setVisible(key, visible: false) }
        saveCache()
        promptsObserving(false)  // [questions]
        if !drainingAway { releaseStashedQueue() }
        onObservingChange?(false)
        if drainingAway { onDrainingAwayChange?(true) }
    }

    /// The chat stops hearing the gateway (its screen left, or its off-screen drain ended).
    func stopListening() {
        if eventTask != nil { AppLog.trace("chat", "stop listening \(logIds)") }
        eventTask?.cancel(); eventTask = nil
        connectionTask?.cancel(); connectionTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        queueDrainTask?.cancel(); queueDrainTask = nil
    }

    private func subscribe() {
        let events = client.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
        let states = client.connectionStates()
        connectionTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.connectionChanged(state)
            }
        }
    }

    private func connectionChanged(_ state: ConnectionState) {
        guard state != connection else { return }
        AppLog.trace("chat", "connection \(logIds): \(connection) → \(state)")
        connection = state
        if case .ready = state {
            everReady = true
            if !openSettled, !queuedMessages.isEmpty, !isQueueParked, !chatGone, isLive {
                if openTask != nil {
                    retryQueuedOpenAfterFlight = true
                } else if opensOnFirstSend {
                    openIfWaiting()
                } else if openFinished {
                    beginOpen(failedOpen: true)
                }
            }
        }
        changes.markState()
        scheduleFlush()
    }

    // MARK: Open sequence (03 §4)

    private func open() async {
        defer {
            openFinished = true
            openTask = nil
            if retryQueuedOpenAfterFlight {
                retryQueuedOpenAfterFlight = false
                if !openSettled, !queuedMessages.isEmpty, !isQueueParked, canDrainQueue, !Task.isCancelled {
                    beginOpen(failedOpen: true)
                }
            }
        }
        let openStart = ContinuousClock.now
        guard let stored = await ensureStoredId() else {
            AppLog.note("chat", "open: no stored id for this chat (profile \(profile)); shows \"isn't available\"")
            parking = false
            parked = []
            openError = openError ?? "This chat isn't available right now."
            changes.markState(); scheduleFlush()
            return
        }
        let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        let features = perfFeatures
        let client = self.client
        // A chat just made has no stored rows yet: only the resume (to bind its runtime) runs.
        let fresh = startsNew && messages.isEmpty
        // A read a finger resting on the bot's row already began (03 §4.4) is taken over instead of asking again.
        var restTask = HistoryFlights.shared.take(HistoryFlights.Key(account: account.id, profile: profile, storedId: stored))
        AppLog.trace("history", "open \(AppLog.tag(stored)): first page \(fresh ? "skipped (new chat)" : restTask != nil ? "taken over from a press read" : "requested, limit 24"); resume started")
        if restTask == nil && !fresh {
            restTask = Task { try await HistoryAPI.fetchAndFold(client: client, request: request, features: features, cut: true) }
        }
        let resumeTask = Task { [weak self] () -> Result<JSONValue, any Error> in
            guard let self else { return .failure(CancellationError()) }
            do { return .success(try await self.resumeNow()) } catch { return .failure(error) }
        }
        if heldPaint != nil {
            let hold = staleHold
            Task { [weak self] in
                try? await Task.sleep(for: hold)
                self?.paintHeldIfNeeded()
            }
        }
        var restFailed = false
        var firstPage: HistoryPage?
        if let restTask {
            do {
                let (page, folded, _) = try await restTask.value
                AppLog.trace("history", "open \(AppLog.tag(stored)): first page \(page.rows.count) rows, page id \(AppLog.tag(page.sessionId)), truncated=\(page.possiblyTruncated), \(AppLog.ms(since: openStart)) ms")
                firstPage = await landFirstPage(page, folded)
            } catch {
                AppLog.note("history", "open \(AppLog.tag(stored)): first page failed after \(AppLog.ms(since: openStart)) ms: \(AppLog.scrub(String(describing: error)))")
                restFailed = !fresh
            }
        }
        paintHeldIfNeeded()
        let resumed = await resumeTask.value
        var snapshot: JSONValue?
        switch resumed {
        case .success(let value):
            snapshot = value
            AppLog.trace("chat", "open \(logIds): resumed, running=\(value["running"]?.bool ?? false), \(AppLog.ms(since: openStart)) ms")
        case .failure(let error):
            AppLog.note("chat", "open \(AppLog.tag(stored)): resume failed: \((error as? RPCError).map { "\($0.code)" } ?? AppLog.scrub(String(describing: error)))")
            if !fresh, let rpc = error as? RPCError, rpc.code == 4007, !rpc.message.localizedCaseInsensitiveContains("no longer live") {
                AppLog.note("chat", "open \(AppLog.tag(stored)): 4007, chat is gone from the gateway; cache dropped")
                chatGone = true
                cache.remove(account: account.id, profile: profile, storedId: stored)
            }
        }
        // A resume that resolved another stored id than the REST page did makes the REST paint untrusted (03 §3.1). The
        // REST route follows the compression chain too, so a page already at the tip needs no second read.
        if let resolved = resolvedStoredId, resolved != (pageSessionId ?? stored), !restFailed {
            AppLog.trace("history", "open: resume resolved \(AppLog.tag(resolved)) but page was \(AppLog.tag(pageSessionId ?? stored)); re-reading first page")
            do {
                let (page, folded, _) = try await HistoryAPI.fetchAndFold(client: client,
                    request: HistoryRequest(storedSessionId: resolved, profile: profileParam, limit: 24), features: features, cut: true)
                AppLog.trace("history", "open: re-read page for \(AppLog.tag(resolved)): \(page.rows.count) rows")
                applyFirstPage(page, folded)
            } catch {   // [diagnostics]
                AppLog.swallowed("history", "open: re-read of the resolved stored id's first page", error)
            }
        }
        if snapshot?["running"]?.bool == true, let page = firstPage, page.possiblyTruncated,
           !page.rows.contains(where: LiveChatSession.isTurnStart), let stored = readSessionId {
            // Opened in the middle of a turn longer than the first page: read back to its prompt first, so the running
            // turn's stored rows fold under it (not above a second copy of the prompt, verification round 2).
            let (extended, grew) = await extendBack(page, stored: stored, until: { $0.contains(where: LiveChatSession.isTurnStart) })
            AppLog.trace("history", "open mid-turn \(AppLog.tag(stored)): read back to the turn's prompt, \(page.rows.count) → \(extended.rows.count) rows, grew=\(grew)")
            if grew, !Task.isCancelled {
                applyFirstPage(extended, await LiveChatSession.foldOffMain(extended.rows, accountId: account.id), keepCached: true)
            }
        }
        graftInflight(snapshot)
        tailSettled(snapshot)            // [offline] §6.3: an open that settles on an unsaved reply rechecks it
        openSettled = true
        parking = false
        releaseParked()
        LeftChatProbe.chatOpened(self)   // [diagnostics] a reply the screen that left a moment ago never showed
        if messages.isEmpty && restFailed && (snapshot == nil || chatGone) {
            openError = chatGone ? "This chat is no longer on your gateway." : "Couldn't load this chat."
            AppLog.note("chat", "open \(AppLog.tag(stored)) failed, error screen shown (gone=\(chatGone))")
            changes.markState()
        } else if restFailed && !chatGone {
            AppLog.note("history", "open \(logIds): resume ok but first page failed; history owed, retrying (rows now \(messages.count))")
            // The REST read failing is non-fatal when the resume succeeded (03 §4.7), but the history is still owed: an
            // empty screen here is not an empty chat (verification round 3: a 30 s stall left a two-message chat on
            // "No messages yet").
            firstPageOwed = true
            firstPageTries = 0
            retryFirstPageSoon(after: firstPageRetryDelays.first ?? .seconds(2))
        }
        scheduleFlush()
        saveCache()
        AppLog.trace("chat", "open settled \(logIds): \(messages.count) rows, hasOlder=\(hasOlder), busy=\(turn.busy), parked frames released, queued=\(queuedMessages.count), \(AppLog.ms(since: openStart)) ms")
        if !restFailed { readOlderAfterOpen() }
        if !turn.busy { scheduleQueueDrain(after: .zero) }
        changes.markState()          // the open finished: the screen's skeleton (or its error) follows `openPhase`
        scheduleFlush()
        onOpenSettled?(!restFailed)
        checkExternalWork("open")                        // [external-turn]
    }

    private func paintHeldIfNeeded() {
        guard let held = heldPaint else { return }
        heldPaint = nil
        if messages.isEmpty { applyCachedPaint(held) } else { AppLog.trace("chat", "held cache paint dropped: \(messages.count) rows already shown") }
    }

    func ensureStoredId() async -> String? {
        if let storedSessionId { return storedSessionId }
        guard let resolveSessionId else { return nil }
        // One at a time (2026-11-03: New Tile opened and sent at once, each made a chat on the gateway; the turn ran
        // on one, the screen watched the other, and after 45 s of silence called it done with no tile).
        let flight: Task<String, any Error>
        if let running = storedIdFlight {
            flight = running
        } else {
            flight = Task { try await resolveSessionId() }
            storedIdFlight = flight
        }
        do {
            let id = try await flight.value
            if storedIdFlight == flight { storedIdFlight = nil }
            // The other waiter took it in already.
            if let storedSessionId { return storedSessionId }
            AppLog.trace("chat", "stored id resolved: \(AppLog.tag(id)) (profile \(profile))")
            let draftScopeBefore = layoutScope
            storedSessionId = id
            // [attachments] What was typed and attached before the id was known moves with the chat's draft
            // (docs/spec/1x-attachments.md A14): the screen and every hand-back follow the scope.
            AttachmentCenter.existing(account.id)?.moveDraft(from: draftScopeBefore, to: layoutScope)
            queueScopeResolved()   // verify round 3: the chat's kept queue
            onStoredIdResolved?(id)
            if let key = cacheKey { cache.setVisible(key) }
            if messages.isEmpty, let entry = cache.loadEntry(account: account.id, profile: profile, storedId: id) {
                applyCachedPaint(entry)
            }
            return id
        } catch {
            if storedIdFlight == flight { storedIdFlight = nil }
            AppLog.note("chat", "stored id could not be resolved (profile \(profile)): \(AppLog.scrub(String(describing: error)))")
            openError = (error as? RPCError)?.message ?? "This chat isn't available right now."
            return nil
        }
    }

    // MARK: Resume (03 §3.1.1: one canonical param set everywhere)

    func resumeParams(_ stored: String) -> JSONValue {
        var p: [String: JSONValue] = ["session_id": .string(stored), "cols": 96, "source": "desktop",
                                      "defer_history": true, "omit_messages": true]
        if let profileParam { p["profile"] = .string(profileParam) }
        return .object(p)
    }

    /// Single-flight `session.resume` of the stored id; binds the returned runtime id.
    @discardableResult
    func resumeNow() async throws -> JSONValue {
        if let flight = resumeFlight {
            let result = try await flight.value
            // [presence] The caller that began the resume binds the runtime it named (below), and the two waiters wake
            // in no promised order: a send that joined an open's resume woke first, found no runtime id and was
            // refused with "Couldn’t reach this chat." (a request put in the main bot's chat while the gateway was
            // away never went out). Wait for the bind: it is done when the flight is cleared.
            var turns = 0
            while resumeFlight == flight, turns < 400 {
                turns += 1
                if turns <= 50 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(5)) }
            }
            return result
        }
        guard let stored = await ensureStoredId() else { throw RPCError(code: 4007, message: "session not found", data: nil) }
        // Another caller began the resume while this one waited for the id: join it, not a second runtime.
        if resumeFlight != nil { return try await resumeNow() }
        let params = resumeParams(stored)
        let client = self.client
        let timeout = resumeTimeout
        let flight = Task { () async throws -> JSONValue in
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await client.call("session.resume", params, timeout: timeout)
                } catch let error as RPCError {
                    // 4007 "session no longer live": the stale record is gone, repeat once at once (04 §2.4.1).
                    if error.code == 4007, error.message.localizedCaseInsensitiveContains("no longer live"), attempt == 1 {
                        AppLog.trace("chat", "resume \(AppLog.tag(stored)): 4007 no longer live, repeating once")
                        continue
                    }
                    // No answer in time, the socket closed first, or it never went out: one quiet retry (03 §3.1).
                    if attempt == 1 && (error.isTimeout || error.isConnectionLost || error.isNotConnected) {
                        AppLog.trace("chat", "resume \(AppLog.tag(stored)): \(error.code) (timeout/link), one quiet retry")
                        continue
                    }
                    throw error
                } catch {
                    if attempt == 1 && !(error is CancellationError) {   // one quiet retry (03 §3.1)
                        AppLog.trace("chat", "resume \(AppLog.tag(stored)): failed, one quiet retry")
                        continue
                    }
                    throw error
                }
            }
        }
        resumeFlight = flight
        // [transcript] "Waking up…" while a cold bot starts (docs/spec/3x-transcript.md §6.5); "Still…" after 20 s.
        resumeStartedAt = .now
        scheduleFlush()
        let stillWaking = Task { [weak self] in
            try? await Task.sleep(for: (self?.stillWakingAfter ?? .seconds(20)) + .milliseconds(50))
            if !Task.isCancelled { self?.scheduleFlush() }
        }
        defer {
            resumeFlight = nil
            resumeHeld = []
            stillWaking.cancel()
            resumeStartedAt = nil
            scheduleFlush()
        }
        let result: JSONValue
        do {
            result = try await flight.value
        } catch let error as RPCError where error.code == 4064 {
            AppLog.note("chat", "resume \(AppLog.tag(stored)): 4064 profile gone, roster refetch")
            onRosterStale?()           // the profile is gone: refetch the roster, never retry (04 §1.4)
            throw error
        } catch {
            AppLog.note("chat", "resume \(AppLog.tag(stored)) failed: \((error as? RPCError).map { "\($0.code)" } ?? AppLog.scrub(String(describing: error)))")
            if let rpc = error as? RPCError, Self.isChatLocked(rpc) {
                sessionProblem = SessionProblem.chatLocked(detail: rpc.message)   // [locked-chat] no retry can open it
            }
            noteResumeFailed(error)    // [transcript] §6.5: both attempts failed → "Couldn’t reopen this chat"
            throw error
        }
        if sessionProblem?.reopen == true || sessionProblem?.primary == .newChat { sessionProblem = nil }   // [transcript] the chat came back
        bindRuntime(result)
        // Frames the new runtime emitted between the gateway's rebind and this answer (bounded hold, seq-deduped).
        let held = resumeHeld
        resumeHeld = []
        if !held.isEmpty {
            AppLog.trace("turn", "resume \(logIds): \(held.filter { $0.sessionId == runtimeSessionId }.count) of \(held.count) held frames are for the bound runtime, \(parking ? "parked" : "dispatched")")
        }
        for frame in held where heldFrameIsMine(frame) {
            if parking { parked.append(frame) } else { dispatch(frame) }
        }
        return result
    }

    /// [transcript] §6.5: a resume that got no answer in time on both attempts, or that the gateway refused because the
    /// chat is still starting, says so in the card above the composer. A lost link is the connection's own state
    /// ("Reconnecting…", "Offline"), a chat that is gone has its own screen, and a cancelled wait says nothing.
    func noteResumeFailed(_ error: Error) {
        guard let rpc = error as? RPCError, !chatGone, rpc.isTimeout else { return }
        // DECISION: every native resume is the web's "waking" resume (two minutes, one quiet retry), so the words
        // are the waking ones (`resumeWaking` in the web's runtime-error.ts).
        sessionProblem = SessionProblem.reopenFailed(starting: true)
    }

    /// [transcript] The card's "Try again": resume once more (its own quiet retry inside), then catch up.
    func retryAfterProblem() {
        let wasReopen = sessionProblem?.reopen == true
        AppLog.trace("chat", "try again \(logIds): reopen problem=\(wasReopen)")
        sessionProblem = nil
        Task { [weak self] in
            guard let self else { return }
            if wasReopen || self.runtimeSessionId == nil { _ = try? await self.resumeNow() }
            if self.openError != nil || self.messages.isEmpty { self.start() }
        }
    }

    // MARK: [transcript] Turn duration (§6.6)

    func noteTurnDuration(messageId: String, seconds: Double) {
        // Unknown is shown as nothing, never as a guess: a start time from another clock that gives nonsense is dropped.
        guard seconds.isFinite, seconds >= 0, seconds < 86_400, storedSessionId != nil else { return }
        turnMarks.set(seconds, scope: layoutScope, messageId: messageId)
        turnMarksPending.insert(messageId)
        turnMarksFollowAliases()
    }

    func turnMarksFollowAliases() {
        guard !turnMarksPending.isEmpty else { return }
        for (stored, displayed) in aliases where turnMarksPending.contains(displayed) {
            turnMarks.move(scope: layoutScope, from: displayed, to: stored)
            turnMarksPending.remove(displayed)
        }
    }

    /// The seconds the turn that ended in this message took, when this device saw it run.
    func turnSeconds(_ messageId: String) -> Double? {
        guard storedSessionId != nil else { return nil }
        return turnMarks.seconds(scope: layoutScope, messageId: messageId)
            ?? turnMarks.seconds(scope: layoutScope, messageId: canonicalId(messageId))
    }

    func dismissSessionProblem() { sessionProblem = nil }
    func dismissSendFailure() { sendFailure = nil }

    /// [owner-wait] The waiting card shows while a send waits for another Hermes process; its ✕ hides it (the wait and
    /// the status line stay), Cancel Message takes the message back like Stop.
    var ownerWaitNotice: OwnerWait? { ownerWaitCardDismissed ? nil : turn.waitingForOwner }
    var ownerWaitKind: OwnerWait? { turn.waitingForOwner }
    func dismissOwnerWait() {
        guard !ownerWaitCardDismissed else { return }
        ownerWaitCardDismissed = true
        changes.markState()
        scheduleFlush()
    }
    func cancelOwnerWait() {
        guard turn.waitingForOwner != nil else { return }
        stop()
    }

    func bindRuntime(_ result: JSONValue) {
        guard let rid = result["session_id"]?.nonEmptyString else { return }
        let old = runtimeSessionId
        AppLog.trace("chat", "bind \(AppLog.tag(storedSessionId)): runtime \(AppLog.tag(old)) → \(AppLog.tag(rid))\(rid == old ? " (same)" : ", seq reset"), resolved \(AppLog.tag(result["session_key"]?.nonEmptyString ?? result["resumed"]?.nonEmptyString))")
        if rid != old { lastSeq = nil }
        runtimeSessionId = rid
        if old != rid { onRuntimeBound?(old, rid) }
        retiredRuntimeId = nil
        if let resolved = result["session_key"]?.nonEmptyString ?? result["resumed"]?.nonEmptyString { resolvedStoredId = resolved }
        promptRuntimeBound(rid)  // [questions]
        applyModelInfo(result["info"])          // MENUS (spec 1x §2.1 rule 1)
        activityBound(result)        // [activity] bind the runtime id in the ActivityStore, apply `todo_state`
        mirrorReactionsSwitch()      // Message Reactions: the bot learns the switch once it has been used
    }

    // MARK: Send (04 §2)

    func send(_ text: String) { send(text, display: nil, attachments: []) }

    /// [tasks] Set by a task's page: what a typed send carries and shows instead (nil: as typed).
    var wrapsSend: ((String) -> (text: String, display: String)?)?
    /// [tasks] Opening the screen makes no session: the first message does (`openIfWaiting`).
    var opensOnFirstSend = false
    /// [tasks] A chat not made yet keeps its draft under this (a task's id) rather than under its bot alone: every
    /// task's unmade chat with one bot had shared one draft and one set of attachments.
    var pendingScope: String?
    /// [tasks] The waiting open began: a send meanwhile waits for it.
    private var madeOnWriting = false
    /// [tasks] Sends made before the chat opened, waiting for it one behind the other (so they go out in typing order).
    private var preOpenSends: Task<Void, Never>?
    private var preOpenWaiting = 0

    /// [attachments] `send` with photos and files (docs/spec/1x-attachments.md §6.4): queued with them while a reply runs.
    func send(_ text: String, attachments: [DraftAttachment]) { send(text, display: nil, attachments: attachments) }

    /// MENUS (spec 1x §8.3): `display` is what the bubble shows (a skill's invocation); `text` is what `prompt.submit`
    /// carries. [attachments] with photos and files.
    func send(_ text: String, display: String?, attachments: [DraftAttachment] = []) {
        // [tasks] A task's chat: typed words go out with what the task adds (its details, the first time); the bubble
        // shows what the task says it shows.
        if display == nil, let wrap = wrapsSend, let wrapped = wrap(text) {
            send(wrapped.text, display: wrapped.display, attachments: attachments)
            return
        }
        if defersSendUntilReady && preOpenWaiting == 0 {
            sendAfterOpen(text, display: display, attachments: attachments)
            return
        }
        if opensOnFirstSend || (madeOnWriting && !openSettled && !openFinished) || preOpenWaiting > 0 {
            openIfWaiting()
            let deadline = ContinuousClock.now + .seconds(4)
            let previous = preOpenSends
            preOpenWaiting += 1
            preOpenSends = Task { [weak self] in
                await previous?.value   // an earlier message waiting too goes first
                while let self, ContinuousClock.now < deadline, !(self.openSettled || self.openFinished) {
                    self.openIfWaiting()   // a send made before the screen showed: the open begins as it does
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let self else { return }
                self.preOpenWaiting -= 1
                self.sendAfterOpen(text, display: display, attachments: attachments)
            }
            return
        }
        sendAfterOpen(text, display: display, attachments: attachments)
    }

    private func sendAfterOpen(_ text: String, display: String?, attachments: [DraftAttachment]) {
        let toQueue = queuesNextSend
        queuesNextSend = false
        guard !ChatText.trimmed(text).isEmpty || !attachments.isEmpty else { return }
        // [presence] A titled request whose title came back to the field (a refused send, or its queue row taken out to
        // edit) and is sent again goes out as the request it stands for, in the main bot's chat only.
        if display == nil, attachments.isEmpty, profile == "default",
           let prompt = LiveChatSession.sentTitles.prompt(forTitle: text) {
            send(prompt, display: ChatText.trimmed(text), attachments: [])
            return
        }
        // [transcript] §6.2, §6.3: a new send answers the card about the last one, and the chat's problem card.
        sendFailure = nil
        sessionProblem = nil
        flushDeltas()
        // Desktop parity (owner 2026-10-28): plain text typed while a reply runs goes into that reply, and leaves a
        // paused queue paused (only a queued message un-pauses it, as on the desktop). A queued send (⌘Return, Send ›
        // Queue, or Settings › Chat › Send While Replying set to Queue) waits instead.
        let defersForLink = defersSendUntilReady
        if !toQueue, !defersForLink, steersTyped(text, display: display, attachments: attachments) {
            steerTyped(text)
            return
        }
        // Verify round 3: a fresh message is fresh intent to keep the conversation moving, so a park left by an earlier
        // Stop (or refusal) never holds it, or the messages queued ahead of it, back (the web's `enqueueQueuedPrompt`
        // unparks). Sent while idle it goes first; the parked ones follow its reply.
        let waitInLine = defersForLink || turn.busy || (!queuedMessages.isEmpty && !isQueueParked)
        unparkQueue()
        if waitInLine {
            // Wait in the FIFO for the connection, the current reply or the messages already ahead of this one.
            let qid = nextQueuedId()
            AppLog.trace("send", "queued \(AppLog.tag(qid)) in \(logIds): busy=\(turn.busy), \(queuedMessages.count) ahead, attachments=\(attachments.count)")
            queuedMessages.append(QueuedMessage(id: qid, text: text, attachments: attachments, display: display))
            changes.markState()
            scheduleFlush()
            if !turn.busy { drainQueueHead() }
            return
        }
        let retryItem = canQueueWhileDisconnected && attachments.isEmpty
            ? QueuedMessage(id: nextQueuedId(), text: text, display: display) : nil
        beginSend(text, display: display, queued: false, attachments: attachments, retryItem: retryItem)
    }

    /// The optimistic bubble, busy at once, then `prompt.submit` (with `queued:true` for queue drains).
    /// VOICE: `memo` stages the memo first (LiveChatSession+Memo.swift); its watchdog arms when `prompt.submit` goes out.
    func beginSend(_ text: String, display: String? = nil, queued: Bool, attachments: [DraftAttachment] = [],
                   memo: MemoSendContext? = nil, interrupted: Bool = false, voiceContext: String? = nil,
                   retryItem: QueuedMessage? = nil) {   // [talk] interrupted
        openIfWaiting()   // [tasks] a memo as a task's first message makes its chat as it stages
        sealLeftoverLiveMessage()
        localCounter += 1
        let localId = "local-user-" + (retryItem?.id ?? "\(localCounter)-\(UInt32.random(in: 0...UInt32.max))")
        AppLog.trace("send", "send \(AppLog.tag(localId)) in \(logIds): queued=\(queued), attachments=\(attachments.count), memo=\(memo != nil), voice=\(voiceContext != nil), interrupted=\(interrupted), waits for stop=\(turn.stopTerminalPending), \(memo.map(Self.memoLogWords) ?? "\(text.count) chars")")
        if let voiceContext { voiceLiveSends[localId] = voiceContext }   // [gpt-live]
        let typed = display ?? text                                                                     // MENUS
        let shown = attachments.isEmpty ? typed : AttachmentSender.bubbleText(typed: typed, attachments: attachments)  // [attachments]
        var bubble = ChatMessage(id: localId, role: .user, parts: [.text(shown)], timestamp: Date(), rowId: nil)
        bubble.isPending = true
        appendMessage(bubble)
        if !attachments.isEmpty { noteLocalAttachments(localId, attachments) }                              // [attachments]
        let holdForStop = turn.stopTerminalPending
        turn.busy = true
        turn.awaitingResponse = true
        turn.sawAssistantPayload = false
        turn.turnLive = false
        if holdForStop {
            // The stopped turn is still unwinding: its late frames keep being treated as stopped until this goes out.
            turn.submitHeld = true
            turn.sentPastStop = false
        } else {
            turn.interrupted = false
            turn.stopPending = false
            turn.stopRetried = false
        }
        turn.streamId = nil
        turn.openPart = nil
        turn.heartbeatSettledStreamId = nil
        turn.userAnchorId = localId
        turn.anchorPromptKey = Hydration.userDisplayKey(text)                                           // MENUS: not `display`
        turn.idleConfirmed = false
        turn.armedAt = Date()
        turn.turnStartedAt = turn.turnStartedAt ?? Date()
        turn.preparingSendId = attachments.isEmpty ? nil : localId                                         // [attachments]
        if let memo { memoSends[localId] = memo } else { armWatchdog() }   // VOICE
        changes.markState()
        scheduleFlush()
        let epoch = stopEpoch
        if memo != nil {
            // VOICE: held strongly until prompt.submit answers (a chat left mid-send finishes into its own chat); Stop
            // cancels the task while it stages.
            memoSends[localId]?.task = Task { await self.runMemoSend(localId: localId, queued: queued, holdForStop: holdForStop, epoch: epoch) }
            return
        }
        Task { [weak self] in
            await self?.submit(text, draft: display ?? text, localId: localId, queued: queued, holdForStop: holdForStop, epoch: epoch,
                               attachments: attachments, interrupted: interrupted, retryItem: retryItem)   // [talk] interrupted
        }
    }

    /// `draft`: what a refused or withdrawn send hands back to the composer (MENUS: a skill's invocation, not its body;
    /// nil = `text`). VOICE: internal.
    func submit(_ text: String, draft: String? = nil, localId: String, queued: Bool, holdForStop: Bool, epoch: Int,
                attachments: [DraftAttachment] = [], interrupted: Bool = false,
                retryItem: QueuedMessage? = nil) async {   // [talk] interrupted
        let draft = draft ?? text
        // A send turned down. One that Stop overtook never went out either: its words come back as stopped, with no
        // "Couldn’t Send" card, no park and no settle (by then the chat may be running the next message's turn).
        func refuse(_ reason: String) {
            if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return }
            refuseSend(localId: localId, text: draft, reason: reason, queued: queued, attachments: attachments)
        }
        // [attachments] the send keeps running while the app is in the background (docs/spec/1x-attachments.md §6.6)
        let background = attachments.isEmpty ? nil : AttachmentPipeline.beginBackground()
        defer { AttachmentPipeline.endBackground(background) }
        var useQueued = queued
        let sendStart = ContinuousClock.now
        let lid = AppLog.tag(localId)
        if holdForStop && turn.stopTerminalPending {
            // The stopped turn is still unwinding: wait for its terminal frame (≤ 6 s), else queue behind it (04 §5.4).
            let settled = await waitForStopTerminal(stopHoldWindow)
            AppLog.trace("send", "send \(lid): stop hold \(settled ? "ended on the terminal frame" : "timed out, goes queued=\(!interrupted)")")
            if !settled {
                // [talk] Words spoken over the reply never wait behind it: unqueued, the gateway's busy mode
                // (interrupt) takes them.
                useQueued = !interrupted
                turn.stopTerminalPending = false      // don't make the next send wait the whole hold again
                // Queued, it only runs after the stopped turn, which is still unwinding: it stays held, so that turn's
                // late text and its `message.complete` are never drawn as this message's reply (its end lets go).
                if useQueued && stopEpoch == epoch && turn.submitHeld { turn.sentPastStop = true }
            }
            turn.followsStopAt = Date()
        }
        if holdForStop && stopEpoch == epoch && !turn.sentPastStop {
            turn.submitHeld = false
            turn.interrupted = false
            turn.stopPending = false
            turn.stopRetried = false
        }
        if runtimeSessionId == nil {
            AppLog.trace("send", "send \(lid): no runtime bound, resuming \(AppLog.tag(storedSessionId)) first")
            do { try await resumeNow() } catch {
                AppLog.note("send", "send \(lid): resume before send failed: \(Self.logError(error))")
                if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return }
                if let retryItem, defersSendUntilReady || (error as? RPCError).map(Self.linkAwayForNow) == true,
                   requeueUnsent(retryItem, localId: localId, epoch: epoch) { return }
                refuse((error as? RPCError)?.message ?? "Couldn’t reach this chat.")
                return
            }
        }
        // Stop pressed while this send was still waiting (stop hold, pre-send resume): it never goes out.
        if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return }
        // [attachments] uploads, then image.attach / file.attach in tray order (docs/spec/1x-attachments.md §6.4 steps 3–5)
        var promptText = text
        var attached = AttachedSend()
        if !attachments.isEmpty {
            switch await attachForSend(attachments, localId: localId, epoch: epoch) {
            case .ready(let sent):
                attached = sent
                promptText = AttachmentSender.promptText(typed: text, fileRefs: sent.fileRefs, hasImages: !sent.photos.isEmpty)
            case .refused(let reason):
                AppLog.note("send", "send \(lid): attachments refused, send handed back")
                refuse(reason)
                return
            case .stopped:
                withdrawStoppedSend(localId: localId, text: draft, attachments: attachments)
                return
            }
            AppLog.trace("send", "send \(lid): attachments ready (\(attached.photos.count) photos, \(attached.fileRefs.count) files)")
        }
        // What goes out (with its files' refs) is what a resume snapshot names as the running turn's prompt.
        if turn.userAnchorId == localId { turn.anchorPromptKey = Hydration.userDisplayKey(promptText) }
        endPreparing(localId)                                                                              // [attachments]
        var resumedOnce = false
        let busyDeadline = ContinuousClock.now + busyRetryWindow
        var firstError: RPCError?
        var ownerDeadline: ContinuousClock.Instant?
        var ownerTries = 0
        var linkAwayNoted = false   // [diagnostics] the wait outliving a paused link is logged once
        var handOffRefusedSince: ContinuousClock.Instant?   // [locked-chat] first "busy" whose hand-off was refused
        ownerWaitCardDismissed = false
        // The wait for another process's run ends (sent, refused, or Stopped): the turn's clocks start from here. After
        // a Stop with a newer send in hand, the wait flag is that send's now and stays.
        func endOwnerWait() {
            guard ownerDeadline != nil else { return }
            ownerDeadline = nil
            if stopEpoch == epoch || turn.userAnchorId == localId { turn.waitingForOwner = nil }
            endPreparing(localId)
            changes.markState()
            scheduleFlush()
        }
        var attempt = 0
        while true {
            attempt += 1
            if ownerDeadline != nil, runtimeSessionId == nil {
                // Reclaimed while waiting: the send hasn't gone out, so resume again rather than give up.
                AppLog.trace("send", "send \(lid): runtime reclaimed while waiting for the owner, resuming again")
                do { try await resumeNow() } catch { AppLog.swallowed("send", "send \(lid): resume while waiting for the owner", error) }   // [diagnostics]
            }
            guard let rid = runtimeSessionId else {
                AppLog.note("send", "send \(lid): no runtime to send to, refused \"Couldn’t reach this chat.\"")
                endOwnerWait()
                refuse("Couldn’t reach this chat.")
                return
            }
            var params: [String: JSONValue] = ["session_id": .string(rid), "text": .string(promptText),
                                               "submission_id": AuthorityWire.submissionId(for: localId)]   // [authority]
            if let profileParam { params["profile"] = .string(profileParam) }
            if useQueued { params["queued"] = true }
            if interrupted { params["interrupted"] = true }   // [talk] the person cut the last reply off (3x-talk §3.6)
            if let context = voiceLiveSends[localId] {
                // [gpt-live] a delegation: the gateway puts the spoken exchange in the model input only (3x-gpt-live §3.4)
                params["surface"] = "voice-live"
                if !context.isEmpty { params["voice_context"] = .string(String(context.suffix(LiveVoiceWire.voiceContextLimit))) }
            }
            // MENUS: a rewind's send (Regenerate, Edit, Rewind to Here) truncates before its stored turn.
            if let rewind = rewindParams(for: localId) { params.merge(rewind) { _, new in new } }
            do {
                let result = try await client.call("prompt.submit", .object(params), timeout: submitTimeout)
                AppLog.trace("send", "send \(lid) accepted on rt \(AppLog.tag(rid)): status \(result["status"]?.string ?? "-"), user row \(result["user_row_id"]?.positiveInt.map(String.init) ?? "-"), try \(attempt), queued=\(useQueued), \(AppLog.ms(since: sendStart)) ms")
                endOwnerWait()
                acknowledge(localId: localId, result: result, epoch: epoch)
                if !attachments.isEmpty { finishAttachmentSend(attached, attachments: attachments, localId: localId) }  // [attachments]
                return
            } catch let error as RPCError {
                AppLog.trace("send", "send \(lid) try \(attempt) refused on rt \(AppLog.tag(rid)): \(Self.logError(error)), waiting for owner=\(ownerDeadline != nil), \(AppLog.ms(since: sendStart)) ms")
                // [owner-wait] A try that never left the phone while the send waits for the chat's owner (the app went
                // to the background, the network dropped): the wait goes on, and the send goes out once the link is
                // back and the chat is free. Owner, 2026-10-23: the job let go 16 s after the app was put away, and the
                // waiting message was handed back instead of sent.
                if let deadline = ownerDeadline, ContinuousClock.now < deadline, Self.linkAwayForNow(error) {
                    if !linkAwayNoted {
                        linkAwayNoted = true
                        AppLog.note("chat", "send keeps waiting for the chat's owner while the link is away (\(error.notSentBecause?.code ?? "?"))")
                    }
                    try? await Task.sleep(for: ownerRetryInterval)
                    if stopEpoch != epoch {
                        endOwnerWait()
                        await detachPhotos(attached)                                                          // [attachments]
                        withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return
                    }
                    continue
                }
                if let retryItem, ownerDeadline == nil, Self.linkAwayForNow(error),
                   requeueUnsent(retryItem, localId: localId, epoch: epoch) { return }
                // The request may have reached the gateway (no answer in time, or the socket closed before it
                // answered): never resent and never handed back for a resend — "Delivery unconfirmed" (04 §2.5). On
                // Hermes the turn runs anyway. One that never went out (`isNotConnected`) is safe to refuse below.
                if !Self.waitsForOwner(error) { endOwnerWait() }
                if error.isTimeout || error.isConnectionLost {
                    AppLog.note("send", "send \(lid): \(error.isTimeout ? "no answer in time" : "link lost") after it may have gone out → Delivery unconfirmed, never resent")
                    // [attachments] The attaches were done: the photos are on the gateway whether or not the prompt
                    // landed, so the phone copies go and the bubble points at the gateway paths either way.
                    if !attachments.isEmpty { finishAttachmentSend(attached, attachments: attachments, localId: localId) }
                    markUnconfirmed(localId: localId, queued: queued, epoch: epoch)
                    return
                }
                // [locked-chat] Owner 2026-11-05: a chat Hermes won't open any more (its record names the bot's old
                // folder: `profile_mismatch`) answered every send "busy", because the gateway's queue held work that
                // can never run, and the message waited for a reply that would never end. Refused at once when the
                // gateway names the lock, after `lockedAfter` when only the queue's hand-off keeps being refused.
                if Self.isChatLocked(error) {
                    handOffRefusedSince = handOffRefusedSince ?? .now
                } else {
                    handOffRefusedSince = nil
                }
                if Self.isChatLocked(error),
                   error.code != 4090 || ContinuousClock.now - (handOffRefusedSince ?? .now) >= lockedAfter {
                    AppLog.note("send", "send \(lid): the chat is locked on the gateway (\(Self.logError(error))) → refused, Continue in New Chat")
                    endOwnerWait()
                    await detachPhotos(attached)                                                              // [attachments]
                    refuse(error.message)
                    sendFailure = nil   // one card: the problem card names the way on
                    sessionProblem = SessionProblem.chatLocked(detail: error.message)
                    return
                }
                switch error.code {
                case 4090 where Self.isOwnerUnconfirmed(error):
                    AppLog.note("send", "send \(lid): owner unconfirmed (gateway queue may hold it) → Delivery unconfirmed")
                    // The gateway's queue may already hold it: never resent, the bubble's Check reads the chat (§2.5).
                    if !attachments.isEmpty { finishAttachmentSend(attached, attachments: attachments, localId: localId) }  // [attachments]
                    markUnconfirmed(localId: localId, queued: queued, epoch: epoch)
                    return
                case 4090 where Self.isOwnerBusy(error) && !attached.photos.isEmpty:
                    // Photos can't wait in the gateway's queue (it unstages them with this refusal, so a later try would
                    // go without them): they go back to the tray with the words.
                    AppLog.note("send", "send \(lid): owner busy with \(attached.photos.count) photos staged → handed back (photos can't wait)")
                    endOwnerWait()
                    await detachPhotos(attached)                                                              // [attachments]
                    refuse(error.message)
                    return
                case 4090 where Self.waitsForOwner(error):
                    if ownerDeadline == nil {
                        let kind = Self.ownerWait(error)
                        AppLog.note("chat", "send waits for the chat's owner: \(AppLog.scrub(error.message))")
                        ownerDeadline = ContinuousClock.now + (kind == .otherWindow ? ownerWaitShortWindow : ownerWaitWindow)
                        turn.waitingForOwner = kind
                        turn.preparingSendId = localId   // not on the gateway yet: no watchdog, no running:false settle
                        changes.markState()
                        scheduleFlush()
                        checkExternalWork("send waits for the owner")   // [external-turn] its steps show meanwhile
                    }
                    if let deadline = ownerDeadline, ContinuousClock.now < deadline {
                        ownerTries += 1
                        let pause = ownerPause(ownerTries)
                        AppLog.trace("send", "send \(lid): still owned (\(Self.ownerWait(error).logWord)), retry \(attempt) in \(pause) or when the other run ends")
                        // The chat answered on the runtime in hand: a later reap (a long time in the background) may
                        // resume once more.
                        resumedOnce = false
                        firstError = nil
                        await waitForOwner(pause, epoch: epoch)
                        if stopEpoch != epoch {
                            endOwnerWait()
                            await detachPhotos(attached)                                                      // [attachments]
                            withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return
                        }
                        continue
                    }
                    endOwnerWait()
                    AppLog.note("chat", "send refused, the chat is still owned: \(AppLog.scrub(error.message))")
                    await detachPhotos(attached)                                                              // [attachments]
                    refuse(error.message)
                    probeTailSoon()     // [owner-wait] what the holder saved during the wait (its changes weren't all read)
                    return
                case 4009:
                    AppLog.trace("send", "send \(lid): 4009 busy, \(ContinuousClock.now < busyDeadline ? "retrying" : "busy window over, refused")")
                    if ContinuousClock.now < busyDeadline {
                        try? await Task.sleep(for: busyRetryInterval)
                        if stopEpoch != epoch {
                            await detachPhotos(attached)                                                      // [attachments]
                            withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return
                        }
                        continue
                    }
                    await detachPhotos(attached)                                                              // [attachments]
                    refuse(error.message)
                    return
                case 4001, 4007:
                    // 4001 and `4007 session no longer live` are pre-admission refusals: resume once, resubmit once.
                    if error.code == 4007 && !error.message.localizedCaseInsensitiveContains("no longer live") {
                        AppLog.note("send", "send \(lid): 4007 session not found, refused")
                        refuse(error.message)
                        return
                    }
                    if resumedOnce {
                        AppLog.note("send", "send \(lid): \(error.code) again after one resume, refused")
                        refuse((firstError ?? error).message)
                        return
                    }
                    resumedOnce = true
                    firstError = error
                    AppLog.trace("send", "send \(lid): \(error.code) pre-admission, dropping rt \(AppLog.tag(runtimeSessionId)), resume once and resubmit")
                    runtimeSessionId = nil
                    do { try await resumeNow() } catch {
                        AppLog.note("send", "send \(lid): resume inside \(firstError?.code ?? 0) recovery failed: \(Self.logError(error))")
                        if let retryItem, defersSendUntilReady || (error as? RPCError).map(Self.linkAwayForNow) == true,
                           requeueUnsent(retryItem, localId: localId, epoch: epoch) { return }
                        // Inside 4001 recovery, report the original error (04 §2.4.1).
                        refuse(firstError?.message ?? "Couldn’t reach this chat.")
                        return
                    }
                    if stopEpoch != epoch { withdrawStoppedSend(localId: localId, text: draft, attachments: attachments); return }
                    // [attachments] the photos were queued on the dead runtime: attach them to the new one (A5).
                    if !attached.photos.isEmpty, let reason = await reattachPhotos(&attached) {
                        refuse(reason)
                        return
                    }
                    continue
                default:
                    AppLog.note("send", "send \(lid): refused \(Self.logError(error)) after \(attempt) tries")
                    if error.code == 4064 { onRosterStale?() }
                    await detachPhotos(attached)                                                              // [attachments]
                    refuse(error.message)
                    return
                }
            } catch {
                AppLog.note("send", "send \(lid): \(Self.logError(error)) after it may have gone out → Delivery unconfirmed")
                endOwnerWait()
                // Timeout or transport loss after the request may have gone out: never auto-resend (04 §2.5).
                if !attachments.isEmpty { finishAttachmentSend(attached, attachments: attachments, localId: localId) }  // [attachments]
                markUnconfirmed(localId: localId, queued: queued, epoch: epoch)
                return
            }
        }
    }

    private func acknowledge(localId: String, result: JSONValue, epoch: Int) {
        _ = memoSendFinished(localId, .acknowledged)   // VOICE
        voiceLiveSends[localId] = nil   // [gpt-live]
        rewindAcknowledged(localId: localId, result: result)   // MENUS: the kept rows' new ids
        updateMessage(localId) { m in
            m.isPending = false
            if let row = result["user_row_id"]?.positiveInt { m.rowId = row }
        }
        // Sent past the stop hold but not held in the gateway's queue: it runs now, so the stopped turn is over.
        if result["status"]?.string != "queued", turn.userAnchorId == localId { releaseSendPastStop("its send was accepted to run now") }
        if result["forwarded"]?.bool == true {                                                                   // [desktop-forward]
            turn.forwarded = true
            AppLog.note("send", "send \(AppLog.tag(localId)) went to the gateway's queue (admission \(AppLog.tag(result["admission_id"]?.string))): its turn runs there")
        }
        scheduleFlush()
        // Stop was pressed while this prompt was on its way: the first interrupt may have reached the gateway before the
        // turn was admitted. Interrupt the now-running turn once more.
        if stopEpoch != epoch, result["status"]?.string != "queued" {
            AppLog.trace("send", "send \(AppLog.tag(localId)) accepted after Stop: interrupting the new turn again")
            interruptAgain()
        }
    }

    /// A send overtaken by Stop before it went out: its bubble (and the Stopped marker for it) go, the text returns.
    func withdrawStoppedSend(localId: String, text: String, attachments: [DraftAttachment] = []) {   // VOICE: internal
        AppLog.trace("send", "send \(AppLog.tag(localId)) withdrawn: Stop came before it went out; text back to the field")
        let text = memoSendFinished(localId, .withdrawn) ?? text   // VOICE: a memo's typed words; the memo → draft chip
        voiceLiveSends[localId] = nil   // [gpt-live]
        // A newer send owns the turn (sent after the Stop): its bubble, hold and flags stay as they are.
        let ownsTurn = turn.userAnchorId == nil || turn.userAnchorId == localId
        if let index = indexById[localId], index + 1 < messages.count {
            let next = messages[index + 1]
            if next.id.hasPrefix("local-stopped-") { removeMessage(next.id) }
        }
        removeMessage(localId)
        if turn.userAnchorId == localId { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        if turn.stoppedAnchorId == localId { turn.stoppedAnchorId = nil }
        if turn.preparingSendId == localId { turn.preparingSendId = nil }                                  // [attachments]
        if ownsTurn { turn.submitHeld = false; turn.sentPastStop = false }
        // MENUS: an Edit, Regenerate or Rewind took the later messages off before sending; the gateway never cut them,
        // so they come back (as a refused rewind's do). A send made after it reads the chat whole instead.
        if rewindWithdrawn(localId: localId, restore: ownsTurn) {
            changes.markState()
            scheduleFlush()
            return
        }
        changes.markState()
        scheduleFlush()
        if !attachments.isEmpty { returnAttachments(attachments, text: text) }                                 // [attachments]
        onDraftReturned?(text, "Stopped before sending")
    }

    /// Returns a text send to the head only when the client knows no prompt was admitted.
    private func requeueUnsent(_ item: QueuedMessage, localId: String, epoch: Int) -> Bool {
        guard stopEpoch == epoch, turn.userAnchorId == localId, !turn.turnLive, !turn.sawAssistantPayload else { return false }
        AppLog.trace("send", "send \(AppLog.tag(localId)) never left; queued for reconnect")
        removeMessage(localId)
        turn.userAnchorId = nil
        settleFlags()
        queuedMessages.insert(item, at: 0)
        changes.markState()
        scheduleFlush()
        scheduleQueueDrain(after: queueDrainFallback)
        return true
    }

    // MARK: Queue (04 §6.2 M1)

    /// Sends a queued message now: at once when idle; while a reply runs, it moves to the head and the reply is stopped
    /// so it goes out when the turn unwinds (the web's "Send Now").
    func sendQueuedNow(_ id: String) {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        AppLog.trace("send", "queued \(AppLog.tag(id)) send now (was \(index + 1) of \(queuedMessages.count)), busy=\(turn.busy)\(turn.busy ? " → stop the reply" : "")")
        let item = queuedMessages.remove(at: index)
        queuedMessages.insert(item, at: 0)
        if turn.busy {
            stop()
            isQueueParked = false
            changes.markState()
            scheduleQueueDrain(after: .zero)
        } else {
            isQueueParked = false
            drainQueueHead()
        }
        scheduleFlush()
    }

    /// Takes a message out of the queue (to edit or discard it) and returns its text. [activity] A hidden goal
    /// continuation returns nil: its text is Hermes's internal prompt, never handed to the field (1x-activity §6.4).
    @discardableResult
    func removeQueued(_ id: String) -> String? {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return nil }
        let item = queuedMessages.remove(at: index)
        AppLog.trace("send", "queued \(AppLog.tag(id)) taken out (\(queuedMessages.count) left)")
        if queuedMessages.isEmpty { isQueueParked = false }
        memoQueueItemRemoved(item)   // VOICE: a memo returns as the draft chip
        changes.markState()
        scheduleFlush()
        if !item.attachments.isEmpty { returnAttachments(item.attachments, text: nil) }                        // [attachments]
        return item.hidden ? nil : (item.display ?? item.text)   // [activity] a hidden continuation never reaches the field
    }

    func unparkQueue() { isQueueParked = false }

    func parkQueue() {
        guard !queuedMessages.isEmpty, !isQueueParked else { return }
        AppLog.trace("send", "queue parked in \(logIds): \(queuedMessages.count) held until the next send")
        isQueueParked = true
        queueDrainTask?.cancel(); queueDrainTask = nil
        changes.markState()
    }

    /// Drains the head once the turn has ended: at once after `session.info running:false`, else after a short wait for
    /// it (`queued:true` keeps a still-running turn from being interrupted either way).
    func scheduleQueueDrain(after delay: Duration) {
        guard !queuedMessages.isEmpty, !isQueueParked, canDrainQueue else { return }
        queueDrainTask?.cancel()
        queueDrainTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.queueDrainTask = nil
            self.drainQueueHead()
        }
    }

    func drainQueueHead() {
        guard !queuedMessages.isEmpty, !isQueueParked, !turn.busy, canDrainQueue, queuedMessages.first?.id != queueEditingId else { return }
        queueDrainTask?.cancel(); queueDrainTask = nil
        let next = queuedMessages.removeFirst()
        AppLog.trace("send", "queue drain \(logIds): \(AppLog.tag(next.id)) goes out (\(next.hidden ? "hidden goal" : next.memo != nil ? "memo" : "message"), \(queuedMessages.count) left, \(observing ? "on screen" : "off screen"))")
        changes.markState()
        if next.hidden { submitHidden(next.text, queued: true); return }    // [activity] goal continuation
        if let memo = next.memo { beginMemoSend(memo, typed: next.text, queued: true); return }   // VOICE
        beginSend(next.text, display: next.display, queued: true, attachments: next.attachments,
                  retryItem: canQueueWhileDisconnected && next.attachments.isEmpty ? next : nil)
    }

    /// [activity] Queues a hidden goal continuation behind the running reply (docs/spec/1x-activity.md §6.4).
    func enqueueHidden(_ text: String, display: String?) {
        queuedMessages.append(QueuedMessage(id: nextQueuedId(), text: text, hidden: true, display: display))
        changes.markState()
        scheduleFlush()
        if !turn.busy { drainQueueHead() }
    }

    func refuseSend(localId: String, text: String, reason: String, queued: Bool,   // VOICE: internal
                    attachments: [DraftAttachment] = []) {
        AppLog.note("send", "send \(AppLog.tag(localId)) refused in \(logIds): \(AppLog.scrub(String((reason.split(separator: "\n").first ?? "").prefix(100)))); queued=\(queued), attachments=\(attachments.count), \(observing ? "on screen" : "off screen"), queue parked (\(queuedMessages.count))")
        // MENUS: a refused rewind puts the transcript back as it was and says why (no error card, no draft).
        if rewindRefused(localId: localId, reason: reason) { return }
        if voiceLiveSends.removeValue(forKey: localId) != nil { onVoiceLiveRefused?() }   // [gpt-live]
        let text = memoSendFinished(localId, .refused) ?? text   // VOICE: a memo's typed words; the memo → draft chip
        removeMessage(localId)
        if turn.userAnchorId == localId { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        parkQueue()                     // a refused send never cascades through the rest of the queue
        // [transcript] §6.3 DECISION: one failure, one place. The refusal is said in the "Couldn’t Send" card at the
        // composer (as on the web), not in an error card in the transcript as well. The state lives on the session, so
        // a send refused while the chat was off screen shows its card when the chat is next on screen.
        sendFailure = SendFailure.make(reason: reason)
        settleFlags()
        changes.markState()
        scheduleFlush()
        if !attachments.isEmpty { returnAttachments(attachments, text: text, refused: true) }                  // [attachments]
        else { returnWordsToDraft(text) }   // verify round 3: refused off screen (a queue drained away)
        onDraftReturned?(text, reason.isEmpty ? "Your message wasn’t sent." : reason)
    }

    /// `4090` with reason `SESSION_NOT_OWNED` (hermes_cli/active_sessions.py): another live process holds this chat.
    nonisolated static func isOwnedElsewhere(_ error: RPCError) -> Bool {
        error.data?["reason"]?.string == "SESSION_NOT_OWNED" || TurnErrors.owned.test(error.message)
    }

    /// `4090` with reason `SESSION_OWNER_BUSY` (tui_gateway/methods_prompt.py `_submit_to_ledger_owner`): the gateway
    /// runs a turn in this chat and its queue couldn't take this prompt. Nothing was sent; it goes once the turn ends.
    nonisolated static func isOwnerBusy(_ error: RPCError) -> Bool {
        error.data?["reason"]?.string == "SESSION_OWNER_BUSY"
    }

    /// `4090` with reason `SESSION_OWNER_UNCONFIRMED`: the gateway's queue didn't confirm the prompt in time and may
    /// still hold it. Never resent (a second copy would run): "Delivery unconfirmed", like a timed-out submit (§2.5).
    nonisolated static func isOwnerUnconfirmed(_ error: RPCError) -> Bool {
        error.data?["reason"]?.string == "SESSION_OWNER_UNCONFIRMED"
    }

    /// [locked-chat] A refusal that says the gateway won't open this chat at all, so waiting or resuming can't help:
    /// `4001 profile_mismatch` (the chat's stored record names another bot folder, e.g. one renamed since), or a
    /// `SESSION_OWNER_BUSY` whose hand-off to the gateway's queue was itself refused ("…and the gateway refused it.",
    /// tui_gateway/methods_prompt.py `_submit_to_ledger_owner`): the queued work it waits behind can never run.
    nonisolated static func isChatLocked(_ error: RPCError) -> Bool {
        if error.code == 4001, error.data?["reason"]?.string == "profile_mismatch" || error.message == "profile_mismatch" { return true }
        return error.code == 4090 && isOwnerBusy(error) && TurnErrors.handOffRefused.test(error.message)
    }

    /// A refusal the send waits out instead of failing at once.
    nonisolated static func waitsForOwner(_ error: RPCError) -> Bool {
        error.code == 4090 && (isOwnedElsewhere(error) || isOwnerBusy(error))
    }

    /// The holder is a one-shot `hermes chat` (surface "cli": cron jobs and background deliveries into the bot's chat),
    /// which lets go when its run ends. Its refusal's second line: "Details: session <id> opened by cli 0m ago."
    nonisolated static func ownerIsOneShotRun(_ error: RPCError) -> Bool {
        error.message.range(of: #"opened by cli\b"#, options: .regularExpression) != nil
    }

    /// The holder is the messaging gateway running a turn for a platform's message: "opened by gateway:telegram 0m
    /// ago." (`gateway/run_busy.py` claims the chat as `gateway:<platform>`). The platform's name, "" when it names none,
    /// nil when the holder isn't the messaging gateway.
    nonisolated static func ownerMessagingPlatform(_ error: RPCError) -> String? {
        guard let match = error.message.firstMatch(of: /opened by gateway(?::([A-Za-z0-9_\-]+))?(?=[\s.]|$)/) else { return nil }
        return match.1.map { ChatSource.label(String($0)) } ?? ""
    }

    /// Who holds the chat a refused (4090) send waits for.
    nonisolated static func ownerWait(_ error: RPCError) -> OwnerWait {
        if isOwnerBusy(error) { return .runningReply }
        if ownerIsOneShotRun(error) { return .backgroundTask }
        if let app = ownerMessagingPlatform(error) { return .messagingTurn(app.isEmpty ? nil : app) }
        return .otherWindow
    }

    /// [owner-wait] A call that never went out because the link is away for now (paused in the background, offline,
    /// the gateway restarting): a waiting send keeps waiting. Sign-out or a gateway switch ends the wait.
    nonisolated static func linkAwayForNow(_ error: RPCError) -> Bool {
        guard let why = error.notSentBecause else { return false }
        switch why {
        case .signedOut, .sessionEnded, .connectionChanged, .accountMissing: return false
        default: return true
        }
    }

    /// The mark on your message whose `prompt.submit` may or may not have reached the gateway (04 §2.5).
    static let unconfirmedMark = "Delivery unconfirmed"

    private func markUnconfirmed(localId: String, queued: Bool, epoch: Int) {
        let memo = memoSends[localId] != nil            // [sessions-m9]
        AppLog.note("send", "send \(AppLog.tag(localId)) in \(logIds) marked Delivery unconfirmed (queued=\(queued), memo=\(memo)); queue parked")
        _ = memoSendFinished(localId, .unconfirmed)   // VOICE: never resent; the file goes to the cache
        voiceLiveSends[localId] = nil   // [gpt-live] the turn may run: the delegation waits for its reply as usual
        if menus.rewinds.removeValue(forKey: localId) != nil { menus.wholeReloadOwed = true }   // MENUS: read it whole later
        updateMessage(localId) { m in
            m.isPending = false
            m.error = LiveChatSession.unconfirmedMark
        }
        noteLostSend(localId, memo: memo)               // [sessions-m9] its Sessions row says "Not Delivered:" (3x-sessions §9.4)
        parkQueue()
        // A Stop came after it and a newer send owns the turn now: that turn is not this one's to settle.
        let superseded = stopEpoch != epoch && turn.userAnchorId != nil && turn.userAnchorId != localId
        if !turn.turnLive && !turn.sawAssistantPayload && !superseded { settleFlags() }
        changes.markState()
        scheduleFlush()
    }

    /// The read-only "Check" for a "Delivery unconfirmed" message (04 §2.5): looks for it in the stored transcript —
    /// by its `user_row_id` when one came back, else a user row after the last known row with the same text.
    /// `true` = delivered (the mark is cleared), `false` = not there, `nil` = couldn't tell. Never resends.
    func checkDelivery(_ messageId: String) async -> Bool? {
        guard let stored = readSessionId, let index = indexById[messageId] else { return nil }
        let message = messages[index]
        let knownRow = messages[..<index].compactMap(\.rowId).max() ?? 0
        // [presence] A titled request is stored as the request it stands for, not as its bubble's words.
        let sentText = LiveChatSession.sentTitles.prompt(forTitle: message.plainText) ?? message.plainText
        let request = HistoryRequest(storedSessionId: stored, profile: profileParam, limit: 24)
        guard let (page, _) = try? await HistoryAPI.fetch(client: client, request: request, features: perfFeatures) else {
            AppLog.note("send", "check delivery \(AppLog.tag(messageId)): read failed, couldn't tell")
            return nil
        }
        let found = page.rows.contains { row in
            guard row["role"]?.string == "user", let id = HistoryPage.rowId(row) else { return false }
            if let mine = message.rowId { return id == mine }
            return id > knownRow && Hydration.userDisplayKey(Hydration.displayContent(role: "user", content: row["content"]))
                == Hydration.userDisplayKey(sentText)                                                             // [attachments]
        }
        AppLog.trace("send", "check delivery \(AppLog.tag(messageId)) in \(logIds): \(found ? "delivered (mark cleared)" : "not in the newest \(page.rows.count) rows") (by \(message.rowId != nil ? "row id" : "text after row \(knownRow)"))")
        if found {
            updateMessage(messageId) { m in m.error = nil }
            clearLostSend(messageId)                    // [sessions-m9]
            scheduleFlush()
            startRefresh(force: true)
        }
        return found
    }

    // MARK: Stop (04 §5, §5.6)

    func stop() {
        flushDeltas()
        guard turn.busy || turn.streamId != nil else { return }
        if memoStopWhileStaging() { return }   // VOICE: a memo still staging comes back as the draft; nothing reached the gateway
        AppLog.trace("turn", "stop pressed \(logIds): stream \(AppLog.tag(turn.streamId)), anchor \(AppLog.tag(turn.userAnchorId)), queued=\(queuedMessages.count), uploads waiting=\(inFlightAttachments.values.flatMap { $0 }.count)")
        stopEpoch += 1
        activityStopPressed()             // [activity] children and task lists go; late frames dropped (§4.2, §5.2)
        parkQueue()                       // Stop halts the queue too (the web parks it); Send Now unparks
        // [attachments] A send still waiting for its uploads hears the Stop at once (its draft comes back now, not
        // when the upload finishes, which offline can be never: docs/spec/1x-attachments.md §6.4 step 9).
        let waiting = inFlightAttachments.values.flatMap { $0 }
        if !waiting.isEmpty { AttachmentCenter.existing(account.id)?.interruptWaits(waiting) }
        let lastUserIndex = turnAnchorIndex()
        turn.stoppedAnchorId = turn.userAnchorId ?? (lastUserIndex >= 0 ? messages[lastUserIndex].id : nil)
        if let sid = turn.streamId, let index = indexById[sid] {
            let m = messages[index]
            if m.hasVisibleContent {
                updateMessage(sid) { msg in
                    msg.isStreaming = false
                    msg.interrupted = true
                    LiveChatSession.sealTools(&msg, summary: "Stopped")
                }
            } else {
                updateMessage(sid) { msg in msg.isStreaming = false; msg.interrupted = true; msg.parts = [] }
            }
        } else if !messages[(lastUserIndex + 1)...].contains(where: { $0.role == .assistant }) {
            // Stopped before the first token: keep a "Stopped" row for the prompt (R:src/fe-convo-r3.ts r6-06).
            localCounter += 1
            var marker = ChatMessage(id: "local-stopped-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
            marker.interrupted = true
            appendMessage(marker)
        }
        settleFlags()
        turn.interrupted = true
        turn.stopTerminalPending = true
        turn.stopPending = false
        turn.stopRetried = false
        silentTools = [:]
        changes.markState()
        scheduleFlush()
        if interruptTask == nil {
            interruptTask = Task { [weak self] in
                await self?.sendInterrupt()
                // Never two in flight (04 §5.6 step 2), but the one that was out may have reached the gateway before a
                // send made since (queued there behind the stopped turn): a Stop pressed meanwhile interrupts again, as
                // long as the chat still stands stopped with nothing held behind it.
                while let me = self, me.interruptOwed {
                    me.interruptOwed = false
                    guard me.turn.interrupted, !me.turn.submitHeld else { break }
                    AppLog.trace("turn", "stop pressed again while the interrupt was out: interrupting \(me.logIds) once more")
                    await me.sendInterrupt()
                }
                self?.interruptTask = nil
            }
        } else {
            interruptOwed = true
        }
    }

    private func sendInterrupt() async {
        if runtimeSessionId == nil {
            let snap: JSONValue
            do { snap = try await resumeNow() } catch {   // [diagnostics]
                AppLog.note("turn", "stop: no runtime and resume failed (\(Self.logError(error))); interrupt not sent")
                return
            }
            if snap["running"]?.bool != true {
                AppLog.trace("turn", "stop: resumed \(logIds), not running; stop settled")
                stopTerminalReached(); return
            }
        }
        guard let rid = runtimeSessionId else { return }
        var params: [String: JSONValue] = ["session_id": .string(rid)]
        if let profileParam { params["profile"] = .string(profileParam) }
        do {
            _ = try await client.call("session.interrupt", .object(params), timeout: interruptTimeout)
            AppLog.trace("turn", "stop: interrupt accepted on rt \(AppLog.tag(rid))")
        } catch let error as RPCError where error.code == 4064 {
            AppLog.note("turn", "stop: 4064 profile gone, settled")
            onRosterStale?()
            stopTerminalReached()
        } catch let error as RPCError where error.code == 5032 || error.isTimeout || error.isConnectionLost || error.isNotConnected {
            // The stop did not reach the turn (agent still building, no answer, the link dropped or was down): keep it
            // stopped on screen and interrupt again when the turn shows it is ready, or on the reconnect (§5.6 step 4).
            AppLog.note("turn", "stop: interrupt didn't reach rt \(AppLog.tag(rid)) (\(Self.logError(error))); stop pending, retried on ready/reconnect")
            turn.stopPending = true
        } catch let error as RPCError where error.code == 4001 || error.code == 4007 {
            // The runtime is gone: resume once; interrupt the live runtime it returns, else settle (§5.6 step 5).
            AppLog.trace("turn", "stop: rt \(AppLog.tag(rid)) gone (\(error.code)), resume once")
            runtimeSessionId = nil
            guard let snap = try? await resumeNow() else {
                AppLog.note("turn", "stop: resume after \(error.code) failed; settled")
                stopTerminalReached(); return
            }
            if snap["running"]?.bool == true, let rid2 = runtimeSessionId {
                var p2: [String: JSONValue] = ["session_id": .string(rid2)]
                if let profileParam { p2["profile"] = .string(profileParam) }
                AppLog.trace("turn", "stop: resumed rt \(AppLog.tag(rid2)) still running, interrupting it")
                do { _ = try await client.call("session.interrupt", .object(p2), timeout: interruptTimeout) } catch {   // [diagnostics]
                    AppLog.swallowed("turn", "stop: second interrupt on rt \(AppLog.tag(rid2))", error)
                }
            } else {
                AppLog.trace("turn", "stop: resumed \(logIds) not running; settled")
                stopTerminalReached()
            }
        } catch let error as RPCError {
            AppLog.note("turn", "stop failed on rt \(AppLog.tag(rid)): \(Self.logError(error)); \"Stop failed\" shown")
            onNotice?("Stop failed")
        } catch {
            AppLog.note("turn", "stop: interrupt \(Self.logError(error)); stop pending")
            turn.stopPending = true      // timeout: the stop did not reach the turn
        }
    }

    /// One more interrupt for a prompt that Stop overtook in flight (its ack came back after the first interrupt).
    func interruptAgain() {   // [activity] internal: a hidden goal continuation overtaken by Stop too
        guard let rid = runtimeSessionId else { return }
        var params: [String: JSONValue] = ["session_id": .string(rid)]
        if let profileParam { params["profile"] = .string(profileParam) }
        let client = self.client
        let timeout = interruptTimeout
        Task { [weak self] in
            do {
                _ = try await client.call("session.interrupt", .object(params), timeout: timeout)
            } catch let error as RPCError where error.code == 4064 {
                self?.onRosterStale?()
            } catch let error as RPCError where error.code == 5032 || error.isTimeout || error.isConnectionLost || error.isNotConnected {
                AppLog.trace("turn", "stop again: interrupt didn't reach rt \(AppLog.tag(rid)) (\(LiveChatSession.logError(error))); pending")
                self?.turn.stopPending = true      // re-interrupted on the turn's message.start (§5.6 step 4)
            } catch {
                AppLog.swallowed("turn", "stop again on rt \(AppLog.tag(rid))", error)
            }
        }
    }

    /// Second interrupt when a stopped-but-pending turn shows it is ready (§5.6 step 4).
    func reinterrupt() {
        guard turn.stopPending, !turn.stopRetried, let rid = runtimeSessionId else { return }
        turn.stopRetried = true
        AppLog.trace("turn", "stop pending: interrupting rt \(AppLog.tag(rid)) once more (turn showed ready)")
        var params: [String: JSONValue] = ["session_id": .string(rid)]
        if let profileParam { params["profile"] = .string(profileParam) }
        let client = self.client
        let timeout = interruptTimeout
        Task { [weak self] in
            do {
                _ = try await client.call("session.interrupt", .object(params), timeout: timeout)
            } catch {
                // Still couldn't stop it: stop hiding the turn; never drop a completed reply.
                AppLog.note("turn", "stop: second interrupt on rt \(AppLog.tag(rid)) failed (\(LiveChatSession.logError(error))); turn shown again, end read forced")
                guard let self else { return }
                self.turn.interrupted = false
                self.turn.stopPending = false
                self.onNotice?("Couldn't stop — Hermes finished the reply.")
                self.scheduleTurnEndRead(force: true)
            }
        }
    }

    func stopTerminalReached() {
        turn.stopTerminalPending = false
        turn.stopPending = false
        let waiters = stopTerminalWaiters
        stopTerminalWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Index of the running turn's user bubble: our own send's, else (a turn we didn't start) the last user row that
    /// isn't a message steered into it.
    func turnAnchorIndex() -> Int {
        if let id = turn.userAnchorId, let index = indexById[id] { return index }
        return messages.lastIndex { $0.role == .user && !turn.correctionIds.contains($0.id) } ?? -1
    }

    private func waitForStopTerminal(_ limit: Duration) async -> Bool {
        guard turn.stopTerminalPending else { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self else { return }
            let waiters = self.stopTerminalWaiters
            self.stopTerminalWaiters = []
            waiters.forEach { $0.resume() }
        }
        await withCheckedContinuation { stopTerminalWaiters.append($0) }
        timeout.cancel()
        return !turn.stopTerminalPending
    }

    // MARK: Message mutation (every content change bumps `revision` and records a precise change)

    func rebuildIndex() {
        indexById.removeAll(keepingCapacity: true)
        for (i, m) in messages.enumerated() { indexById[m.id] = i }
    }

    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        indexById[message.id] = messages.count - 1
        changes.append(message.id)
    }

    func removeMessage(_ id: String) {
        guard let index = indexById[id] else { return }
        messages.remove(at: index)
        metaById[id] = nil
        rebuildIndex()
        changes.remove(id)
        if turn.streamId == id { turn.streamId = nil; turn.openPart = nil }
    }

    func updateMessage(_ id: String, _ body: (inout ChatMessage) -> Void) {
        guard let index = indexById[id] else { return }
        var m = messages[index]
        let before = m
        body(&m)
        guard !m.sameContent(as: before) else { return }
        m.revision = before.revision + 1
        messages[index] = m
        changes.update(id)
    }

    static func sealTools(_ m: inout ChatMessage, summary: String) {
        for i in m.parts.indices {
            guard case .tool(var call) = m.parts[i], call.state == .running else { continue }
            call.state = .done
            call.summary = summary
            let args = call.argsText.flatMap { ChatJSON.parse(string: $0)?.object } ?? [:]
            call.title = ToolPresentation.title(for: .init(name: call.name, args: args, pending: false, failed: false, hasResult: false),
                                                live: false)
            m.parts[i] = .tool(call)
        }
    }

    func settleFlags() {
        turn.busy = false
        turn.submitHeld = false
        turn.sentPastStop = false
        turn.awaitingResponse = false
        turn.streamId = nil
        turn.openPart = nil
        turn.interimBoundaryPending = false
        turn.turnLive = false
        turn.turnStartedAt = nil
        turn.generatingTool = nil
        turn.providerWait = nil
        turn.compacting = false
        turn.armedAt = nil
        turn.preparingSendId = nil
        turn.waitingForOwner = nil
        turn.forwarded = false
        turn.inflightUserKey = nil
        turn.anchorPromptKey = nil
        turn.correctionIds = []
        turn.followsStopAt = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// A send whose stop hold ran out went to the gateway queued behind the stopped turn, still held (04 §5.4). That
    /// turn's terminal frame (or its send running now) lets it go: from here the frames are its own turn's.
    @discardableResult
    func releaseSendPastStop(_ why: String) -> Bool {
        guard turn.sentPastStop, turn.submitHeld else { return false }
        AppLog.trace("turn", "send past the stop hold on \(logIds) let go: \(why)")
        turn.sentPastStop = false
        turn.submitHeld = false
        turn.interrupted = false
        turn.stopPending = false
        turn.stopRetried = false
        turn.followsStopAt = Date()
        changes.markState()
        return true
    }

    /// [attachments] The send's uploads and attaches are done and its prompt goes out now: from here its turn is the
    /// gateway's, so the watchdog and the 15 s pre-start rule count from this moment.
    func endPreparing(_ localId: String) {
        guard turn.preparingSendId == localId else { return }
        turn.preparingSendId = nil
        turn.lastEventAt = Date()
        turn.armedAt = Date()
    }

    /// The canonical (stored) id of a displayed row.
    func canonicalId(_ displayed: String) -> String {
        aliases.first { $0.value == displayed }?.key ?? displayed
    }

    /// A pending live message from a turn that never settled is sealed before the next send (04 §2.6 step 2).
    private func sealLeftoverLiveMessage() {
        guard let sid = turn.streamId, let index = indexById[sid] else { return }
        AppLog.trace("turn", "leftover live row \(AppLog.tag(sid)) \(messages[index].hasVisibleContent ? "sealed" : "removed (empty)") before the next send")
        if messages[index].hasVisibleContent || messages[index].interrupted || messages[index].error != nil {
            updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
        } else {
            removeMessage(sid)
        }
        turn.streamId = nil
        turn.openPart = nil
    }

    // MARK: Frame delivery

    func scheduleFlush() {
        ticker.schedule()
    }

    func deliver() {
        let span = MainTrail.begin("chat.deliver")        // [diagnostics] build 292
        defer { MainTrail.end(span) }
        flushDeltas()
        activityFrame()              // [activity] reasoning timing, Stop mirror
        // [external-turn] A turn of ours started: its own state says what runs from here.
        if externalWork != nil, turn.busy, turn.waitingForOwner == nil { endExternalWork("a turn of ours started") }
        // [transcript] A word that only says "wait" shows after a grace period (§6.4), so a short blip shows nothing.
        let graced = statusGrace.next(raw: computeStatus(), now: .now)
        let status = graced.shown
        statusRecheck?.cancel()
        statusRecheck = graced.recheckAfter.map { wait in
            Task { [weak self] in
                try? await Task.sleep(for: wait + .milliseconds(20))
                if !Task.isCancelled { self?.scheduleFlush() }
            }
        }
        if status != statusText {
            statusText = status
            changes.markState()
        }
        if turn.busy != reportedRunning {
            reportedRunning = turn.busy
            onRunningChange?(turn.busy)
        }
        if drainingAway && !observing { endAwayDrainIfDone() }   // verify round 3
        onVoiceChange?()   // [talk] the conversation hears every change, on screen or off
        guard !changes.isEmpty else { return }
        watchForDoubledReply()                                   // [doubled-reply]
        let emitted = changes.emissions()
        changes = ChangeSet()
        guard let onChange else { return }
        for change in emitted { onChange(change) }
    }

    /// [toolnow] The header words say what the turn is doing (a step, "Thinking…", "Writing…", another process's
    /// "Working…"), not the link, a question, a wake-up, a wait or a summary (`computeStatus`'s order). Under At the
    /// Bottom the row under the typing dots says it, so the pill doesn't (owner, 2026-10-28: the step showed twice).
    func statusIsWork() -> Bool {
        switch connection {
        case .offline, .reconnecting, .signedOut: return false
        case .connecting where everReady: return false
        default: break
        }
        if promptStatusText != nil { return false }
        if resumeStartedAt != nil, case .ready = connection, runtimeSessionId == nil, !turn.busy { return false }
        guard turn.busy else { return externalWork != nil }
        return turn.waitingForOwner == nil && !turn.compacting
    }

    /// Header words (spec 06 §4.1, R:src/ui-kit/bot-status.ts): link state first, then what the turn is doing.
    func computeStatus() -> String? {
        switch connection {
        case .offline: return "Offline"
        case .reconnecting: return "Reconnecting…"
        case .connecting where everReady: return "Reconnecting…"
        default: break
        }
        if let waiting = promptStatusText { return waiting }   // [questions] "Waiting for your approval / reply"
        // [transcript] A cold bot starting (§6.5): a resume is pending and this chat has no runtime on the gateway
        // yet. A chat already bound to its runtime (a re-resume before a send or a menu action) and a turn known to be
        // running keep their own words, so an ordinary busy chat never reads "Waking up…".
        if let since = resumeStartedAt, case .ready = connection, runtimeSessionId == nil, !turn.busy {
            return since.duration(to: .now) >= stillWakingAfter ? "Still waking up…" : "Waking up…"
        }
        // [external-turn] Another process's turn (a bot's message, Telegram, a job's hand-off): the same word as ours.
        if !turn.busy, externalWork != nil { return "Working…" }
        guard turn.busy else { return nil }
        if let wait = turn.waitingForOwner { return wait.status }
        if turn.compacting { return "Summarizing…" }
        if let step = activityHeaderStatus() { return step }      // [activity] In Header: the step running now
        if !turn.turnLive && turn.awaitingResponse { return "Thinking…" }
        if let sid = turn.streamId, let index = indexById[sid] {
            let parts = messages[index].parts
            if let running = parts.last(where: { if case .tool(let c) = $0 { return c.state == .running } else { return false } }),
               case .tool(let call) = running {
                return call.title.hasSuffix("…") ? call.title : call.title + "…"
            }
        }
        if let tool = turn.generatingTool { return ToolPresentation.presentVerb(tool) + "…" }
        guard let sid = turn.streamId, let index = indexById[sid], let last = messages[index].parts.last else { return "Thinking…" }
        switch last {
        case .reasoning: return "Thinking…"
        case .tool: return "Thinking…"
        case .text: return "Writing…"
        }
    }

    // MARK: Cache

    /// Saves backend truth only (03 §7.2): stored rows, live rows already matched to their stored row (under the stored
    /// id), and acknowledged prompts (their stored id is known). Live replies not yet re-read, error cards, Stopped
    /// markers and unconfirmed sends are never cached. Saved under the opened id and the lineage tip (03 §1).
    func saveCache() {
        guard let stored = storedSessionId, !messages.isEmpty else { return }
        let span = MainTrail.begin("chat.cache")          // [diagnostics] build 292
        defer { MainTrail.end(span) }
        var canonicalOf: [String: String] = [:]
        for (c, d) in aliases { canonicalOf[d] = c }
        var out: [ChatMessage] = []
        var seen = Set<String>()
        var meta: [String: MessageMeta] = [:]
        for m in messages where !m.isPending && !m.isStreaming {
            var c = m
            if let canonical = canonicalOf[m.id] {
                c.id = canonical
            } else if m.isLocal {
                guard m.role == .user, m.error == nil, let row = m.rowId else { continue }
                c.id = "stored-row-\(row)-user"
            }
            guard seen.insert(c.id).inserted else { continue }
            out.append(c)
            if let mm = metaById[m.id] { meta[c.id] = mm }
        }
        guard !out.isEmpty else { return }
        AppLog.trace("chat", "cache saved \(AppLog.tag(stored)): \(out.count) of \(messages.count) rows")
        cache.save(out, meta: meta, account: account.id, profile: profile, storedId: stored)
        for alternate in Set([resolvedStoredId, pageSessionId].compactMap { $0 }) where alternate != stored {
            cache.save(out, meta: meta, account: account.id, profile: profile, storedId: alternate)
        }
    }
}

// MARK: - Screen details (contract `ChatSessionDetails`)

extension LiveChatSession: ChatQueueing {}

extension LiveChatSession: ChatChangeFlushing {}

extension LiveChatSession: ChatDeliveryChecking {}

extension LiveChatSession: ChatToolDetails {}

extension LiveChatSession: ChatOpenStatus {
    var openPhase: ChatOpenPhase {
        if let openError, messages.isEmpty { return .failed(openError) }
        if chatGone && messages.isEmpty { return .failed("This chat is no longer on your gateway.") }
        // History is still owed: nothing shown is not "no messages yet".
        if firstPageOwed && messages.isEmpty { return .opening }
        // A chat just started shows the bot's intro while its session is made (the error above still wins).
        if startsNew && messages.isEmpty && (started || opensOnFirstSend) { return .open }
        return started && !openFinished ? .opening : (started ? .open : .opening)
    }
}

extension LiveChatSession: ChatSessionDetails {
    var layoutScope: String { "\(account.id)|\(profile)|\(storedSessionId ?? pendingScope ?? "")" }
    /// The newest stored time the reader has seen: the newest row any history read returned, or (a cached paint
    /// only) the newest stored message's time. Never a device-clock time (a local row's stamp before its read).
    var seenThrough: Date? {
        let shown = messages.last(where: { $0.rowId != nil && !$0.isLocal })?.timestamp?.timeIntervalSince1970
        guard let newest = [newestStoredAt, shown].compactMap({ $0 }).max() else { return nil }
        return Date(timeIntervalSince1970: newest)
    }
}
