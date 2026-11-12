// The app-wide model (contract `AppServices`): the signed-in account's client, the Bots and Sessions stores, and the
// chats the screens open. It also wires the hooks the modules leave to integration (docs/m1-module-reports.md):
// focus and unread bookkeeping around an open chat, "Working…" from the chat engine, connection changes for the
// lists, and the app lifecycle for the socket and the stores.

import UIKit

final class AppModel: AppServices {
    let signIn: SignInService
    /// Testing switch for the owner's real gateway (spec 02 §12.5): refuse every write. Off in M1 builds; both stores
    /// read it from here.
    let readOnlyGateway: Bool

    private(set) var account: GatewayAccount? {
        didSet {
            DefaultProjectFolder.activeAccount = account?.id   // [settings]
            HostWord.gatewayName = account.map { UpdateHermesScreen.name(url: $0.baseURL, label: $0.label) }   // [update-flow]
        }
    }
    private(set) var client: LiveGatewayClient?
    private(set) var botStore: BotStore?
    private(set) var sessionStore: SessionStore?
    /// Re-registers push when Outside Chats turns on or off (AppModel+Notifications.swift).
    var outsideChatsObserver: NSObjectProtocol?
    private var warmer: ChatWarmer?
    /// [activity] Subagents, tasks and goals of the account's chats (docs/spec/1x-activity.md §3.2).
    private(set) var activityStore: ActivityStore?
    /// [activity] Profiles whose chat runs a turn (a bot says Working… for a turn or a live child, §8.4).
    private var turnWorking = TurnWorking()
    private(set) var connection: ConnectionState = .connecting
    /// [questions] The account's open approvals, questions and password prompts (spec 1x §3.2); nil under the
    /// `HQNNoServerRequests` kill switch (M1 behaviour).
    private(set) var serverRequests: ServerRequestCenter?
    /// [preview-tab] Bots' Browser tabs (App/Browser/PreviewTab.swift).
    private(set) var previewTabs: PreviewTabCenter?
    /// [questions] The account's kept password sheets (typed text survives a tuck and leaving the chat, spec 1x §4.5).
    private(set) var promptSheets: PromptSheetStore?
    /// [browser] The account's browser plugin (Watch Browser, App/Browser/AppModel+Browser.swift).
    private(set) var browser: BrowserService?
    /// [presence] The account's bots' browser and screen use outside the viewer: the Bots rows' line and the notice
    /// with Watch (docs/spec/3x-presence.md §3.3, App/Presence/AppModel+Presence.swift).
    private(set) var presence: PresenceCenter?
    /// [screen] The account's Bot Screen service (App/Screen/AppModel+Screen.swift).
    private(set) var screen: ScreenService?
    /// [screen] The chats this run has live (the latest-screenshots view asks whose a live tool event is).
    var screenLiveChats: [LiveChatSession] { [focusedChat].compactMap { $0 } + awayChats }
    /// [screen] Runtime session → bot for every chat this run opened (the web's session owner): a bot that keeps
    /// working after its chat was left still says what it is doing on its latest-screenshots page.
    private var screenSessionOwners: [String: String] = [:]
    /// [screen] Before sign-out or a gateway switch ends the client: an open Screen in control hands back and waits
    /// (at most two seconds) for the gateway's answer. Nothing to do, and no wait, when no Screen is open.
    func screenLeaving() async { await screen?.handBackBeforeLeaving() }
    func screenOwnsSession(_ runtime: String, profile: String) -> Bool {   // [screen]
        screenSessionOwners[runtime] == profile || runningChats[runtime]?.profile == profile
            || screenLiveChats.contains { $0.profile == profile && $0.runtimeSessionId == runtime }
    }

    var onBotsChange: (() -> Void)?
    var onSessionsChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?
    /// The gateway ended the session (refused after renewal, revoked): show sign-in, prefilled, saying why.
    var onSessionEnded: ((SignInService.Prefill) -> Void)?
    /// The user signed out: decide again what to show (the next saved account, or sign-in).
    var onSignedOut: (() -> Void)?

    private var statesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    /// The chat on screen (between its `start()` and `stopObserving()`).
    weak var focusedChat: LiveChatSession?
    /// [offline] §6.10: the bot whose chat is on screen (the Capabilities warm-up reads for it).
    var focusedProfile: String? { focusedChat?.profile }
    /// Verify round 3: chats left with messages still queued behind a reply, held while they send them off screen
    /// (`LiveChatSession.drainingAway`); opening one of them again returns it instead of a new chat.
    private var awayChats: [LiveChatSession] = []
    /// Chats this run has opened whose turn may still run off screen, by runtime id: their "Working…" ends when the
    /// gateway says the turn completed, even after the screen went away.
    var runningChats: [String: (profile: String, storedId: String?)] = [:]
    /// Attaches turns left running off screen to a new socket (`reattachUnheardTurns`).
    private var unheardTurnsTask: Task<Void, Never>?
    /// Stored ids of sessions with a running turn (the Sessions rows' "Working…").
    private var runningSessions: Set<String> = []
    /// [working-ledger] The chats the gateway itself says run a turn (any process, any device), read while the Sessions
    /// list is on screen: they say Working… there too (WorkingLedgerWatch).
    private var workingLedger: WorkingLedgerWatch?
    /// [working-ledger] The app is in front (the ledger is read only then).
    private var ledgerAppActive = true
    /// [toolnow] Each heard chat's newest step (LiveSteps): the Bots and Sessions rows name it instead of "Working…".
    private var liveSteps = LiveSteps()
    /// [toolnow] One hand-over to the lists per quarter second: a burst of quick steps rebuilds them once.
    private var stepsPush: Task<Void, Never>?
    /// [sessions-m9] Stored ids of the chats where an approval, a question or a password prompt waits (3x-sessions §3.3).
    private var needsInputSessions: Set<String> = []
    /// The Sessions tab is the one showing (its list refreshes on the on-screen cadence only then, spec 03 §7.7).
    private var sessionsListShown = false
    /// [m9/ipad] Two panes: the lists stay on screen beside the chat on show.
    private var listsBesideChat = false
    /// [notifications] When this account's socket was first ready (permission is never asked during the replay right after).
    var notificationsReadySince: Date?
    /// [notifications] A tapped alert's chat whose tabs weren't on screen within ~6 s (a slow first launch with nothing
    /// cached): it opens when they show (`openChatAwaitingTabs`), instead of being dropped.
    var chatAwaitingTabs: (stored: String, profile: String?, at: Date)?
    private var signingOut = false
    // [m2/pages] PagesServices (App/Pages/PagesServices.swift): the pages' stores let go before their caches are deleted.
    var onSignOutPages: (() -> Void)?
    /// [restore] The launch's reopened chat waits on the roster or the Sessions list (MainTabController+LaunchChat.swift).
    var onLaunchListsChange: (() -> Void)?
    /// [restore] `display.resume_last_session` was asked for this sign-in.
    var resumePreferenceRead = false
    /// Settings stream (1x-settings): saved gateways, news check, capabilities, version (App/Settings/AppModel+Settings.swift).
    lazy var settingsHub = SettingsHub(signIn: signIn)
    /// [groups] Group chats: the account's rooms, their mirror and their rounds (App/Groups/AppModel+Groups.swift).
    let groupsHub = GroupsHub()
    /// [sync] What follows the owner from device to device: pins, orders, settings (App/Sync/SyncHub.swift).
    let syncHub = SyncHub()
    /// [offline] The launch screen's signal, the reconnect notice and the two alerts (App/Offline/OfflineHub.swift).
    let offlineHub = OfflineHub()

    init(signIn: SignInService = SignInService(), readOnlyGateway: Bool = false) {
        self.signIn = signIn
        self.readOnlyGateway = readOnlyGateway
        offlineHub.model = self                       // [offline]
        // [live words] The bots' names are words every memo, Dictate and Talk take can write as spelled.
        LiveWordsVocabulary.botNames = { [weak self] in self?.bots.map(\.name) ?? [] }
    }

    /// Where both list stores keep their per-account files (`<kind>-<account key>.json`).
    static var listsCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "lists", directoryHint: .isDirectory)
    }

    // MARK: - AppServices

    var bots: [Bot] { botStore?.bots ?? [] }
    var sessions: [SessionSummary] { sessionStore?.sessions ?? [] }

    func refreshBots() {
        guard let botStore else { return }
        Task { await botStore.refresh() }
    }

    func refreshSessions() {
        guard let sessionStore else { return }
        Task { await sessionStore.refresh() }
    }

    func chat(for bot: Bot) -> ChatSessionModel {
        guard let client, let account, let botStore else { return UnavailableChat(title: bot.name, profile: bot.id, head: bot.head) }
        // Verify round 3: the bot's chat still sending its queue off screen opens as itself (its queue, its reply).
        if let away = awayChats.first(where: { $0.menus.isBotChat && $0.profile == bot.id
            && (bot.canonicalSessionId == nil || $0.storedSessionId == bot.canonicalSessionId) }) { return away }
        botStore.noteChatOpening(true)
        botStore.noteBotOpening(bot.id, true)      // [botslist] its row says "Waking up…" once this has taken a second
        let chat = LiveChatSession(client: client, account: account, profile: bot.id, storedSessionId: bot.canonicalSessionId,
                                   title: bot.name, head: bot.head, cache: .shared,
                                   resolveSessionId: { [weak botStore] in
                                       guard let botStore else { throw CancellationError() }
                                       return try await botStore.chatSessionId(for: bot)
                                   },
                                   lastActive: bot.lastActive)
        chat.botName = bot.name
        chat.modelName = botStore.profile(named: bot.id)?.model
        chat.menus.isBotChat = true             // MENUS (spec 1x §4.1): a bot's own chat offers no Rename
        chat.activityLink.store = activityStore       // [activity]
        wire(chat)
        chat.keepQueue()                        // verify round 3: a queue left in this chat comes back
        chat.adoptEarlierDraft()                // the row's "Draft:" words are the ones the field opens with
        chat.readAhead()                        // [smooth-open]
        return chat
    }

    func chat(for session: SessionSummary) -> ChatSessionModel {
        let owner = botStore?.bot(named: session.profile)
        guard let client, let account else { return UnavailableChat(title: session.title, profile: session.profile, head: owner?.head) }
        if let away = awayChats.first(where: { $0.storedSessionId == session.id }) {   // verify round 3
            sessionStore?.markOpened(session)
            return away
        }
        botStore?.noteChatOpening(true)
        let chat = LiveChatSession(client: client, account: account, profile: session.profile, storedSessionId: session.id,
                                   title: session.title, head: owner?.head, cache: .shared, resolveSessionId: nil,
                                   lastActive: session.lastActive)
        chat.botName = owner?.name ?? sessionStore?.ownerName(for: session) ?? session.title
        chat.modelName = botStore?.profile(named: session.profile)?.model
        chat.activityLink.store = activityStore       // [activity]
        sessionStore?.markOpened(session)
        wire(chat)
        chat.keepQueue()                        // verify round 3
        chat.readAhead()                        // [smooth-open]
        return chat
    }

    /// A new chat with a bot (Bots row › New Chat, Bot Info › New Chat): not its Bot Chat but a fresh session in its
    /// profile, made on the gateway (`session.create`) as the chat opens; it lists in Sessions once it has a message.
    /// `folder`: a project's root (Sessions › a project's New Chat); the chat starts there instead of the default folder.
    func newChat(for bot: Bot, folder: String? = nil) -> ChatSessionModel {
        freshChat(for: bot, folder: folder, shownTitle: "New Chat", extra: [:], created: nil)
    }

    /// [tasks] A task's own chat: born hidden (never in Sessions, nor the desktop app's sidebar) under `sessionTitle`,
    /// headed `shownTitle` here; `created` gets the stored id once the gateway made it, so the task can keep it.
    func taskChat(for bot: Bot, sessionTitle: String, shownTitle: String,
                  created: @escaping @MainActor (String) -> Void) -> ChatSessionModel {
        let chat = freshChat(for: bot, folder: nil, shownTitle: shownTitle,
                             extra: ["title": .string(sessionTitle), "hidden": true], created: created)
        // [tasks] Opening the task's page makes no chat: the first message (or starting to write) does.
        if let live = chat as? LiveChatSession {
            live.opensOnFirstSend = true
            botStore?.noteChatOpening(false)
        }
        return chat
    }

    private func freshChat(for bot: Bot, folder: String?, shownTitle: String, extra: [String: JSONValue],
                           created: (@MainActor (String) -> Void)?) -> ChatSessionModel {
        guard let client, let account, let botStore else { return UnavailableChat(title: shownTitle, profile: bot.id, head: bot.head) }
        botStore.noteChatOpening(true)
        let profile = bot.id
        let params = extra.merging(["profile": .string(profile), "follow_profile_config": true,
                                    "idempotency_key": .string(UUID().uuidString)]) { _, base in base }
        let chat = LiveChatSession(client: client, account: account, profile: profile, storedSessionId: nil, title: shownTitle,
                                   head: bot.head, cache: .shared,
                                   resolveSessionId: { [weak client] in
                                       guard let client else { throw CancellationError() }
                                       let made = try await SessionCreate.call(client, profile: profile, params,
                                                                               folder: folder, timeout: .seconds(30))
                                       guard let stored = RosterText.trimmed(made["stored_session_id"]) ?? RosterText.trimmed(made["session_id"])
                                       else { throw RPCError(code: 4007, message: "The gateway didn’t start a new chat.", data: nil) }
                                       if let created { await MainActor.run { created(stored) } }
                                       return stored
                                   }, startsNew: true)
        chat.botName = bot.name
        chat.modelName = botStore.profile(named: profile)?.model
        chat.activityLink.store = activityStore       // [activity]
        wire(chat)
        chat.keepQueue()
        return chat
    }

    func markRead(_ bot: Bot) {
        botStore?.markRead(bot)
    }

    var botsLoaded: Bool {
        guard let botStore else { return false }
        if case .failed = botStore.loadState { return true }
        return botStore.phase >= .slim
    }

    func setSessionsListShown(_ shown: Bool) {
        sessionsListShown = shown
        if focusedChat == nil { sessionStore?.setListVisible(shown) } else if listsBesideChat { showListsBesideChat() }
        updateLedgerWanted()
    }

    func setListsBesideChat(_ beside: Bool) {
        guard listsBesideChat != beside else { return }
        listsBesideChat = beside
        if focusedChat != nil { showListsBesideChat() }
        updateLedgerWanted()
    }

    /// [working-ledger] The gateway's word on which chats run is read while the Sessions list can be seen: its tab is
    /// showing, no chat covers it (or the list stays beside the chat), and the app is in front.
    private func updateLedgerWanted() {
        workingLedger?.setWanted(ledgerAppActive && sessionsListShown && (focusedChat == nil || listsBesideChat))
    }

    /// The Sessions rows' Working…: turns this app heard, chats holding a live child (§8.4), and what the gateway says.
    private func pushRunning() {
        sessionStore?.setRunning(runningSessions.union(activityStore?.liveWorkStoredIds ?? [])
            .union(workingLedger?.storedIds ?? []))
    }

    /// A chat is on show: on a phone the lists are off screen (their reads wait the longer gap); in two panes the
    /// list beside the chat is still seen, so Sessions keeps its on-screen cadence while its tab is the one showing.
    private func showListsBesideChat() {
        let sessionsSeen = listsBesideChat && sessionsListShown
        botStore?.setListVisible(listsBesideChat)
        sessionStore?.setListVisible(sessionsSeen)
        sessionStore?.setChatFocused(!sessionsSeen)   // [perf] the off-screen list reads at the longer gap meanwhile
    }

    func prefetchChat(for bot: Bot) {
        warmer?.prefetch(bot)
    }

    /// Sign Out (Account screen, spec 01 §17): stop the stores, end the client and its session (a password session is
    /// also ended on the gateway in the background), forget this account's local caches, then decide what to show.
    func signOut() {
        // [notifications] This device leaves the gateway's push list first (<= 4 s), while the client can still ask.
        guard !signingOut else { return }
        signingOut = true
        // The account being left, as it is now: if the gateway ends its session during the waits below (the app off
        // screen), it is torn down early and `account` reads nil, but its chats, drafts and memos still go.
        let asked = (account: account, bots: botStore, sessions: sessionStore)
        Task { @MainActor in
            await screenLeaving()                 // [screen] control is handed back while the client can still ask
            await notificationsLeaving(signingOut: true)
            signingOut = false
            if account == nil { finishSignOut(leaving: asked.account, bots: asked.bots, sessions: asked.sessions) }
            else { finishSignOut(leaving: account, bots: botStore, sessions: sessionStore) }
        }
    }

    private func finishSignOut(leaving: GatewayAccount?, bots: BotStore?, sessions: SessionStore?) {
        if let leaving { ServerIssues.shared.signOut(account: leaving.id) }   // [capabilities] 3x §8.1
        if let leaving { AddOnReminder.shared.signOut(account: leaving.id) }   // [addon-reminder]
        if let leaving { PluginUpdateReminder.shared.signOut(account: leaving.id) }   // [plugin-updates]
        if leaving?.kind == .nous { NousSheetLogin.signedOut() }   // [nous-different-account] the next sheet asks who you are
        tearDown(shutdownClient: false)           // SignInService ends the client and still logs out with its cookies
        signIn.signOut()
        shareLeaving()                                // [share] the sheet offers nobody once signed out
        settingsHub.accountsChanged()                 // settings stream
        bots?.removeCachedData()
        sessions?.removeCachedData()
        if let leaving { SyncHub.forgetLists(accountId: leaving.id) }   // [sync] 13-1: with the lists' state it was about
        BotsFilterMemory.reset()                      // [botslist] the next sign-in starts unfiltered
        if let leaving {
            GroupStore.removeFiles(directory: Self.listsCacheDirectory, account: leaving)   // [groups] rooms, marks, pins
            TranscriptCache.shared.purge(account: leaving.id)
            QueueStash.shared.purge(accountId: leaving.id)            // verify round 3: messages kept queued
            LostSends.shared.purge(accountId: leaving.id)             // [sessions-m9] the rows' "Not Delivered:" words
            SideResultStash.shared.purge(accountId: leaving.id)       // /btw and /bg results kept for the launch
            AttachmentCenter.signedOut(accountId: leaving.id)       // [attachments] drafts, phone copies, media cache
            MemoDisk.flush(); MemoPaths.purge(accountId: leaving.id)   // VOICE: recordings, drafts, played memos
            // MENUS (spec 1x §2.3): favourites, recents and presets go with the account's other caches.
            ModelPrefs.forget(accountId: leaving.id)
            CommandFavorites.forget(accountId: leaving.id)            // starred commands
            ModelCatalogCache.shared.forget(account: leaving.id)
            CommandsCatalogCache.shared.forget(account: leaving.id)
            LaunchChatMemory.shared.forget(account: leaving.id)   // [restore] the chat left on show, the preference
            // [13-19] What Remove Gateway deletes and this didn't: the plugin list, the warm Capabilities copy, the
            // bots' photos (also when no Bots store was made).
            PluginListCache.shared.forget(account: leaving)
            CapabilitiesWarmCache.shared.forget(account: leaving.id)
            BotPhotoStore.purge(cacheDirectory: Self.listsCacheDirectory, account: leaving)
        }
        // [m2/pages] Jobs, Kanban and Artifacts caches go with the account (docs/spec/1x-pages.md §2.1, §2.5).
        onSignOutPages?()
        if let leaving {
            PagesCache.purge(account: leaving)
            SoulDraftStore.standard.removeAll(account: leaving.id)   // [13-12] unsaved SOUL.md text, beside the page caches
            KeychainToolRuleVault(account: leaving.id).removeAll()   // [13-13] half-saved connectors' copies (may hold headers)
        }
        intentsSignedOut()                            // [intents]
        chatAwaitingTabs = nil                        // [notifications] a tapped alert's chat never opens under the next account
        if signIn.store.accounts.isEmpty {
            offlineHub.signedOutOfLast()              // [offline] §3.5: nothing left to name
            PromptLibrary.shared.removeAll()          // ⋯ › Prompts: shared by every account, so kept until the last goes
        }
        onSignedOut?()
    }

    // MARK: - Account lifecycle

    /// Signed in (launch restore or a fresh sign-in): the client, the stores (painted from their caches at once), and
    /// the connection watch.
    func activate(_ account: GatewayAccount) {
        if self.account?.id == account.id, client != nil { return }
        tearDown(shutdownClient: true)
        self.account = account
        TranscriptCache.shared.reopen(account: account.id)   // [13-7] a sign-out's purge stopped its saves
        MemoAccountStores.shared.activate(accountId: account.id)   // VOICE
        let client = signIn.client(for: account)
        self.client = client
        // [offline] (review) A read-only gateway session writes nothing at all, the app's own performance log included.
        // Both read-only switches are DEBUG launch arguments today (`-HQDebugReadOnly`, the pages' `-HQPagesReadOnly`).
        var readOnly = readOnlyGateway
        #if DEBUG
        readOnly = readOnly || UserDefaults.standard.bool(forKey: "HQPagesReadOnly")
        #endif
        if readOnly {
            LogUploader.shared.setSender(nil, account: account.id)
        } else {
            LogUploader.shared.setSender({ body in
                _ = try await client.rest("POST", LogUploader.route, query: [], body: body, timeout: 20)
            }, account: account.id)   // [13-9] lines logged on this gateway go to this gateway only
        }
        connection = client.state
        browser = BrowserService(rest: client, sockets: client)   // [browser]
        registerBrowserMenu()                                     // [browser]
        startPresence()                                           // [presence]
        screen = ScreenService(client: client)                    // [screen]
        registerScreenMenu()                                      // [screen]
        registerTerminal()                                        // [terminal]
        // [questions] Before any chat: it subscribes to the events every request arrives on.
        if ServerRequestsSwitch.enabled {
            let center = ServerRequestCenter(client: client)
            let sheets = PromptSheetStore()
            center.onNeedsInput = { [weak self] profile, storedId, kind in self?.needsInputChanged(profile, storedId, kind) }
            center.onRemoved = { [weak sheets] ids in
                sheets?.drop(ids)
                NotificationHub.shared.withdrawLocal(requests: ids)   // [notifications] UX study #257
            }
            serverRequests = center
            promptSheets = sheets
        }
        // [preview-tab] The Browser tab a bot opens with `desktop_preview`; it also answers the bot's reads of it.
        let previewTabs = PreviewTabCenter(client: client, accountId: account.id)
        self.previewTabs = previewTabs
        serverRequests?.previewReader = { [weak previewTabs] session, params in
            await previewTabs?.read(session: session, params: params)
        }
        // [attachments] drafts restored and their uploads resumed, chat on screen or not (docs/spec/1x-attachments.md §6.3)
        let attachments = AttachmentCenter.center(for: account, client: client)

        let directory = Self.listsCacheDirectory
        let bots = BotStore(client: client, account: account, cacheDirectory: directory, autoStart: false)
        bots.readOnlyGateway = readOnlyGateway
        bots.reconcilesPinned = true                // [botslist] desktop pins and unpins get their agreeing section (L147)
        // Verify round 3: "Model changed to Opus 5.5" previews say the model's name, as the chat's own note and toast do.
        bots.modelLabel = { ModelNames.displayModelName($0) }
        // Verify round 3: a bot's chat with words typed and not sent says "Draft: <words>" on its row (spec 02 §6.4).
        let accountId = account.id
        bots.draftWords = { [weak attachments] profile, chatId in
            guard let attachments else { return nil }
            let typed = attachments.draft("\(accountId)|\(profile)|\(chatId ?? "")").text
            return typed.isEmpty && chatId != nil ? attachments.draft("\(accountId)|\(profile)|").text : typed
        }
        // [botslist] A send in the Bot Chat that may never have arrived leads the bot's row: "Not Delivered: <words>".
        bots.lostWords = { profile, chatIds in
            chatIds.lazy.compactMap { LostSends.shared.first(accountId: accountId, profile: profile, chatId: $0)?.text }.first
        }
        attachments.onDraftChange = { [weak self] in
            guard let self, self.focusedChat == nil else { return }
            self.botStore?.refreshDrafts()
            self.sessionStore?.refreshPending()       // [sessions-m9] the Sessions row's "Draft:" line
        }
        bots.onChange = { [weak self] in self?.botsChanged() }
        let sessions = SessionStore(client: client, account: account, cacheDirectory: directory, autoStart: false)
        sessions.readOnlyGateway = readOnlyGateway
        sessions.modelLabel = { ModelNames.displayModelName($0) }
        // [sessions-m9] A row's pending line (3x-sessions §9.4): a send that may never have arrived wins over words
        // waiting in the field. The reconnect probe's counters go to `probe.txt` for the UI tests (§11.2).
        sessions.pendingLine = { [weak attachments] profile, storedId in
            let lost = LostSends.shared.first(accountId: accountId, profile: profile, chatId: storedId)?.text
            return SessionPending.pending(lost: lost, draft: attachments?.draft("\(accountId)|\(profile)|\(storedId)").text)
        }
        LostSends.shared.onChange = { [weak self] in
            self?.sessionStore?.refreshPending()
            self?.botStore?.refreshDrafts()           // [botslist] the Bots row's "Not Delivered:" line follows too
        }
        sessions.onDeleted = { profile, storedId in
            LostSends.shared.clear(accountId: accountId, profile: profile, chatId: storedId)
            TranscriptCache.shared.removeEverywhere(account: accountId, storedId: storedId)      // [load-cache] its saved tail too
        }
        bots.onDeleted = { name in TranscriptCache.shared.removeProfile(account: accountId, profile: name) }
        #if DEBUG
        sessions.onProbeStats = { DebugHooks.recordText($0.text, as: "probe.txt") }
        if DebugHooks.resetSessionsView {          // UI tests: Filter and Sort from its defaults, no lost send or draft kept
            UserDefaults.standard.removeObject(forKey: NewChatLast.botKey)       // the New Chat sheet remembers nothing
            UserDefaults.standard.removeObject(forKey: NewChatLast.projectsKey)
            UserDefaults.standard.removeObject(forKey: NewChatLast.recentsKey)
            sessions.setView { $0 = SessionsViewPrefs() }
            sessions.showBackgroundRuns = false
            sessions.showOutsideChats = false
            sessions.resetGroupFolds()
            sessions.resetOrders()                 // [manual-order]
            LostSends.shared.purge(accountId: accountId)
            attachments.debugReset()
        }
        if DebugHooks.resetUnread {                // [sessions-layout] chats' and bots' unread marks from scratch
            sessions.resetUnreadForTests()
            bots.resetUnreadForTests()
        }
        if DebugHooks.outsideChats { sessions.showOutsideChats = true }
        if let group = DebugHooks.sessionsGroupBy { sessions.setView { $0.groupBy = group } }
        for key in DebugHooks.sessionsOpen { sessions.setGroupCollapsed(SessionListPipeline.projectPrefix + key, false) }
        for id in DebugHooks.sessionsFold { sessions.setGroupCollapsed(id, true) }
        if !DebugHooks.sessionsRunning.isEmpty {
            runningSessions.formUnion(DebugHooks.sessionsRunning)
            sessions.setRunning(runningSessions)
        }
        #endif
        // [/sessions-m9]
        sessions.onChange = { [weak self] in
            self?.onSessionsChange?()
            self?.onLaunchListsChange?()              // [restore]
            self?.refreshNotificationDirectory()      // [notifications]
            self?.intentsListsChanged()               // [intents]
        }
        botStore = bots
        sessionStore = sessions
        BotFaces.shared.use(bots.photos)       // [photoheads] every face draws this account's photos from here on
        BotPhotoPicker.removeLeftoversAtLaunch()       // [photoheads] files a pick left when the app was last closed
        // [activity] One store for the account: it hears every event once, for chats on screen or not.
        let activity = ActivityStore(client: client)
        activity.onLiveWorkChange = { [weak self] profile in self?.refreshWorking(profile) }
        activity.start()
        activityStore = activity
        let ledger = WorkingLedgerWatch(client: client)       // [working-ledger]
        ledger.onChange = { [weak self] in self?.pushRunning() }
        workingLedger = ledger
        updateLedgerWanted()
        let warmer = ChatWarmer(client: client, account: account)
        warmer.isOpen = { [weak self] profile in self?.focusedChat?.profile == profile }
        // [offline] §6.10: the web's order — the chat the next launch reopens first, then bots, then 15 Sessions rows.
        warmer.lastChat = { LaunchChatMemory.shared.recall(account: account.id).map { WarmOrder.LastChat(profile: $0.profile, storedId: $0.botChat ? nil : $0.storedId) } }
        warmer.sessionRows = { [weak self] in self?.sessionStore?.sessions ?? [] }
        self.warmer = warmer
        #if DEBUG
        // Probes of a first open with nothing saved (`-HQDebugNoWarmer YES`): no chat tails are saved ahead of a tap.
        if UserDefaults.standard.bool(forKey: "HQDebugNoWarmer") { self.warmer = nil }
        #endif
        sessions.profileDisplayNames = Self.displayNames(bots.bots)
        bots.setListVisible(true)
        sessions.setListVisible(sessionsListShown)
        bots.start()
        sessions.start()

        let states = client.connectionStates()
        statesTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.connectionChanged(state)
            }
        }
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.gatewayEvent(event)
            }
        }
        settingsDidActivate(account, client: client)  // settings stream
        notificationsDidActivate(account, client: client)   // [notifications]
        shareActivated(account)                       // [share] roster for the sheet; a share made while away opens its chat
        intentsDidActivate(account)                   // [intents]
        groupsHub.activated(self, account: account, client: client, bots: bots)   // [groups]
        syncHub.activated(account: account, client: client, bots: bots, sessions: sessions)   // [sync]
        offlineHub.activated(account, label: signIn.store.stored(account)?.label)   // [offline]
    }

    /// Settings stream (1x-settings §4.4): a gateway switch or Add Gateway… — the old gateway's stores and client go, the
    /// new one's lists paint from their disk caches at once.
    func activateSwitched(_ account: GatewayAccount) {
        shareLeaving()                                // [share] the old gateway's roster goes at once
        tearDown(shutdownClient: true)
        activate(account)
    }

    /// Stops the stores and the watches; the client too unless sign-out ends it.
    private func tearDown(shutdownClient: Bool) {
        groupsHub.tearDown()             // [groups] running rounds end here; nothing is interrupted on the gateway
        syncHub.tearDown()               // [sync]
        LiveActivityCenter.shared.accountLeft()       // [live] nothing of this account stays on the Lock Screen
        offlineHub.tornDown()                         // [offline] the reconnect notice and a waiting alert go with the account
        LogUploader.shared.setSender(nil)
        statesTask?.cancel(); statesTask = nil
        eventsTask?.cancel(); eventsTask = nil
        botStore?.onChange = nil
        sessionStore?.onChange = nil
        botStore?.stop()
        sessionStore?.stop()
        BotFaces.shared.use(nil)       // [photoheads] nothing of this account's pictures is drawn after it
        BotMoods.shared.reset()        // [moods]
        liveSteps.reset()              // [toolnow]
        stepsPush?.cancel(); stepsPush = nil
        botStore = nil
        sessionStore = nil
        warmer?.stop()
        warmer = nil
        activityStore?.shutdown()        // [activity]
        presence?.shutdown()             // [presence] its timers, its notice and every row line go with the account
        presence = nil
        browser?.shutdown()              // [browser] its sockets close; a viewer still open shows its last page
        browser = nil
        screen?.shutdown()               // [screen] an open Screen leaves by its rules (hand back, release)
        screen = nil
        activityStore = nil
        workingLedger?.stop()            // [working-ledger]
        workingLedger = nil
        turnWorking = TurnWorking()
        needsInputSessions = []          // [sessions-m9]
        HistoryFlights.shared.removeAll()
        previewTabs?.shutdown()      // [preview-tab]
        previewTabs = nil
        serverRequests?.shutdown()   // [questions] drafts and kept sheets go too (rule 9)
        serverRequests = nil
        promptSheets?.removeAll()
        promptSheets = nil
        // VOICE: a take in progress is dropped; playback stops; the memo stores belong to the next account.
        MemoController.shared.reset()
        MemoPlayer.shared.stop()
        TalkWiring.accountGone()                // [talk] no conversation, notice or speech outlives its account
        MemoUploader.resetCaches()
        MemoAccountStores.shared.deactivate(purge: false)
        if shutdownClient { client?.shutdown() }
        // Verify round 3: chats sending their queue off screen stop (what is left waits in the account's stash).
        awayChats.forEach { $0.abandonAwayDrain() }
        awayChats = []
        client = nil
        account = nil
        focusedChat = nil
        screenSessionOwners = [:]        // [screen]
        runningChats = [:]
        unheardTurnsTask?.cancel(); unheardTurnsTask = nil
        runningSessions = []
        connection = .connecting
        notificationsReadySince = nil
        onLaunchListsChange = nil                     // [restore]
        resumePreferenceRead = false
    }

    /// `returned` (docs/spec/3x-offline.md §6.8): the app was away (the first activation, or one after the background).
    /// False for a moment inside the app (Notification Center, Control Center, a permission alert, Face ID): nobody was
    /// away, the socket and the timers ran, so no list is read again; what the person may have done in that moment
    /// (alerts cleared or acted on, a question answered from an alert) is still reconciled.
    /// [connect-fast] Coming forward from the background: the socket dials back now (the return's other refreshes
    /// wait for `appDidBecomeActive`). The offline notice drops "paused" first, as `offlineHub.becameActive` does.
    func appWillEnterForeground() {
        offlineHub.willEnterForeground()
        client?.appDidBecomeActive()
    }

    func appDidBecomeActive(returned: Bool = true) {
        if returned {
            offlineHub.becameActive()                 // [offline] before the socket's own return, so a paused reconnect stays quiet
            client?.appDidBecomeActive()
            botStore?.appDidBecomeActive()
            sessionStore?.appDidBecomeActive()
            warmer?.appActive = true
            activityStore?.setAppActive(true)        // [activity]
            settingsHub.appActive(true)               // settings stream
            ledgerAppActive = true                    // [working-ledger]
            updateLedgerWanted()
        }
        focusedChat?.promptsCameOnScreen()   // [questions] answered elsewhere while away? (spec 1x §3.5)
        if returned { groupsHub.appActive(true) }     // [groups] late replies are collected
        // [notifications] Back on screen the lists are the badge's truth again; saved answers go; a failed registration retries.
        NotificationHub.shared.becameActive()
        refreshBadge()
        Task { @MainActor in await PushRegistrar.shared.flush() }
        if PushRegistrar.shared.retry { PushRegistrar.shared.sync() }
        notificationsSettleOwedRemovals()             // [notifications] audit 14-1: another gateway's owed removal
        DeviceAccessCenter.shared.appActive()        // [device-access] what bots asked while the wake-up didn't come
        openSharedChatIfAny()                         // [share] the chat a share just went to
        IntentsRuntime.shared.kick()                  // [intents] a shortcut's request waits for the app to be on screen
    }

    func appDidEnterBackground() {
        // [diagnostics] §14: the upload on leaving the app has its own named background time, given back when the
        // upload ends or after 20 s, whichever is first (and by iOS's own expiry before that).
        let upload = BackgroundTime.begin("Hermes HQ performance log")
        LogUploader.shared.kick("background", force: true) { Task { @MainActor in upload.end() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { upload.end() }
        client?.appDidEnterBackground()
        botStore?.appDidEnterBackground()
        sessionStore?.appDidEnterBackground()
        warmer?.appActive = false
        activityStore?.setAppActive(false)       // [activity]
        settingsHub.appActive(false)                  // settings stream
        ledgerAppActive = false                       // [working-ledger]
        updateLedgerWanted()
        groupsHub.appActive(false)                    // [groups] the rooms reach the disk and the mirror
        syncHub.wentBackground()                      // [sync] a change made here reaches the gateway
        HistoryFlights.shared.removeAll()
        // Debounced transcript writes reach the disk before the app may be killed (a relaunch paints from them).
        // [diagnostics] §14: `BackgroundTime` always ends, by its owner or when iOS takes the time back.
        let task = BackgroundTime.begin("Hermes HQ cache flush")
        if let account { AttachmentCenter.existing(account.id)?.flush() }   // [attachments] drafts reach the disk
        QueueStash.shared.flush()                                          // verify round 3: queued messages too
        LostSends.shared.flush()                                           // [sessions-m9]
        DispatchQueue.global(qos: .utility).async {
            TranscriptCache.shared.flush()
            RosterDiskWriter.shared.flush()
            DispatchQueue.main.async { task.end() }
        }
    }

    // MARK: - Store and connection changes

    private func botsChanged() {
        sessionStore?.profileDisplayNames = Self.displayNames(bots)
        warmer?.rosterChanged(bots)
        refreshOpenChatIdentities()
        presence?.botsChanged()                       // [presence] a bot came, went or was renamed: its browser line follows
        groupsHub.rosterChanged()                     // [groups] membership and the mirror ride on the roster
        syncHub.rosterChanged()                       // [sync] another device's pins, orders and settings ride on it too
        onBotsChange?()
        refreshNotificationDirectory()                // [notifications]
        onLaunchListsChange?()                        // [restore]
        shareRosterChanged()                          // [share]
        intentsListsChanged()                         // [intents]
        offlineHub.rosterChanged()                    // [offline] §3.2 the launch screen leaves once a list has content; §6.10 warm-ups
        LiveActivityCenter.shared.botsChanged(bots)   // [live] a turn that ended ends its Lock Screen progress
        liveSideChatsChanged()                        // [live-chats] a side chat's bot name follows a rename
    }

    /// Chat screens made here, with their header head (weak: a screen that went away drops out).
    private var openChatScreens: [(screen: WeakBox<ChatViewController>, head: WeakBox<HeadView>)] = []

    /// Verify round 2 (1x-settings §7.5): every place that draws a bot redraws when it is edited — an open chat's
    /// header (name and head), its subtitle, and its field's "Message <name>" included, not only after a reopen.
    private func refreshOpenChatIdentities() {
        openChatScreens.removeAll { $0.screen.value == nil }
        guard let botStore else { return }
        for entry in openChatScreens {
            guard let screen = entry.screen.value, let live = screen.session as? LiveChatSession,
                  let bot = botStore.bot(named: live.profile) else { continue }
            var changed = false
            if live.menus.isBotChat, live.title != bot.name { live.title = bot.name; changed = true }
            if live.botName != bot.name { live.botName = bot.name; changed = true }
            if live.head != bot.head {
                live.head = bot.head
                entry.head.value?.configure(raw: bot.head, profile: bot.id, follows: true)
                changed = true
            }
            if changed { screen.botIdentityChanged() }
        }
    }

    private static func displayNames(_ bots: [Bot]) -> [String: String] {
        Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func connectionChanged(_ state: ConnectionState) {
        guard state != connection else { return }
        AppLog.note("net", "connection \(state)")
        if state == .ready {
            // [perf] The log waits 15 s: the lists' refresh after a return goes first (the background kick sent the rest).
            LogUploader.shared.hold(until: Date().addingTimeInterval(15))
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { LogUploader.shared.kick("ready") }   // just after the hold
            if notificationsReadySince == nil { notificationsReadySince = Date() }   // [notifications]
            readResumePreference()                    // [restore]
            reattachUnheardTurns()
        }
        // [presence] The link is back: plugin sockets waiting out a back-off dial now (spec 3x-presence §11).
        if BrowserLinkRule.restored(from: connection, to: state) { browser?.linkRestored() }
        connection = state
        groupsHub.connectionChanged(state)            // [groups]
        offlineHub.connectionChanged(state, failure: client?.lastFailure)   // [offline] §5.1, before the headers read it
        onConnectionChange?()
        settingsHub.notify()                          // settings stream: titles say "Offline · <gateway>"
        if case .signedOut = state, let account {
            // The saved session was refused for good: back to sign-in with the address (and username) filled in. The
            // Keychain entry stays; a new sign-in replaces its session.
            let prefill = SignInService.Prefill(address: account.baseURL.absoluteString,
                                                username: account.kind == .password ? account.username : nil)
            // [offline] §5.2: with the app on screen the user is told first (drafts are kept) and chooses when.
            if offlineHub.holdSessionEnd(prefill) { return }
            tearDown(shutdownClient: true)
            onSessionEnded?(prefill)
        }
    }

    /// [offline] §5.2: "Sign in again" from the notice. What is typed and queued reaches the disk first, then the
    /// prefilled sign-in form shows as before.
    func endSession(_ prefill: SignInService.Prefill) {
        if let account { AttachmentCenter.existing(account.id)?.flush() }
        QueueStash.shared.flush()
        TranscriptCache.shared.flush()
        tearDown(shutdownClient: true)
        onSessionEnded?(prefill)
    }

    /// Turns that keep running after their chat left the screen: their "Working…" ends with the turn.
    private func gatewayEvent(_ event: GatewayEvent) {
        // [offline] §5.3: a message over 64 MB was skipped; said once per streak (the connection sends one event).
        if event.type == LocalEvent.messageTooLarge { offlineHub.messageTooLarge(); return }
        notificationsGatewayEvent(event)              // [settings] credits and background-process alerts
        presence?.handle(event)                       // [presence] screen tools: the row's line and the notice
        BotMoods.shared.handle(event, profile: presenceOwner(ofRuntime: event.sessionId))   // [moods] what its face acts out
        if liveSteps.handle(event, roster: DeliveryRoster.seats) { scheduleStepsPush() }       // [toolnow] the rows' step
        // Settings stream (1x-settings §3.7): a reply finished → the completion cue (web: every message.complete).
        if event.type == "message.complete" { CompletionCue.turnEnded(sessionKey: event.sessionId) }
        // [notifications] A turn of a chat this run opened ended: an alert (or the peek) unless it is the one on screen;
        // the one on screen may be the moment to ask for permission.
        if event.type == "message.complete" || event.type == "error" {
            noteTurnOutcome(event)                    // [botslist] a standing problem is the row's orange status (L185)
            if let chat = focusedChat, chat.runtimeSessionId == event.sessionId {
                askNotificationsOnce(after: event)
            } else if let tracked = runningChats[event.sessionId] {
                notificationsTurnEnded(event, profile: tracked.profile, storedId: tracked.storedId)
            }
        }
        guard let tracked = runningChats[event.sessionId] else { return }
        if let chat = focusedChat, chat.runtimeSessionId == event.sessionId { return }   // the open chat reports itself
        let ended: Bool
        switch event.type {
        case "message.complete", "error": ended = true
        case "session.info": ended = event.payload["running"]?.bool == false
        default: ended = false
        }
        guard ended else { return }
        offScreenTurnEnded(event.sessionId, tracked, reply: event.type == "message.complete" ? event.payload["text"]?.string : nil)
    }

    private func offScreenTurnEnded(_ runtime: String, _ tracked: (profile: String, storedId: String?), reply: String?) {
        runningChats[runtime] = nil
        if liveSteps.clear(runtime) { scheduleStepsPush() }   // [toolnow]
        if let id = tracked.storedId { workingLedger?.turnEnded(id) }   // [working-ledger] a read in the air can't bring it back
        setWorking(profile: tracked.profile, storedId: tracked.storedId, false)
        // The reply landed while its chat was off screen: the row says so now (and gets its dot).
        if let reply { botStore?.noteChatActivity(profile: tracked.profile, sessionId: tracked.storedId, preview: reply, at: Date(), unseen: true) }
        if let reply, let id = tracked.storedId { sessionStore?.noteLatest(profile: tracked.profile, sessionId: id, text: reply) }
    }

    /// Turns running off screen that no chat on this socket hears: when a socket drops, the gateway parks each session's
    /// events until a client binds it again, and only a chat on screen (or sending its queue) binds its session. So a
    /// turn that ended after a reconnect sent its end nowhere, and its bot said "Working…" until the app was relaunched
    /// (Otto, 2026-10-20). When the link is back, each one is attached to the new socket again (`session.activate` adds
    /// this socket beside any other viewer, the desktop keeps its own), once the connection's replay of it is over: its
    /// end then arrives like any other, reply and dot included. A turn the gateway no longer runs ended in the gap.
    private var unheardTurns: [String: (profile: String, storedId: String?)] {
        let heard = Set(screenLiveChats.compactMap(\.runtimeSessionId))
        return runningChats.filter { !heard.contains($0.key) }
    }

    /// How long a reattach that got no answer waits before asking again (tests shorten it).
    static var unheardTurnsRetryDelay: Duration = .seconds(10)

    private func reattachUnheardTurns() {
        unheardTurnsTask?.cancel()
        unheardTurnsTask = nil
        guard let client, !unheardTurns.isEmpty else { return }
        unheardTurnsTask = Task { [weak self] in
            var ended = false
            // A new reattach or sign-out cancels the lot.
            await UnheardTurns.reattachAll(client: client, retryDelay: Self.unheardTurnsRetryDelay,
                                           unheard: { self?.unheardTurns.mapValues(\.profile) ?? [:] },
                                           linkUp: { self?.connection == .ready }) { runtime, outcome in
                guard let self else { return }
                switch outcome {
                case .running(let moved?):
                    // Re-bound under a new runtime id: its frames come by that one now.
                    if let entry = self.runningChats.removeValue(forKey: runtime) { self.runningChats[moved] = entry }
                case .ended:
                    guard let tracked = self.runningChats[runtime] else { return }
                    AppLog.note("chat", "an off-screen turn ended while the link was down; its Working… ends")
                    self.offScreenTurnEnded(runtime, tracked, reply: nil)
                    ended = true
                case .running(nil), .failed, .skipped: break
                }
            } roundOver: {
                // After each round, not once after the retries: a turn that ended now shows its last line now, and a
                // later cancel cannot drop the refresh.
                if ended { self?.refreshBots(); ended = false }   // the row's last line comes from the roster
            }
            guard let self, !Task.isCancelled else { return }
            self.unheardTurnsTask = nil
        }
    }

    /// [botslist] A turn in a bot's own chat ended: an error that is a standing problem (provider sign-in, quota, no
    /// provider, blocked) becomes its row's status; a reply clears it (docs/spec/3x-botslist.md §9). The bot is the
    /// chat's owner by runtime id (the chat on screen, or one whose turn runs off screen), never the event's own word.
    private func noteTurnOutcome(_ event: GatewayEvent) {
        let profile: String
        if let chat = focusedChat, chat.runtimeSessionId == event.sessionId { profile = chat.profile }
        else if let tracked = runningChats[event.sessionId] { profile = tracked.profile }
        else { return }
        let payload = event.payload
        if event.type == "error" || payload["status"]?.string == "error" || payload["error"].isTruthy {
            let message = payload["message"]?.nonEmptyString ?? payload["error"]?.nonEmptyString ?? payload["text"]?.string
            botStore?.noteTurnFailed(profile: profile, message: message, reason: payload["data"]?["reason"]?.string ?? payload["reason"]?.string)
        } else if payload["partial"]?.bool != true {
            botStore?.noteTurnSucceeded(profile: profile)
        }
    }

    // MARK: - [presence] What App/Presence/AppModel+Presence.swift reads (spec 3x-presence §3.1)

    /// The bot whose chat a gateway event belongs to, by runtime id: the chat bound this run, a chat whose turn runs off
    /// screen, or the one on screen. Never the event's own `profile`. nil when nobody owns it or the bot is not in the roster.
    func presenceOwner(ofRuntime runtimeId: String) -> String? {
        guard !runtimeId.isEmpty else { return nil }
        let profile = activityStore?.owner(ofRuntime: runtimeId)?.profile
            ?? runningChats[runtimeId]?.profile
            ?? (focusedChat?.runtimeSessionId == runtimeId ? focusedChat?.profile : nil)
        guard let profile, !profile.isEmpty, botStore?.bot(named: profile) != nil else { return nil }
        return profile
    }

    /// The bot of the chat on screen.
    var presenceVisibleChatProfile: String? { focusedChat?.profile }

    func presenceSet(_ center: PresenceCenter?) { presence = center }

    /// [questions] A bot's own chat waits for an answer (spec 1x §3.6): its row says so.
    private func needsInputChanged(_ profile: String, _ storedId: String?, _ kind: NeedsInput?) {
        // [sessions-m9] Any chat that waits says so on its Sessions row and counts under Status › Needs Input.
        if let storedId {
            if kind != nil { needsInputSessions.insert(storedId) } else { needsInputSessions.remove(storedId) }
            sessionStore?.setNeedsInput(needsInputSessions)
        }
        BotMoods.shared.setAsking(profile, kind != nil)   // [moods] its face looks at you and hops
        guard let botStore, let bot = botStore.bot(named: profile) else { return }
        guard storedId == nil || bot.canonicalSessionId == nil || bot.canonicalSessionId == storedId else { return }
        botStore.setNeedsInput(profile, kind)
    }

    private func setWorking(profile: String, storedId: String?, _ running: Bool) {
        turnWorking.set(profile: profile, storedId: storedId, running: running)
        // [moods] A turn began: its face thinks till its events say more; none runs: a step it was on ends.
        if running { BotMoods.shared.started(profile) } else if turnWorking.isIdle(profile) { BotMoods.shared.settle(profile) }
        refreshWorking(profile)
        if let storedId {
            if running { runningSessions.insert(storedId) } else { runningSessions.remove(storedId) }
            pushRunning()                             // [activity] §8.4, [working-ledger]
        }
    }

    /// [toolnow] The steps go to the lists on the next quarter second (LiveSteps): each by its chat's bot and stored id.
    private func scheduleStepsPush() {
        guard stepsPush == nil else { return }
        stepsPush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.stepsPush = nil
            self.pushSteps()
        }
    }

    private func pushSteps() {
        var byBot: [String: [String: String]] = [:]   // profile → stored id ("" not stored yet) → words
        var bySession: [String: String] = [:]
        for (runtime, words) in liveSteps.byRuntime {
            let owner: (profile: String, storedId: String?)
            if let tracked = runningChats[runtime] { owner = tracked }
            else if let chat = screenLiveChats.first(where: { $0.runtimeSessionId == runtime }) { owner = (chat.profile, chat.storedSessionId) }
            else { continue }
            byBot[owner.profile, default: [:]][owner.storedId ?? ""] = words
            if let id = owner.storedId { bySession[id] = words }
        }
        botStore?.setSteps(byBot)
        sessionStore?.setSteps(bySession)
        liveSideChatsChanged()
    }

    /// [live-chats] The bots' other chats running a turn go to the Lock Screen's rules too, each with its bot's name,
    /// its title and its link (LiveActivityCenter.sideChatsChanged).
    private func liveSideChatsChanged() {
        guard let botStore else { return }
        let names = Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let chats = botStore.busySideChats().compactMap { busy -> LiveBot? in
            guard let name = names[busy.profile] else { return nil }
            // The Sessions list's title, or (a chat made a moment ago isn't listed yet) the open chat's own.
            let listed = sessionStore?.row(for: busy.storedId)?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let open = screenLiveChats.first { $0.storedSessionId == busy.storedId }?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = listed?.isEmpty == false ? listed : open
            return LiveBot(id: LiveBot.sideId(profile: busy.profile, session: busy.storedId), name: name, isWorking: true,
                           link: LiveActivityCenter.sessionLink(busy.storedId), step: busy.step, session: busy.storedId,
                           profile: busy.profile, chat: title?.isEmpty == false ? title : nil)
        }
        LiveActivityCenter.shared.sideChatsChanged(chats)
    }

    /// [activity] A chat's live children came or went: its Sessions row says Working… meanwhile (§8.4), and so does
    /// the bot when that chat is its own Bot Chat (BotStore.setWorkingChats).
    private func refreshWorking(_ profile: String) {
        let busy = turnWorking.busy(profile).union(activityStore?.liveWorkStoredIds(profile: profile) ?? [])
        botStore?.setWorkingChats(profile, busy)
        pushRunning()
        liveSideChatsChanged()
    }

    // MARK: - Chat hooks

    private func wire(_ chat: LiveChatSession) {
        chat.statusGraceDelay = StatusGrace.standard   // [transcript] §6.4: waiting words show after a second
        #if DEBUG
        // [transcript] UI tests: `-HQNResumeTimeout 6` so two timed-out resumes do not take four minutes.
        let seconds = UserDefaults.standard.double(forKey: "HQNResumeTimeout")
        if seconds > 0 { chat.resumeTimeout = .milliseconds(Int(seconds * 1000)) }
        #endif
        chat.lostSends = LostSends.shared               // [sessions-m9] a send that may not have arrived names itself on its row
        chat.onObservingChange = { [weak self, weak chat] observing in
            guard let self, let chat else { return }
            if observing { self.chatCameOnScreen(chat) } else { self.chatLeft(chat) }
        }
        chat.onOpenSettled = { [weak self, weak chat] fresh in
            guard let self, let chat else { return }
            self.chatOpened(chat, fresh: fresh)
        }
        chat.onRunningChange = { [weak self, weak chat] running in
            guard let self, let chat else { return }
            if let rid = chat.runtimeSessionId {
                if running { self.runningChats[rid] = (chat.profile, chat.storedSessionId) } else { self.runningChats[rid] = nil }
            } else if !running, let stored = chat.storedSessionId {
                // Reclaimed mid-turn: the runtime id went before the turn said it ended, so the entry goes by its chat.
                for (key, value) in self.runningChats where value.profile == chat.profile && value.storedId == stored {
                    self.runningChats[key] = nil
                }
            }
            // [working-ledger] Its turn ended: the gateway's last word (read before the end) no longer counts.
            if !running, !chat.externalWorking, let id = chat.storedSessionId { self.workingLedger?.turnEnded(id) }
            self.setWorking(profile: chat.profile, storedId: chat.storedSessionId, running || chat.externalWorking)
        }
        // [external-turn] Another Hermes process's turn in the open chat: its bot and Sessions rows say Working… too.
        chat.onExternalWorkChange = { [weak self, weak chat] working in
            guard let self, let chat else { return }
            // [working-ledger] It ended (not just the screen leaving it, after which the gateway's word keeps the row on).
            if !working, !chat.reportsRunning, chat.observing, let id = chat.storedSessionId { self.workingLedger?.turnEnded(id) }
            self.setWorking(profile: chat.profile, storedId: chat.storedSessionId, working || chat.reportsRunning)
        }
        // A turn sent before the chat's stored id came back: it counts under the id now, so its end clears Working…
        // (TurnWorking.resolved), and its off-screen end names the id too.
        chat.onStoredIdResolved = { [weak self, weak chat] id in
            guard let self, let chat, chat.reportsRunning || chat.externalWorking else { return }
            if let rid = chat.runtimeSessionId, let tracked = self.runningChats[rid], tracked.storedId == nil {
                self.runningChats[rid] = (tracked.profile, id)
            }
            guard self.turnWorking.resolved(profile: chat.profile, storedId: id) else { return }
            AppLog.note("chat", "stored id came mid-turn (profile \(chat.profile)): its Working… moves to \(AppLog.tag(id))")
            self.runningSessions.insert(id)
            self.refreshWorking(chat.profile)
        }
        // A running turn's chat bound (or re-bound) its runtime id after it said so: its end, heard off screen, comes
        // by the new id. Without this a send before the resume answered, or a re-resume mid-turn, kept Working… on.
        chat.onRuntimeBound = { [weak self, weak chat] old, new in
            guard let self, let chat, chat.reportsRunning else { return }
            if let old, old != new { self.runningChats[old] = nil }
            self.runningChats[new] = (chat.profile, chat.storedSessionId)
        }
        chat.onRosterStale = { [weak self] in self?.refreshBots() }
        if let serverRequests { chat.attachPrompts(serverRequests) }   // [questions]
        // MENUS (spec 1x §4.5): a rename shows on the Sessions row at once (and rolls back with it).
        chat.menus.onTitleApplied = { [weak self, weak chat] title in
            guard let self, let id = chat?.storedSessionId else { return }
            self.sessionStore?.applyTitle(id: id, title: title)
        }
        chat.onDrainingAwayChange = { [weak self, weak chat] away in
            guard let self, let chat else { return }
            self.awayChats.removeAll { $0 === chat }
            if away { self.awayChats.append(chat) }
        }
        chat.onSeenAfterLeaving = { [weak self, weak chat] seen in
            guard let self, let chat, let id = chat.storedSessionId else { return }
            self.botStore?.noteSeenAfterLeaving(profile: chat.profile, sessionId: id, seenThrough: seen)
        }
    }

    private func chatCameOnScreen(_ chat: LiveChatSession) {
        // iPad / Mac: a chat can come on screen before the one it replaces says it left. The bot list stops counting
        // that one as watched now (until this one's open settles and claims it), or a roster read meanwhile quietly
        // acknowledged its new replies.
        if let previous = focusedChat, previous !== chat {
            botStore?.setFocusedChat(profile: nil, sessionId: nil, seenThrough: previous.seenThrough)
        }
        focusedChat = chat
        notificationsFocus(runtime: chat.runtimeSessionId, stored: chat.storedSessionId ?? chat.resolvedStoredId)   // [notifications]
        showListsBesideChat()
        updateLedgerWanted()                          // [working-ledger]
        if let id = chat.storedSessionId { sessionStore?.setFocusedSession(id) }
    }

    /// The open applied fresh history: the chat is focused for the roster (its activity is seen, not unread) and,
    /// for a bot's chat, the bot is read.
    private func chatOpened(_ chat: LiveChatSession, fresh: Bool) {
        intentsVisited(chat)                          // [intents]
        botStore?.noteChatOpening(false)
        if chat.menus.isBotChat { botStore?.noteBotOpening(chat.profile, false) }   // [botslist]
        if let runtime = chat.runtimeSessionId { screenSessionOwners[runtime] = chat.profile }   // [screen]
        if focusedChat === chat { notificationsFocus(runtime: chat.runtimeSessionId, stored: chat.storedSessionId ?? chat.resolvedStoredId) }
        guard fresh, focusedChat === chat, let id = chat.storedSessionId else { return }
        sessionStore?.setFocusedSession(id)
        botStore?.setFocusedChat(profile: chat.profile, sessionId: id)
        if let bot = botStore?.bot(named: chat.profile), bot.canonicalSessionId == nil || bot.canonicalSessionId == id {
            botStore?.markRead(bot)
        }
    }

    private func chatLeft(_ chat: LiveChatSession) {
        botStore?.noteChatOpening(false)
        if chat.menus.isBotChat { botStore?.noteBotOpening(chat.profile, false) }   // [botslist] leaving ends the wait
        botStore?.refreshDrafts()            // verify round 3: the row's "Draft:" line follows what was typed
        sessionStore?.refreshPending()       // [sessions-m9] and the Sessions row's
        if focusedChat === chat || focusedChat == nil {
            let seen = chat.seenThrough
            botStore?.setFocusedChat(profile: nil, sessionId: nil, seenThrough: seen)
            focusedChat = nil
            sessionStore?.setChatFocused(false)     // [perf]
            updateLedgerWanted()                    // [working-ledger] back on the list: read now
            notificationsFocus(runtime: nil, stored: nil)   // [notifications]
            // Back on the list: the row shows the exchange just seen (the roster may be up to 30 s old).
            if let seen, let id = chat.storedSessionId, !chat.isRunning,
               // [restated] Not your request as Hermes restated it after compressing the chat: a repeat.
               let last = chat.messages.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.plainText.isEmpty
                   && !($0.role == .user && TimelineNotes.restatedRequest($0.plainText) != nil) }) {
                // [botsaid] The Bots row shows the bot's own newest words: not yours, a run's report or another bot's.
                let said = chat.messages.last { $0.role == .assistant && $0.sender == nil && $0.job == nil && !$0.silentNote
                    && $0.report == nil && !$0.plainText.isEmpty }
                botStore?.noteChatActivity(profile: chat.profile, sessionId: id, preview: said?.plainText, at: seen, unseen: false)
                sessionStore?.noteLatest(profile: chat.profile, sessionId: id, text: last.plainText)
            }
        }
        // A turn still running is tracked under the id it runs by now, whatever id it started under.
        if chat.reportsRunning, let rid = chat.runtimeSessionId {
            for (key, value) in runningChats where key != rid && value.profile == chat.profile && value.storedId == chat.storedSessionId {
                runningChats[key] = nil
            }
            runningChats[rid] = (chat.profile, chat.storedSessionId)
        }
        botStore?.setListVisible(true)
        sessionStore?.setListVisible(sessionsListShown)
    }

    // MARK: - Chat screen

    /// The chat screen for a model: the bot's head left of the name in the title (dropped at the largest text sizes,
    /// spec 06 §10), ⋯ with Info and Share, and the title opening the same Info sheet (spec 06 §4.1).
    func makeChatScreen(_ model: any ChatSessionModel) -> UIViewController {
        AppLog.note("screen", "open chat (\(model.messages.count) messages)")
        let screen = ChatViewController(session: model)
        screen.promptSheets = promptSheets   // [questions]
        let head = HeadView(side: 34)
        head.configure(raw: model.head, profile: model.profile, follows: true)   // [moods] the face acts out its turn
        screen.titleAccessoryView = head
        screen.onSignInAgain = { [weak self] in self?.offlineHub.signInAgain() }   // UX study #121
        openChatScreens.removeAll { $0.screen.value == nil }
        openChatScreens.append((WeakBox(screen), WeakBox(head)))
        screen.makeInfoContent = { [weak self, weak model] in   // [mac-layout] the same rows, in the Mac's inspector
            guard let self, let model else { return nil }
            return ChatInfoSheet.makeContent(model: model, account: self.account,
                                             modelName: self.botStore?.profile(named: model.profile)?.model,
                                             store: self.sessionStore,
                                             profileName: { [weak self] id in
                                                 self?.botStore?.bot(named: id)?.name ?? SessionsViewController.readableProfileName(id)
                                             })
        }
        let info = { [weak self, weak screen, weak model] in
            guard let self, let screen, let model else { return }
            // [sessions-m9] Session Info: the stored row comes from the Sessions store; Profile reads as the bot's name.
            PanePopover.hangNext(on: screen.navigationItem.titleView, arrow: .up, from: screen, size: CGSize(width: 340, height: 680), bar: false)   // [ipad-polish] under the title in two panes
            screen.present(ChatInfoSheet.make(model: model, account: self.account,
                                              modelName: self.botStore?.profile(named: model.profile)?.model,
                                              store: self.sessionStore,
                                              profileName: { [weak self] id in
                                                  self?.botStore?.bot(named: id)?.name ?? SessionsViewController.readableProfileName(id)
                                              }), animated: true)
        }
        // Settings stream (1x-settings §8): in a bot's own chat the header opens Bot Info (name, head, sections, pin), as
        // the web's bot title view does; ⋯ › Info keeps the chat's own info (session id, model). Other chats: Info.
        screen.onTitleTap = { [weak self, weak screen, weak model] in
            guard let self, let screen, let model else { return }
            if (model as? LiveChatSession)?.menus.isBotChat == true, self.botEditing != nil,
               let bot = self.botStore?.bot(named: model.profile) {
                BotInfoSheet.present(bot: bot, from: screen, services: self)
            } else {
                info()
            }
        }
        // MENUS (spec 1x §4): the ⋯ menu (Share, Info, Model ▸, Rename…), ☰, the dispatcher's hooks, hold menus.
        let menus = ChatMenus.install(on: screen, account: account, info: info)
        menus.host = self                           // MENUS: Pin, unread, Archive, Delete, Branch (AppModel+ChatMenus.swift)
        // [activity] DEBUG: ⋯ › Tool Calls (UI tests, screenshots); Settings › Chat › Tool Calls is the real way in.
        menus.slotItems[.more] = { [weak screen] in screen.map { Self.debugActivityItems($0) } ?? [] }
        installBrowser(on: screen, menus: menus)   // [browser] the shelf's browser card and ⋯ › Watch Browser
        if let live = model as? LiveChatSession {
            // A refused send hands its words back (04 §2.4.1): into the field when it is empty, never lost. Its reason is
            // already on the error card in the transcript; only a send Stop withdrew (no card) says so in a notice.
            live.onDraftReturned = { [weak screen, weak live] text, reason in
                guard let screen else { return }
                // [transcript] §6.3: typing done meanwhile is never overwritten; the returned words go before it.
                let typed = screen.composer.text
                if typed.isEmpty { screen.composer.text = text }
                else if !text.isEmpty, typed != text, !typed.hasPrefix(text + "\n") { screen.composer.text = text + "\n" + typed }
                // A refused send says why in the "Couldn’t Send" card; only a send Stop withdrew says so in a notice.
                if live?.sendFailure == nil { screen.showNotice(reason) }
            }
            live.onNotice = { [weak screen] text in screen?.showNotice(text) }
        }
        return screen
    }
}

extension AppModel {
    /// [activity] Until the Settings tab links Chat › Tool Calls, DEBUG builds open it from the chat's ⋯
    /// (docs/spec/1x-activity.md §13).
    static func debugActivityItems(_ screen: ChatViewController) -> [UIMenuElement] {
        #if DEBUG
        return [UIAction(title: "Tool Calls", image: UIImage(systemName: "wrench.and.screwdriver")) { [weak screen] _ in
            guard let screen else { return }
            let page = ToolCallSettings.makeScreen(inSheet: true)   // [mac] Stress test 2026-10-28 round 9: a sheet's rows
            let sheet = ChatSheet.wrap(page, title: "Tool Calls")
            #if targetEnvironment(macCatalyst)
            MacSheetFit.cap(sheet, at: 600)   // [mac-audit K] a medium sheet, not 920 pt of choices
            #endif
            screen.present(sheet, animated: true)
        }]
        #else
        return []
        #endif
    }
}

/// What a chat screen shows if it is asked for while no account is signed in (a tap racing a sign-out).
final class UnavailableChat: ChatSessionModel {
    let title: String
    let profile: String
    let head: JSONValue?
    let messages: [ChatMessage] = []
    let isRunning = false
    let hasOlder = false
    let isLoadingOlder = false
    let connection: ConnectionState = .signedOut(reason: "signed-out")
    let statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?

    init(title: String, profile: String, head: JSONValue?) {
        self.title = title; self.profile = profile; self.head = head
    }

    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
}

/// A weak reference in a collection.
struct WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
