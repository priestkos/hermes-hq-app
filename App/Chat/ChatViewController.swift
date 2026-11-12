import UIKit

/// The chat screen. An inverted table (row 0 = newest, at the bottom) with exact precomputed heights, a glass composer
/// pinned to the keyboard layout guide, and a jump-to-latest button (docs/ARCHITECTURE.md "Feel rules", spec 06).
///
/// Built before the push: `init` lays out the newest screenful synchronously so the first frame of the push already
/// shows the chat. After the push, older rows are measured off the main thread; the table holds only the newest
/// few screens (plus whatever the reader scrolls back to), so every update costs O(shown), not O(chat).
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UITableViewDataSourcePrefetching, ChatCellDelegate {

    let session: any ChatSessionModel

    /// A view drawn left of the name in the title (the bot's head, added at integration). 34 pt.
    var titleAccessoryView: UIView? { didSet { titleView.accessory = titleAccessoryView; sizeTitle(); noteTitleHead() } }

    /// DEBUG: the header head's shape (a dot-matrix head's outline) and eyes as the title's accessibility value (UI tests
    /// check it follows an edit).
    private func noteTitleHead() {
        #if DEBUG
        if let view = titleAccessoryView as? HeadView {
            let head = view.head
            titleView.accessibilityValue = "\(head.theme == .matrix ? head.silhouette.rawValue : head.form.rawValue)/\(head.look.rawValue)"
        }
        #endif
    }
    /// Tapping the title (Bot Info, later).
    var onTitleTap: (() -> Void)? { didSet { titleView.onTap = onTitleTap } }
    /// UX study #121: the "Signed Out" status pill signs in again (OfflineHub.signInAgain).
    var onSignInAgain: (() -> Void)? { didSet { statusPill.onSignIn = onSignInAgain } }
    /// The ⋯ menu; the button shows only when a menu is set.
    var moreMenu: UIMenu? { didSet { updateMoreButton() } }
    /// MENUS (spec 1x): the ⋯ menu's provider, the commands and Models sheets, hold menus (App/Chat/Menus/ChatMenus.swift).
    var menus: ChatMenus?
    /// [mac-layout] The Chat Info rows for the Mac's inspector (set where the Info sheet is made).
    var makeInfoContent: (() -> UIViewController?)?
    /// MENUS: Find in chat, made on first use (App/Chat/Find/ChatFindController.swift).
    private(set) var findController: ChatFindController?
    /// MENUS: the find bar's room under the status line (0 while it is closed).
    private var findInset: CGFloat = 0
    /// MENUS: a find match to bring into view once its row reaches the table.
    private var pendingFindRow: String?
    /// MENUS: Edit's send — the composer's next send goes here instead (true = handled).
    var sendOverride: ((String) -> Bool)?
    /// Swipe to Reply: the quoted lines that lead the next send (its banner sits over the composer); nil when not replying.
    var replyQuote: String?
    /// [keys-return] When a pop-up about to open put the keys down for it (`stowKeys`); its closing brings them back.
    var keysOwedAt: CFTimeInterval?

    let tableView = ChatTableView(frame: .zero, style: .plain)
    let composer = ComposerView()
    /// [attachments] The + menu, the tray and the chat's draft (docs/spec/1x-attachments.md §4, §6); nil when the
    /// session can't send attachments.
    private(set) var attachments: ChatAttachmentsController?
    /// [composer-drawers] The slash / @ drawer above the composer (docs/spec/3x-composer.md §9, §10); nil when this chat
    /// can't complete (not a live chat).
    private(set) var drawer: ComposerDrawerController?
    private let jumpButton = JumpButton()
    private lazy var jumpWidth = jumpButton.widthAnchor.constraint(equalToConstant: ChatMetrics.jumpSize)
    private lazy var statusPillTop = statusPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                                                     constant: ChatMetrics.statusPillTop)
    private lazy var jumpHeight = jumpButton.heightAnchor.constraint(equalToConstant: ChatMetrics.jumpSize)
    #if DEBUG
    private var jumpBegan: CFTimeInterval?
    #endif
    private let queueCard = ChatQueueCard()
    /// The queue card's gap above the composer (0 while it is empty) and its collapsed height.
    private var queueGap: NSLayoutConstraint!
    private var queueCollapsed: NSLayoutConstraint!
    // VOICE (spec 1x-voice): voice memos on this screen — the mic, recorder, draft chip, notice card and tips.
    private(set) lazy var voice = ChatVoiceHost(screen: self)
    /// VOICE: the memo notice card's gap above the queue card and its collapsed height.
    private var noticeGap: NSLayoutConstraint!
    private var noticeCollapsed: NSLayoutConstraint!
    // [transcript] The chat's problem card and the "Couldn’t Send" card (§6.2, §6.3), one column between the queue
    // card and the memo notice. DECISION: they sit directly on the composer's stack (under the memo notice and the
    // activity shelf, which are anchored above them), so the card about the field is the one nearest the field.
    private let earlierPill = ChatEarlierPill()   // §4.2: "Show earlier messages", its spinner, its failure
    private var wasLinkReady = false
    /// The model state and link the composer's model bubble last read (`updateChrome`).
    private var chipModelState: ChatModelState?
    private var chipLinkReady: Bool?
    private let composerNotices = UIStackView()
    private let problemCard = ChatNoticeCard(identifier: "chat.problem")
    private let sendFailureCard = ChatNoticeCard(identifier: "chat.sendFailure")
    private let ownerWaitCard = ChatNoticeCard(identifier: "chat.ownerWait")   // [owner-wait]
    private var composerNoticesGap: NSLayoutConstraint!
    private var composerNoticesCollapsed: NSLayoutConstraint!
    private let titleView = ChatTitleView()
    private let statusPill = ChatStatusPill()
    /// [activity] The shelf, tool-call styles, the fold, In Header and step sheets (App/Chat/Activity/).
    lazy var activity = ChatActivityController(chat: self)
    private let noticeToast = ChatNoticeToast()
    /// [mac] Stress test 2026-10-28 #79: the notice's top: under the status pill, or under the find bar while it shows.
    private var noticeToastTop: NSLayoutConstraint?
    /// What the transcript shows while it has no rows: a skeleton while the open runs (spec 06 §4.2), the reason and
    /// Retry when it failed (spec 03 §4.7), or the bot's intro for an empty chat.
    private let placeholder = ChatPlaceholderView()
    /// [tasks] A page's own content above the first message (`setLead`): the table's footer, at the top of an inverted
    /// table, holding the lead upright.
    private let leadBox = UIView()
    private let leadUpright = UIView()
    private(set) var lead: UIViewController?
    /// [tasks] What stands at the lead box's foot, right above the first message ("Chat with Hermes").
    private(set) var leadFoot: UIViewController?
    /// [tasks] The lead's own height (the page measures it); the box fills the room a short chat leaves.
    var leadHeight: CGFloat = 0 { didSet { if abs(leadHeight - oldValue) > 0.5 { layoutLead() } } }
    private var leadSizeWatch: NSKeyValueObservation?
    private var leadLayoutQueued = false
    /// [tasks] The page opens on the task (the lead's top) and holds it until you scroll, send, jump, find, or write
    /// in the lead; the chat's newest end is a jump or a send away.
    private var leadPinEnded = false
    /// [tasks] The page holds the task's top (the Talk tip waits: its coming moved the newest end, which brought the
    /// jump button, which sent the tip away, round and round under your finger, 2026-11-05). Nor while the task's chat
    /// is empty: the tip lay over where the chat starts.
    var holdsLeadTop: Bool { suppressesTalkTip || (lead != nil && (!leadPinEnded || rows.isEmpty)) }
    /// [tasks] Opens at the newest end, not the task's top: a reply's alert brought you for the reply.
    func opensAtNewest() { leadPinEnded = true }
    /// [tasks] A page's own panel pinned under the bar, outside the transcript (`setTopAccessory`, Pinned Task step 3).
    private(set) var topAccessory: UIViewController?
    private var topAccessoryHeight: NSLayoutConstraint?
    /// Its top, right under the bar: the safe area's top less what the panel itself added to it.
    private var topAccessoryTop: NSLayoutConstraint?
    /// [tasks] You took up the conversation: dragged the transcript, wrote in the composer, sent, or opened Find. The
    /// page with a pinned panel rolls it up to its bar.
    var onEngage: ((ChatEngagement) -> Void)?
    enum ChatEngagement { case drag, send, find }
    /// [tasks] No Talk tip on this page (a task's: the tip lay over its chat's first lines under the pinned task).
    var suppressesTalkTip = false
    /// [tasks] The page's panel covers the whole transcript (a task's whole view, owner 2026-11-08: "I like A"): the
    /// chat's own floating pieces (status line, ↓, earlier pill) stay away until the transcript shows again.
    /// [tasks] What the bar's title says instead of the chat's name: the task's view names its bot there, the task's
    /// own title standing large right under it (owner 2026-11-08: the name had been said twice). nil: the chat's name.
    var titleOverride: String? {
        didSet {
            guard titleOverride != oldValue, isViewLoaded else { return }
            applyState()
        }
    }
    private var shownTitle: String { titleOverride ?? session.title }

    var transcriptCovered = false {
        didSet {
            guard transcriptCovered != oldValue, isViewLoaded else { return }
            // Each pill keeps its own alpha (an empty status line is clear, not a blank capsule): hide, don't fade.
            statusPill.isHidden = transcriptCovered
            if transcriptCovered { earlierPill.set(.hidden) }
            updateJumpButton()
        }
    }
    /// The bar and the status line under it, as one element of the top scroll edge: the fade covers the status
    /// capsule's row and 10 pt more (spec 06 §4.1), from the push's first frame.
    private let topEdgeElement = UIView()
    /// The top edge element's bottom under the status line: further down while a status shows, so the soft edge covers
    /// the whole capsule (verify round 1: it ended mid-capsule and text ran sharp under "Waiting for your reply").
    private var topEdgeBottom: NSLayoutConstraint!
    static let topEdgeBelowStatus: CGFloat = 10
    static let topEdgeBelowShownStatus: CGFloat = 30
    /// A push waiting for this chat's first rows (`push(_:on:limit:done:)`).
    private var readyWaiter: (() -> Void)?
    /// The skeleton is fading out as the first rows fade in.
    private var placeholderHiding = false
    /// The soft top edge during the push (UIKit draws its own only once the push is over).
    private let edgeStandIn = ChatEdgeStandIn()
    /// A still (non-scrolling) scroll view holding the inverted table. The bar's scroll edge effect needs a
    /// scroll view whose top is the screen's top; the flipped table's own top is the screen's bottom.
    private let edgeHost = UIScrollView()
    /// [backdrop] Theme › Chat Background: the person's own picture behind everything, bars and message bar included.
    private let backdrop = BackdropView(place: .chats)
    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-31 #1: the Mac draws no soft edge under the clear bar, so words scrolled under it ran
    /// straight through the bot's name and face. A page-coloured backing behind the bar, fading out 16 pt below it,
    /// comes in once a row reaches under the bar; at rest it is clear (the Bots list's, `EdgeHostScrollView`). The
    /// iPhone keeps its see-through top (owner 2026-10-18), where the system's soft edge does the job.
    private let barBacking = UIView()
    private let barBackingFade = CAGradientLayer()
    /// Owner 2026-11-09 ("Looks too solid?"): over a Chat Background the backing is a soft blur of the picture, not the
    /// page colour (a white band over the picture), fading out under the bar as the iPhone's soft edge does.
    private let barBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let barBlurMask = UIView()
    private let barBlurFade = CAGradientLayer()
    private var barBackingWatch: NSKeyValueObservation?
    /// Owner 2026-11-07 (yes to the polish pass's call): while a notice shows under the bar (the voice banner, "Switching
    /// to …"), the page colour reaches down behind it and fades out 16 pt below, so no half-covered line of the
    /// transcript shows beside it. Only while the transcript reaches under it (over a chat background too, as the bar's).
    private let noticeBacking = UIView()
    private let noticeBackingFade = CAGradientLayer()
    #endif

    // MARK: Rows

    /// Built rows and how many the table shows (see `ChatRowModel`).
    private var model = ChatRowModel()
    /// The table's rows (newest first) and their layouts.
    private var rows: [ChatRow] = []
    private var layouts: [RowLayout] = []
    private var expanded: Set<String> = []
    private var style: ChatStyle
    private var layoutWidth: CGFloat
    private let details: ChatSessionDetails?
    /// The cache scope ("<account>|<profile>|<stored id>").
    let scope: String
    /// This chat's tag in the detailed log: its stored id's, the same tag the chat engine's lines carry.
    var logTag: String { AppLog.tag(scope: scope) }

    private let layoutQueue = DispatchQueue(label: "hq.chat.layout", qos: .userInitiated)
    /// The background fill and chunk builds: one serial utility queue, so they never compete with the main thread
    /// and the render server for every core.
    private let fillQueue = DispatchQueue(label: "hq.chat.fill", qos: .utility)
    private let warmQueue = DispatchQueue(label: "hq.chat.warm", qos: .userInitiated)
    private var layoutInFlight = false
    private var fillInFlight = false
    private var fillGeneration = 0
    private var fillDoneLogged = false
    /// Messages whose rows are built synchronously when the chat opens (the rest follow in the background).
    static let syncBuildMessages = 160
    static let chunkMessages = 500
    static let fillBatch = 120
    /// Above this many rows in the table, updates the reader can't see apply at most five times a second.
    static let heavyTableRows = 1_500

    // MARK: Pending changes (one apply per delivery)

    private var pendingReset = false
    /// A send's own apply: measure here, never on the layout queue (its bubble lands in the frame the field clears).
    private var syncApply = false
    private var pendingTouched: [String] = []
    /// [drafts] The draft answers the rows were last built with (ChatViewController+Drafts.swift).
    var draftAnswersShown: [String: DraftCards.Answer] = [:]
    private var pendingNewest = false
    private var flushScheduled = false
    private var lastApplyTime: CFTimeInterval = 0
    private var throttledApply: Timer?
    private var trimTimer: Timer?
    private var revealing = false

    // MARK: Scrolling state

    /// Pinned to the newest end: growth and new rows keep the end in view.
    private var following = true { didSet { if following != oldValue { updateBottomEdge() } } }
    /// The reply being read from its top (spec 06 §5.3): following stops when its top reaches the bar.
    private var anchorMessageId: String?
    /// A send waits for its reply: the first non-user message after the user message sent at or after
    /// `awaitFromIndex` becomes the anchor (spec 06 §5.3), whatever the running state in between.
    private var awaitingReply = false
    private var awaitFromIndex = 0
    private var lastSendTime: CFTimeInterval = 0
    /// A row to hold in place through the next update (a tapped tool row that opens).
    private var holdRowId: String?
    private var unseen = 0
    private var glideLink: CADisplayLink?
    private var a11yToken: NSObjectProtocol?   // [a11y]
    private var introWatch: NSObjectProtocol?   // [settings] Intro Splash
    private var glideStart: (clock: GlideClock, offset: CGFloat) = (GlideClock(), 0)
    private var lastMomentum: CFTimeInterval = 0
    private(set) var didAppear = false
    /// A chat just started (New Chat, Compose, Command-N): the keys come up with the push, ready for its first message.
    var focusesOnAppear = false
    /// [activity] On screen and not being pushed or popped: the shelf animates its changes (the newest row riding it,
    /// 1x-activity §7.3). During the push they land at once, before the chat is judged (verify round 2: the shelf's
    /// reads answered as the push ended and the transcript glided 150 pt up after it).
    var shelfMayAnimate: Bool { didAppear && transitionCoordinator == nil }
    private var firstContentLogged = false
    /// Observing the session (between `start()` and `stopObserving()`).
    private var attached = false
    /// [questions] The approval card, question dock and password sheets (App/Questions/ChatPromptsController.swift).
    var promptsUI: ChatPromptsController?
    /// [questions] The account's kept password sheets (AppModel.makeChatScreen); nil = this screen keeps its own.
    var promptSheets: PromptSheetStore?
    /// [groups] A room's chrome: reply chip, paused capsule, Stop in the composer, mentions, the hold menu (App/Groups/GroupRoomChrome.swift).
    private(set) var roomChrome: GroupRoomChrome?
    private var promptDock: UIView?
    /// [ipad-polish] When this screen last started a move between the panes (`landedInOtherPane`).
    private var paneMoveTime: CFTimeInterval = 0
    /// [ipad-polish] The pane this screen left tells it "you went away" only when that pane next lays out, which can be
    /// after the screen has already shown in the other pane and `movingBetweenPanes` is cleared. Taken as a real
    /// close, that late word stopped the chat listening: a reply streaming while an iPad's window crossed between
    /// two panes and one (a rotation on a small iPad, Split View, Stage Manager) froze where it was until the chat
    /// was opened again. A screen that is in a stack and in the window just after a move has not gone anywhere.
    private var landedInOtherPane: Bool {
        CACurrentMediaTime() - paneMoveTime < 2 && parent != nil && viewIfLoaded?.window != nil
    }
    /// [m9/ipad] Set while this screen moves between the list stack and the right pane (a window crossing 768 pt):
    /// it stays attached to its session; nothing about the chat ends. Cleared once it shows in the other pane.
    var movingBetweenPanes = false {
        didSet {
            guard movingBetweenPanes else { return }
            paneMoveTime = CACurrentMediaTime()
            // The appearance callbacks of the move arrive later; if none does (the stack is off screen), clear anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.movingBetweenPanes else { return }
                self.movingBetweenPanes = false
                // Dropped without a pop meanwhile (the tabs rebuilt for another gateway, sign-out): it ends here.
                if self.parent == nil { self.detach() } else if self.isViewLoaded { self.attach() }
            }
        }
    }
    /// [m9/ipad] The readable column (ReadableColumn): the pane's width up to 760 pt, centred.
    let columnGuide = UILayoutGuide()
    /// [m9/ipad] A question or approval is waiting in the dock (Escape never answers or dismisses it).
    var questionWaiting: Bool { promptDock != nil }
    private var promptQueueGap: NSLayoutConstraint?
    /// [questions] While a dock shows, the stack above it (queue card, memo notice, activity shelf) stops under the status
    /// line and the dock gives up the height (owner 2026-11-01: a long question pushed "Using its browser" up under
    /// "Waiting for your reply").
    private var promptStackTop: NSLayoutConstraint?
    private weak var promptChip: UIView?
    private var promptGapPending = false

    // MARK: Init

    init(session: any ChatSessionModel) {
        self.session = session
        details = session as? ChatSessionDetails
        scope = details?.layoutScope ?? "\(session.profile)|\(session.title)"
        let category = UIApplication.shared.preferredContentSizeCategory
        style = ChatStyleCache.shared.style(for: category)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // [m9/ipad] In a pane or a resized window the first screen is laid out for the pane, not the device's screen.
        let screen = Self.openingSize ?? scene?.screen.bounds.size ?? CGSize(width: 402, height: 874)
        layoutWidth = ReadableColumn.fit(pane: screen.width).width   // [m9/ipad] at most the readable column
        TextLayout.screenHeight = screen.height
        super.init(nibName: nil, bundle: nil)
        ChatCaches.installObservers()
        hidesBottomBarWhenPushed = true
        navigationItem.largeTitleDisplayMode = .never
        ChatPerf.mark("chat.init.start")
        model.rebuildAll(input(), syncMessages: Self.syncBuildMessages, oldestShown: nil)
        ChatPerf.mark("chat.init.rowsBuilt \(model.allRows.count) of \(session.messages.count) messages")
        layoutInitialScreen(height: screen.height)
        ChatPerf.mark("chat.init.end rows=\(rows.count)/\(model.allRows.count)")
        AppLog.trace("chatui", "open \(logTag): \(rows.count) rows shown first")
        #if DEBUG
        rowsAtInit = rows.count
        #endif
    }

    #if DEBUG
    /// UI tests read how soon the chat showed content: `first-content-ms=<ms from init to the first cell>;rows-at-init=<n>`
    /// on the table's accessibility value (rows at init > 0: painted from the cache before the push).
    private let createdAt = CACurrentMediaTime()
    private var rowsAtInit = 0
    private var firstCellNoted = false

    private func noteFirstCell() {
        guard !firstCellNoted else { return }
        firstCellNoted = true
        let ms = (CACurrentMediaTime() - createdAt) * 1000
        tableView.accessibilityValue = String(format: "first-content-ms=%.0f;rows-at-init=%d", ms, rowsAtInit)
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let deliveryObserver { DeliveryRoster.stopObserving(deliveryObserver) }   // [groups]
        if let themeWatch { NotificationCenter.default.removeObserver(themeWatch) }   // [desktoplook]
        if let backdropWatch { NotificationCenter.default.removeObserver(backdropWatch) }   // [backdrop]
        if let muteWatch { BotMuteCenter.shared.stopObserving(muteWatch) }   // UX study #248
        if let a11yToken { NotificationCenter.default.removeObserver(a11yToken) }   // [a11y]
        if let introWatch { NotificationCenter.default.removeObserver(introWatch) }   // [settings]
        filesWatch.forEach { NotificationCenter.default.removeObserver($0) }   // [settings]
        if attached {
            session.onChange = nil
            (session as? ChatQueueing)?.endQueuedEdit()   // [composer] a held queued row goes on with the queue
            session.stopObserving()
        }
        throttledApply?.invalidate()
        trimTimer?.invalidate()
        reconnectWordsTimer?.invalidate()   // [connect-fast]
        promptsUI?.uninstall()   // [questions] its timers stop; a sheet it shows is tucked, kept by the account
    }

    /// Pays the first-use costs (fonts, TextKit, the markdown parser, a text view, glass) ahead of the first chat
    /// open. Call once after launch, when the first screen is up. The text work runs in the background; the
    /// main-thread part (mostly the first keyboard layout guide, ~100 ms) waits until the app is idle: its timer runs
    /// in the default run loop mode, which doesn't run while a finger scrolls.
    static func prewarm() {
        ChatCaches.installObservers()
        let category = UIApplication.shared.preferredContentSizeCategory
        DispatchQueue.global(qos: .utility).async {
            let style = ChatStyleCache.shared.style(for: category)
            let sample = "**Hi** _there_ `code` https://example.com\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |"
            for theme in [MarkdownTheme.bot, .me] {
                for block in MarkdownRenderer.render(sample, style: style, theme: theme).blocks {
                    switch block {
                    case .text(let t), .quote(let t, _), .code(_, _, let t, _): _ = TextKitLayout(t, width: 300)
                    case .table(let t): t.header.forEach { _ = TextKitLayout($0, width: nil) }
                    case .spacer, .media, .linkChip, .pageCard: break
                    }
                }
            }
            _ = ChatRunSummary.summarize([ToolCall(id: "w", name: "terminal", title: "terminal", argsText: #"{"command":"ls"}"#,
                                                   summary: nil, state: .done, durationSeconds: nil)], live: false)
            _ = ChatRowBuilder.clock(Date())
        }
        idle(after: 0.6) {
            let started = CACurrentMediaTime()
            defer {
                #if DEBUG
                print(String(format: "[ChatPerf] prewarm idle part (keyboard guide) %.1f ms", (CACurrentMediaTime() - started) * 1000))
                #endif
            }
            // The first keyboard layout guide in a process costs ~100 ms (keyboard tracking starts up); pay it now, in
            // an invisible view of the key window, instead of on the first chat push.
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            if let window {
                let probe = UIView(frame: window.bounds)
                probe.isHidden = true
                probe.isUserInteractionEnabled = false
                window.addSubview(probe)
                let pin = UIView()
                pin.translatesAutoresizingMaskIntoConstraints = false
                probe.addSubview(pin)
                NSLayoutConstraint.activate([
                    pin.bottomAnchor.constraint(equalTo: probe.keyboardLayoutGuide.topAnchor),
                    pin.leadingAnchor.constraint(equalTo: probe.leadingAnchor),
                    pin.widthAnchor.constraint(equalToConstant: 1),
                    pin.heightAnchor.constraint(equalToConstant: 1),
                ])
                probe.layoutIfNeeded()
                DispatchQueue.main.async { probe.removeFromSuperview() }
            }
            idle(after: 0.05) {
                let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 40))
                composer.text = "warm"
                composer.layoutIfNeeded()
                composer.text = ""
                let title = ChatTitleView()
                title.title = "Hermes"
                title.layoutIfNeeded()
                _ = JumpButton()
            }
        }
    }

    /// Runs `work` after `delay` once the main run loop is in its default mode (not while a finger scrolls).
    private static func idle(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(timer, forMode: .default)
    }

    var botName: String { details?.botName ?? session.title }

    /// [groups] The transcript on screen has a delivery (a roster change re-resolves its sender), and the watch for one.
    private var showsDeliveries = false
    private var deliveryObserver: UUID?

    /// Background reports made readable, by note id (`input()` runs on every streamed flush).
    private var backgroundResultCache: [String: String] = [:]
    /// /btw answers already opened as they landed (once: one closed stays closed).
    private var openedAsides: Set<String> = []

    private func input() -> ChatRowBuilder.Input {
        // [groups] A delivery from another bot draws as that bot's incoming bubble (docs/spec/3x-groups.md §7.12).
        var messages = session.messages
        if !(session is ChatRoomSurface) {
            let resolved = DeliveryMessages.resolve(messages, roster: DeliveryRoster.seats)
            messages = resolved.messages
            showsDeliveries = resolved.found
            // [transcript] Cron deliveries speak as the job's bot, timeline notes read in words, one card per failed
            // turn (docs/spec/3x-transcript.md §2.1, §2.2, §2.20). Display-time only: positions are kept.
            let own = DeliveryRoster.seats.first { $0.profile == session.profile }
                ?? DeliveryMessages.Seat(profile: session.profile, name: botName, head: session.head)
            // [botdm] A message this bot sent another comes back as that bot's reply, not a background process note.
            let dms = BotDMs.resolve(messages, roster: DeliveryRoster.seats)
            let cron = CronDeliveries.resolve(dms.messages, roster: DeliveryRoster.seats, own: own)
            messages = TurnErrors.withoutDuplicateTurnErrors(TimelineNotes.resolve(cron.messages))
            showsDeliveries = showsDeliveries || cron.found || dms.found
        }
        // A /btw answer is what was asked for: its row opens as it lands (SideTasks.swift).
        for m in messages where m.role == .system && SideTaskRow.opensByItself(m) && openedAsides.insert(m.id).inserted {
            expanded.insert("\(m.id)|bg")
        }
        // [owner-wait] A send waiting for another Hermes run hasn't reached the model: no "Waiting for <model>" row.
        let ownerWaiting = (session as? ChatComposerNotices)?.ownerWaitKind != nil
        // [external-turn] Another Hermes process's turn draws as one of ours: the waiting capsule, live steps, no
        // action row under a reply that isn't finished (docs/spec/03-chat-history.md §4.8).
        let externalWorking = (session as? ChatExternalWork)?.externalWorking == true
        var input = ChatRowBuilder.Input(messages: messages, isRunning: (session.isRunning || externalWorking) && !ownerWaiting,
                                         botName: botName, expanded: expanded,
                                         now: Date(), scope: scope, modelName: details?.modelName,
                                         prompts: promptsUI?.rowsInput)   // [questions]
        input.media = (session as? ChatAttachmentSending)?.mediaSnapshot ?? .empty             // [attachments]
        #if DEBUG
        if let demo = ChatDemo.pageContext { input.media.context = demo }   // -HQDemoPage: page cards read this Mac's disk
        #endif
        input.ownFace = ChatSender(key: session.profile, name: input.speakerName, head: session.head,
                                   profile: session.profile, colorHex: nil)
        // [transcript] §6.6: the newest reply's turn duration (the action row sits under that reply only).
        if let marks = session as? ChatTurnMarks, let at = ActivityRows.latestReplyIndex(messages), messages[at].role == .assistant,
           let seconds = marks.turnSeconds(messages[at].id) {
            input.turnSeconds = [messages[at].id: seconds]
        }
        input.activity = activity.rowsInput()                                                  // [activity]
        input.bots = DeliveryRoster.seats                                                      // [botdm]
        input.drafts = DraftEdits.shared.rowsInput(messages, queued: draftQueuedTexts, scope: scope)                      // [drafts]
        input.fewerTimes = ToolCallSettings.fewerTimestamps
        input.externalWorking = externalWorking && !ownerWaiting                                // [external-turn]
        if let source = session as? ChatBackgroundResultSource {
            for m in messages where m.role == .system {
                if let shown = backgroundResultCache[m.id] { input.backgroundResults[m.id] = shown; continue }
                guard let report = source.backgroundResult(m.id), !ChatText.trimmed(report).isEmpty else { continue }
                let shown = BackgroundResults.readable(report)
                backgroundResultCache[m.id] = shown
                input.backgroundResults[m.id] = shown
            }
        }
        if let room = session as? ChatRoomSurface {                                            // [groups]
            input.room = RoomRowsInput(typing: room.typing, undelivered: room.undelivered, retrying: room.retrying)
        }
        // [transcript] An edit call's diff, for the files card and its inline preview (§12, n20 F10); not kept on the
        // message itself, so it's read fresh off the session each build (as the step sheet's own Changes panel does).
        if let tools = session as? ChatToolDetails {
            for m in messages where m.role == .assistant {
                for part in m.parts {
                    guard case .tool(let call) = part, call.state == .done, ChangedFiles.isEditTool(call.name),
                          let diff = tools.toolDetail(messageId: m.id, toolId: call.id)?.inlineDiff, !diff.isEmpty else { continue }
                    input.diffs[call.id] = diff
                }
            }
        }
        return input
    }

    /// Lays out the newest rows until they fill 1.5 screens, synchronously, and shows them; the rest wait hidden.
    /// [perf] On a cold cache, uncached text past `initialMeasureBudget` stops it as soon as the screen itself is
    /// covered (a chat whose newest replies are big code dumps would measure all of them before the push); the fill
    /// measures the rest off the main thread after the push.
    private func layoutInitialScreen(height: CGFloat) {
        var total: CGFloat = 0
        var made: [RowLayout] = []
        var uncachedCost = 0
        let all = model.allRows
        let budget = height * 1.5
        while made.count < all.count && (total < budget || (made.count < 12 && uncachedCost < Self.initialMeasureBudget)) {
            let row = all[made.count]
            if TextLayout.cached(row, width: layoutWidth, style: style) == nil {
                uncachedCost += Self.measureCost(row)
                if !made.isEmpty && total >= height && uncachedCost > Self.initialMeasureBudget { break }
            }
            let l = TextLayout.layout(row, width: layoutWidth, style: style, keep: true)
            made.append(l)
            total += l.height
        }
        model.reveal(made.count - model.shownCount)
        rows = Array(model.shown)
        layouts = made
        // [perf] A cache hit offers nothing to the draw pool (only measuring does), so after a background trim the
        // first screen's cells would build their TextKit on main during the push: build it on the warm queue now.
        warm(rows: Array(made.indices))
    }

    /// Uncached text (in `measureCost` units) the opening screen measures synchronously past the visible height.
    static let initialMeasureBudget = 24_000

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        let span = MainTrail.begin("chat.load")           // [diagnostics] build 292
        defer { MainTrail.end(span) }
        ChatPerf.mark("chat.viewDidLoad")
        applyChatColour()   // [bot-colour] before the first row is drawn
        watchChatColour()
        view.backgroundColor = ChatPalette.page
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(backdrop, at: 0)

        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
        tableView.accessibilityIdentifier = "chat.table"
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.keyboardDismissMode = .interactive
        tableView.showsVerticalScrollIndicator = true
        // The scroll bar's insets are the chat's own (`updateInsets`): the system's extra kept it ~120 pt short of
        // the newest end (owner 2026-11-01).
        tableView.automaticallyAdjustsScrollIndicatorInsets = false
        tableView.allowsSelection = false
        tableView.delaysContentTouches = false
        // A status-bar tap would scroll the flipped table to its own top: the newest end. Off.
        tableView.scrollsToTop = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.reuse)
        tableView.register(ChatToolCell.self, forCellReuseIdentifier: ChatToolCell.reuse)
        tableView.register(ChatLineCell.self, forCellReuseIdentifier: ChatLineCell.reuse)
        tableView.register(ChatErrorCell.self, forCellReuseIdentifier: ChatErrorCell.reuse)
        tableView.register(ChatWaitingCell.self, forCellReuseIdentifier: ChatWaitingCell.reuse)
        tableView.register(ChatActionsCell.self, forCellReuseIdentifier: ChatActionsCell.reuse)
        tableView.register(ChatPromptCell.self, forCellReuseIdentifier: ChatPromptCell.reuse)   // [questions]
        tableView.register(ChatReactionsCell.self, forCellReuseIdentifier: ChatReactionsCell.reuse)
        tableView.register(UpdateMemberCell.self, forCellReuseIdentifier: UpdateMemberCell.reuse)   // [updates]
        // [activity] Here, not only in `activity.install`: the rows (a subagent card among them) exist from init, and
        // a layout before the install asked for a cell nobody had registered (build 294 crash, chat opened from a
        // notification).
        ActivityCells.register(in: tableView)
        // The table is flipped, so its own top edge effect sits at the screen's bottom: that one is the composer's
        // fade (sized by the visual-bottom inset). The bar's fade comes from `edgeHost`, an unflipped still scroll
        // view around the table (spec 06 §4.1, §4.3: the system scroll edge effect at both ends).
        tableView.topEdgeEffect.isHidden = true
        tableView.bottomEdgeEffect.isHidden = true
        edgeHost.isScrollEnabled = false
        edgeHost.contentInsetAdjustmentBehavior = .never
        edgeHost.showsVerticalScrollIndicator = false
        edgeHost.scrollsToTop = false
        // The host follows the keyboard (so its bottom edge effect sits behind the composer); the table inside it
        // keeps the view's full size and shows through behind the keyboard.
        edgeHost.clipsToBounds = false
        // [chat-soft-edge] Owner 2026-11-05: chats keep the soft fade whatever Theme › Themes › Top Edge says. The bar
        // here is three glass pills over the transcript; a frosted band behind them took an eighth of the screen from
        // the conversation (as Messages, WhatsApp and Telegram, which fade instead). Tabs still follow the setting.
        edgeHost.topEdgeEffect.style = .soft
        edgeHost.bottomEdgeEffect.style = .soft
        // [desktop-glass-sweep] The chat keeps its soft edges in the Desktop Look too (owner 2026-10-18: the top and
        // bottom of chats see-through "like it used to be", as the look's bar has been since 2026-10-13).
        DesktopEdges.leaveAlone(edgeHost)
        edgeHost.addSubview(tableView)
        view.addSubview(edgeHost)
        setContentScrollView(edgeHost, for: .top)
        #if targetEnvironment(macCatalyst)
        barBacking.isUserInteractionEnabled = false
        barBacking.alpha = 0
        barBacking.accessibilityIdentifier = "chat.barBacking"
        barBackingFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        barBacking.layer.mask = barBackingFade
        view.insertSubview(barBacking, aboveSubview: edgeHost)
        barBlur.isUserInteractionEnabled = false
        barBlur.alpha = 0
        barBlur.accessibilityIdentifier = "chat.barBlur"
        barBlurFade.colors = barBackingFade.colors
        barBlurMask.layer.addSublayer(barBlurFade)
        barBlur.mask = barBlurMask
        view.insertSubview(barBlur, aboveSubview: barBacking)
        barBackingWatch = tableView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateBarBacking() }
        }
        noticeBacking.isUserInteractionEnabled = false
        noticeBacking.alpha = 0
        noticeBacking.accessibilityIdentifier = "chat.noticeBacking"
        noticeBackingFade.colors = barBackingFade.colors
        noticeBacking.layer.mask = noticeBackingFade
        view.insertSubview(noticeBacking, aboveSubview: barBlur)   // under the status line and the notice, added later
        noticeToast.onShowingChange = { [weak self] in
            self?.view.setNeedsLayout()
            self?.updateBarBacking()
        }
        #endif
        // The top edge's own element: the bar region down to 10 pt under the status line. With it the soft edge is
        // drawn by the still host from the first frame (it doesn't wait for the bar to adopt the scroll view at the
        // end of the push), and it reaches past the status capsule so no transcript text runs sharp beside it.
        topEdgeElement.isUserInteractionEnabled = false
        topEdgeElement.backgroundColor = .clear
        view.addSubview(topEdgeElement)
        edgeStandIn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edgeStandIn)
        let topEdge = UIScrollEdgeElementContainerInteraction()
        topEdge.scrollView = edgeHost
        topEdge.edge = .top
        topEdgeElement.addInteraction(topEdge)
        placeholder.isHidden = true
        placeholder.onRetry = { [weak self] in self?.retryOpen() }
        // [talk] the intro's capsules (§5.6); Talk with the composer's light tap
        placeholder.onTalk = { [weak self] in Haptics.play(.light); self?.beginTalk() }
        placeholder.onInfo = { [weak self] in self?.voice.talkShowBotInfo() }   // [talk]
        placeholder.onName = { [weak self] in
            guard let self else { return }
            AppLog.trace("chatui", "intro Name Chat tapped \(self.logTag)")
            self.menus?.promptRename()
        }
        view.addSubview(placeholder)

        // The model panel, left open from before the message, closes on its send (tester, 2026-11-06).
        composer.onSend = { [weak self] text in
            self?.menus?.closeModelPanel()
            self?.send(text)
        }
        composer.onStop = { [weak self] in
            guard let self else { return }
            AppLog.trace("composer", "stop tapped \((self.logTag))")
            if let roomChrome = self.roomChrome { roomChrome.stop(); return }   // [groups] Stop All, with its alert
            self.session.stop()
        }
        composer.shouldBeginEditing = { [weak self] in self?.composerMayFocus() ?? true }
        composer.onHeightChange = { [weak self] in
            guard let self, self.view.window != nil else { return }
            // [a11y] The composer growing a line moves the transcript: at once under Reduce Motion.
            HQMotion.animate(0.2, changes: { self.view.layoutIfNeeded() })
        }
        view.addSubview(composer)
        attachments = ChatAttachmentsController.make(for: self)                                   // [attachments]
        sendHasAttachments = { [weak self] in self?.attachments?.hasAttachments == true }       // MENUS × [attachments]
        // The composer row is the bottom edge's element: the system fades the transcript under it (`updateBottomEdge`).
        let composerEdge = UIScrollEdgeElementContainerInteraction()
        composerEdge.scrollView = edgeHost
        composerEdge.edge = .bottom
        composer.addInteraction(composerEdge)

        queueCard.isHidden = true
        queueCard.canSendNow = { [weak self] item in
            guard let q = self?.session as? ChatQueueing else { return true }
            return !q.isReplyRunning || q.canSteer(item.id)      // busy and not steerable: only Stop and Send (⋯)
        }
        // A send from the card closes the model panel as the composer's Send does (the card sits above the panel).
        queueCard.onSendNow = { [weak self] id in
            guard let q = self?.session as? ChatQueueing else { return }
            if q.isReplyRunning {
                // Busy: only a steerable row, once (a second tap while the first is out must not become Stop and Send).
                guard q.canSteer(id) else { return }
                self?.menus?.closeModelPanel()
                Task { @MainActor in _ = await q.steerQueued(id) }
            } else {
                self?.menus?.closeModelPanel()
                q.sendQueuedNow(id)
            }
        }
        queueCard.onStopAndSend = { [weak self] id in
            self?.menus?.closeModelPanel()
            (self?.session as? ChatQueueing)?.sendQueuedNow(id)
        }
        // Delete throws the row away (its photos, files and memo with it); Edit changes its words in place (spec §15.5).
        queueCard.onDelete = { [weak self] id in self?.deleteQueued(id) }
        queueCard.canEdit = { [weak self] item in (self?.session as? ChatQueueing)?.canEditQueued(item.id) ?? false }
        queueCard.onEdit = { [weak self] id in self?.beginQueueEdit(id) }
        composer.onHardwareReturnEmpty = { [weak self] in self?.hardwareReturnInEmptyField() }
        // [m9/composer] Resume on a paused queue (docs/spec/3x-composer.md §16).
        queueCard.onResume = { [weak self] in (self?.session as? ChatQueueResuming)?.resumeQueue() }
        // Show N More / Show Less: the card grows or shrinks in place; the dock above it and the insets follow.
        queueCard.onResize = { [weak self] in
            guard let self else { return }
            let apply = { self.view.layoutIfNeeded() }
            if self.view.window != nil && !HQMotion.reduced {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply) { _ in self.updateInsets() }   // motion-ok: off under Reduce Motion
            } else {
                apply(); self.updateInsets()
            }
        }
        view.addSubview(queueCard)
        installComposerNotices()        // [transcript]
        let memoNotice = voice.notice   // VOICE
        view.addSubview(memoNotice)
        jumpButton.onTap = { [weak self] in
            guard let self else { return }
            if self.jumpButton.approvalMode { self.jumpToApproval() } else { self.jumpToLatest() }
        }
        jumpButton.onSizeChange = { [weak self] in
            guard let self else { return }
            self.jumpWidth.constant = self.jumpButton.preferredWidth
            self.jumpHeight.constant = self.jumpButton.preferredHeight
            self.activity.jumpWidthChanged(self.jumpButton.preferredWidth)   // [activity] the capsule may crowd a chip
            self.view.setNeedsLayout()
        }
        view.addSubview(jumpButton)
        view.addSubview(statusPill)
        installEarlierPill()            // [transcript] under the toast
        view.addSubview(noticeToast)

        let guide = view.keyboardLayoutGuide
        guide.usesBottomSafeArea = false
        edgeHost.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        queueCard.translatesAutoresizingMaskIntoConstraints = false
        queueGap = queueCard.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: 0)
        queueCollapsed = queueCard.heightAnchor.constraint(equalToConstant: 0)
        memoNotice.translatesAutoresizingMaskIntoConstraints = false   // VOICE
        composerNoticesGap = composerNotices.bottomAnchor.constraint(equalTo: queueCard.topAnchor, constant: 0)   // [transcript]
        composerNoticesCollapsed = composerNotices.heightAnchor.constraint(equalToConstant: 0)
        noticeGap = memoNotice.bottomAnchor.constraint(equalTo: composerNotices.topAnchor, constant: 0)
        noticeCollapsed = memoNotice.heightAnchor.constraint(equalToConstant: 0)
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        noticeToast.translatesAutoresizingMaskIntoConstraints = false
        topEdgeElement.translatesAutoresizingMaskIntoConstraints = false
        // Glass bottom: 29 pt above the screen bottom with the keyboard down, 8 pt above the keys with it up. Both
        // limits are required inequalities; a weaker equality pulls the row down to whichever is higher, so the row
        // waits for the rising keyboard to reach it and then rides on top of it.
        let followKeys = composer.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -ChatMetrics.composerBottomUp)
        followKeys.priority = .defaultHigh
        let aboveKeys = composer.bottomAnchor.constraint(lessThanOrEqualTo: guide.topAnchor, constant: -ChatMetrics.composerBottomUp)
        keysGaps = [followKeys, aboveKeys]
        // VOICE: above the memo notice card (which sits on the queue card; collapsed it is the queue card's top).
        // [activity] The shelf moves it above the shelf when a card is open (ChatActivityController adjusts the constant).
        topEdgeBottom = topEdgeElement.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: Self.topEdgeBelowStatus)
        let jumpAboveQueue = jumpButton.bottomAnchor.constraint(equalTo: memoNotice.topAnchor, constant: -ChatMetrics.jumpAboveComposer)
        // [questions] gives way to the top limit below. Under the docked views' own resistance to being squashed (750):
        // at a tie a tall shelf + queue card + keyboard let the button's top limit squash the composer and the queue
        // card instead (verify round 1: the field dropped half under the keys while Stop stayed put).
        jumpAboveQueue.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue - 10)
        for docked in [composer, queueCard, memoNotice, composerNotices] as [UIView] {
            docked.setContentCompressionResistancePriority(UILayoutPriority(UILayoutPriority.defaultHigh.rawValue + 10), for: .vertical)
        }
        [queueCard, memoNotice, composerNotices].forEach(ThemeChrome.followCorners)   // [desktop-corners]
        // Verify round 2: the cards docked above the composer (queue card, memo notice, the activity shelf) share the
        // row's side edges (26 pt resting, 8 pt over the keys or beside the question dock), as one column.
        dockSides = [queueCard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ChatMetrics.composerSideDown),
                     view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: queueCard.trailingAnchor, constant: ChatMetrics.composerSideDown),
                     memoNotice.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ChatMetrics.composerSideDown),
                     view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: memoNotice.trailingAnchor, constant: ChatMetrics.composerSideDown),
                     composerNotices.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ChatMetrics.composerSideDown),
                     view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: composerNotices.trailingAnchor, constant: ChatMetrics.composerSideDown)]
        NSLayoutConstraint.activate(dockSides)
        // [m9/ipad] The readable column: the pane's width up to 760 pt, centred. The jump button, the question dock
        // and the Find bar keep to it (on a phone it is the whole view).
        view.addLayoutGuide(columnGuide)
        let columnFill = columnGuide.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor)   // [duo] clear of the side column
        columnFill.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([columnGuide.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor), columnFill,
                                     columnGuide.widthAnchor.constraint(lessThanOrEqualToConstant: ReadableColumn.maxWidth),
                                     columnGuide.topAnchor.constraint(equalTo: view.topAnchor)])
        edgeHostBottom = edgeHost.bottomAnchor.constraint(equalTo: guide.topAnchor)
        NSLayoutConstraint.activate([
            edgeHost.topAnchor.constraint(equalTo: view.topAnchor),
            edgeHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edgeHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edgeHostBottom,
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            composer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -ChatMetrics.composerBottomDown),
            aboveKeys,
            followKeys,
            jumpWidth,
            jumpHeight,
            // [mac] In a wide window the arrow at the trailing edge sat on the end of the owner's own bubbles (they
            // hug that edge); a Mac chat puts it in the middle, over the message box.
            DeviceWord.isMac ? jumpButton.centerXAnchor.constraint(equalTo: columnGuide.centerXAnchor)
                : jumpButton.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor, constant: -ChatMetrics.jumpTrailing),
            queueGap, queueCollapsed,
            // VOICE: the memo notice card sits on top of the dock; the jump button above it.
            noticeGap, noticeCollapsed,
            composerNoticesGap, composerNoticesCollapsed,
            jumpAboveQueue,
            // [questions] A tall question dock (AX sizes, many choices) can't push it up over the bar and status line.
            jumpButton.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                                            constant: ChatMetrics.statusLineHeight + 8),
            statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusPillTop,
            statusPill.heightAnchor.constraint(equalToConstant: ChatMetrics.statusLineHeight),
            noticeToast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noticeTop(under: statusPill),
            noticeToast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            topEdgeElement.topAnchor.constraint(equalTo: view.topAnchor),
            topEdgeElement.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topEdgeElement.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topEdgeBottom,
            edgeStandIn.topAnchor.constraint(equalTo: view.topAnchor),
            edgeStandIn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edgeStandIn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edgeStandIn.bottomAnchor.constraint(equalTo: topEdgeElement.bottomAnchor),
        ])

        applyChatLook()

        titleView.title = shownTitle
        let owner = botName.trimmingCharacters(in: .whitespaces)
        titleView.subtitle = owner.isEmpty || owner == shownTitle.trimmingCharacters(in: .whitespaces) ? nil : owner
        titleView.onTap = onTitleTap
        titleView.onSizeChange = { [weak self] in self?.sizeTitle() }
        sizeTitle()
        updateMoreButton()
        applyState()

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: ChatViewController, _) in
            vc.style = ChatStyleCache.shared.style(for: vc.traitCollection.preferredContentSizeCategory)
            vc.relayoutEverything(reason: "text size changed")
            vc.titleView.setNeedsLayout()
            vc.sizeTitle()
        }
        // UX study #248: muting the bot (here, in Bot Info, on the Bots list) or its mute running out: the title's bell.
        muteWatch = BotMuteCenter.shared.observe { [weak self] in self?.updateTitleMute() }
        updateTitleMute()
        // [desktoplook] A theme change that moves text (the look, UI Scale, the skin's typeface, High Contrast's reply
        // boxes) lays the chat out again, as a Dynamic Type change does. A skin change is colours only: a redraw.
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] note in
            let layout = (note.userInfo?["layout"] as? Bool) ?? true
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyChatColour()   // [bot-colour] Chat Bubbles › Colour moved to or from Bot's Face
                self.applyChatLook()
                if layout {
                    self.style = ChatStyleCache.shared.style(for: self.traitCollection.preferredContentSizeCategory)
                    self.relayoutEverything(reason: "theme changed")
                    self.titleView.themeChanged()   // Mac polish #80
                    self.statusPill.themeChanged()   // [ui-sizing] its words kept the old UI Scale
                    self.sizeTitle()
                } else {
                    self.tableView.reloadData()
                }
            }
        }
        // [backdrop] A chat background set or removed: the lines on the page put on or take off their glass pills.
        backdropWatch = NotificationCenter.default.addObserver(forName: Backdrop.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tableView.reloadData()
                self?.placeholder.setNeedsLayout()
            }
        }
        watchFileBrowser()   // [settings] the Files bar button follows the switch and the chat's folder
        // [settings] Intro Splash switched while this chat is open: the empty chat follows at once.
        introWatch = NotificationCenter.default.addObserver(forName: IntroSplash.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlaceholder(animated: false) }
        }
        // [a11y] Bold Text flipped while the chat is open: the drawn text is re-measured with the other weights.
        a11yToken = NotificationCenter.default.addObserver(forName: HQAccessibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Either the app's own step (the DEBUG switch, or a system that leaves drawn text alone) or the
                // system's heavier fonts changed: both change every measured width.
                let next = ChatStyleCache.shared.style(for: self.traitCollection.preferredContentSizeCategory)
                guard next.bold != self.style.bold || next.body != self.style.body else { return }
                ChatCaches.clearAll()
                self.style = next
                self.relayoutEverything(reason: "bold text changed")
            }
        }

        // [activity] The shelf (subagents, goal, previous tasks) above the queue card and the memo notice. Before the
        // prompts: a tucked prompt's chip sits over the shelf.
        activity.install(queueCard: queueCard, jumpBottom: jumpAboveQueue, statusAnchor: view.safeAreaLayoutGuide.topAnchor,
                         shelfBase: voice.notice)
        // [questions] Approvals, questions and password prompts (spec 1x §4).
        if let prompting = session as? ChatPrompting {
            let ui = ChatPromptsController(chat: self, prompting: prompting, sheets: promptSheets)
            promptsUI = ui
            ui.install()
        }
        // [groups] After the prompts: its dock gives way to the question dock.
        if let room = session as? ChatRoomSurface {
            let chrome = GroupRoomChrome(chat: self, room: room)
            roomChrome = chrome
            chrome.install(jumpButton: jumpButton)
        }
        tableView.reloadData()
        if lead != nil { installLead() }   // [tasks]
        attach()
        updatePlaceholder(animated: false)
        voice.onNoticeChange = { [weak self] shown in self?.setMemoNotice(shown: shown) }   // VOICE
        voice.install()
        installDrawer()   // [composer-drawers]
        ChatPerf.mark("chat.viewDidLoad.end")
    }

    // MARK: Opening (push hold, skeleton, failure)

    private var openPhase: ChatOpenPhase { (session as? ChatOpenStatus)?.openPhase ?? .open }

    /// Pushes a chat screen. One with rows (painted from the cache) goes at once. One with nothing to paint yet is
    /// loaded first, so its open starts, and pushed as soon as its first rows land or its open ends, at most `limit`
    /// later: the push never slides in blank (Telegram holds a chat's push the same way). Past the limit it slides in
    /// with its skeleton. `done` runs once it is pushed.
    static func push(_ screen: UIViewController, on navigation: UINavigationController, limit: TimeInterval = 0.35,
                     done: @escaping () -> Void) {
        // [m9/ipad] Next / Previous Chat in the phone layout: the new chat takes the place of the one on show in one
        // step (the list never flashes between them).
        let replace = replacesTopOnNextPush
        replacesTopOnNextPush = false
        let place: (UINavigationController, UIViewController) -> Void = { navigation, screen in
            if replace, let list = navigation.viewControllers.first, navigation.viewControllers.count > 1 {
                navigation.setViewControllers([list, screen], animated: false)
            } else {
                navigation.pushViewController(screen, animated: true)
            }
        }
        guard let chat = screen as? ChatViewController, chat.rows.isEmpty, chat.openPhase == .opening else {
            place(navigation, screen)
            done()
            return
        }
        // Held strongly until it fires (≤ `limit`): nothing else holds the screen before the push.
        let go: () -> Void = { [chat, weak navigation] in
            guard chat.readyWaiter != nil else { return }
            chat.readyWaiter = nil
            ChatPerf.mark("chat.push rows=\(chat.rows.count)")
            if let navigation { place(navigation, chat) }
            done()
        }
        chat.readyWaiter = go
        chat.loadViewIfNeeded()
        if !chat.rows.isEmpty || chat.openPhase != .opening { go(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { go() }
    }

    /// Nothing shows yet, but rows are on their way: the open runs, or messages are in and their rows are still being
    /// built or measured (they reach the table on the next apply).
    private var awaitingRows: Bool {
        guard rows.isEmpty else { return false }
        if openPhase == .opening { return true }
        if session.messages.isEmpty { return false }
        return flushScheduled || layoutInFlight || pendingReset || !pendingTouched.isEmpty || !model.allRows.isEmpty
    }

    /// A held push goes now (the first rows are in, or the open ended with nothing to show).
    private func pushIfWaiting() {
        guard readyWaiter != nil, !awaitingRows else { return }
        readyWaiter?()
    }

    private func retryOpen() {
        session.start()
        updatePlaceholder(animated: true)
    }

    /// The empty chat's intro: Talk and Bot Info (§5.6), and Name Chat while the chat is still unnamed.
    private func emptyIntro() -> ChatPlaceholderView.Intro {
        var intro = voice.talkIntro()
        intro.name = menus?.canName ?? false
        return intro
    }

    /// Shows the placeholder that fits (none once there are rows). When the first rows replace a skeleton on screen,
    /// the skeleton fades out as the rows fade in (one 0.2 s cross-fade, no slide).
    private func updatePlaceholder(animated: Bool) {
        guard isViewLoaded else { return }
        let mode: ChatPlaceholderView.Mode?
        if !rows.isEmpty || lead != nil {   // [tasks] the lead is the empty chat's content
            mode = nil
        } else if awaitingRows {
            mode = .loading
        } else if model.builtFrom > 0 || model.hiddenOlder > 0 {
            // [right-open] Messages exist whose rows aren't in the table yet (built or revealed a moment later): never
            // the empty chat's "No messages yet" over a chat that has messages.
            mode = nil
        } else {
            switch openPhase {
            case .opening: mode = .loading
            case .failed(let reason): mode = .failed(reason)
            case .open:
                // [settings] Intro Splash off: the empty chat is blank above the message bar.
                mode = roomChrome != nil ? nil
                    : IntroSplash.isOn ? .empty(name: botName, head: session.head, profile: session.profile, intro: emptyIntro())   // [talk] [groups]
                    : .blank
            }
        }
        roomChrome?.setEmpty(rows.isEmpty)   // [groups] an empty room draws its own centre
        guard mode != placeholder.mode else { return }
        let wasSkeleton = placeholder.mode == .loading && !placeholder.isHidden
        let fade = animated && view.window != nil && !HQMotion.reduced
        if let mode {
            placeholderHiding = false
            let wasShowing = !placeholder.isHidden && placeholder.mode != nil
            placeholder.mode = mode
            placeholder.layer.removeAllAnimations()
            tableView.alpha = 1
            if !wasShowing {
                placeholder.alpha = fade ? 0 : 1
                placeholder.isHidden = false
                updatePlaceholderFrame()   // [perf] its frame isn't kept while hidden
                if fade { UIView.animate(withDuration: 0.2) { self.placeholder.alpha = 1 } }   // motion-ok: opacity only
            } else {
                placeholder.alpha = 1
            }
            return
        }
        guard !placeholder.isHidden else { return }
        if fade && wasSkeleton {
            guard !placeholderHiding else { return }          // a second call while it fades does nothing
            placeholderHiding = true
            // Not from the current state: the rows' 0 → 1 must start at 0 (the presentation layer still says 1).
            tableView.alpha = 0
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {   // motion-ok: opacity only
                self.placeholder.alpha = 0
                self.tableView.alpha = 1
            } completion: { _ in
                self.placeholderHiding = false
                guard !self.rows.isEmpty else { return }
                self.placeholder.isHidden = true
                self.placeholder.mode = nil
                self.placeholder.alpha = 1
            }
        } else {
            placeholder.isHidden = true
            placeholder.mode = nil
            tableView.alpha = 1
        }
    }

    /// The queue card's and the memo notice's side constraints (constant = the dock's side inset).
    private var dockSides: [NSLayoutConstraint] = []
    /// [desktop-composer] The composer's gap above the keys: the bar's own (a switch of Text Box changes it).
    private var keysGaps: [NSLayoutConstraint] = []

    /// [composer-drawers] The drawer sits 8 pt above the composer, on the docked cards' side edges, over the transcript
    /// (the composer's frame never changes for it). Its top keeps the status line and 44 pt of transcript in view; both
    /// its limits are weak so that it is the drawer, never the composer, that gives way.
    private func installDrawer() {
        guard let live = session as? LiveChatSession else { return }
        let host = ComposerDrawerHost(
            loadCatalog: { [weak live] in
                guard let live else { throw CancellationError() }
                return try await live.loadCommandsCatalog()
            },
            loadFreshCatalog: { [weak live] in
                guard let live else { throw CancellationError() }
                return try await live.loadCommandsCatalog(fresh: true)
            },
            latestCatalog: { [weak live] in live?.latestCommandsCatalog },
            isBotChat: { [weak live] in live?.isBotChat ?? false },
            ownProfile: { [weak live] in live?.profile ?? "" },
            bots: { (TalkWiring.model?.bots ?? []).filter { !$0.hidden }.map { (ComposerDrawerModel.BotEntry(profile: $0.id, name: $0.name), $0.head) } },
            recentChats: { [weak live] in
                guard let live else { return [] }
                let own = live.profile.isEmpty ? "default" : live.profile
                return (TalkWiring.model?.sessions ?? [])
                    .filter { ($0.profile.isEmpty ? "default" : $0.profile) == own && !$0.archived && $0.id != live.storedSessionId }
                    .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
                    .map { ComposerDrawerModel.RecentChat(id: $0.id, title: $0.title) }
            },
            sendCommand: { [weak self] command in
                guard let self else { return }
                if self.sendHasAttachments() {
                    self.composer.text = ""
                    self.runCommand(command)
                } else {
                    self.composer.text = command
                    self.composer.submit()
                }
            },
            openModels: { [weak self] in self?.menus?.presentModelSheet(query: nil) },
            openChat: { [weak self] id in
                guard let self, let summary = TalkWiring.model?.sessions.first(where: { $0.id == id }) else { return }
                TalkWiring.model?.openChat(summary, replacing: self)
            },
            enabled: { [weak self] in self?.roomChrome == nil },
            favoriteCommands: { [weak live] in live.map { CommandFavorites(accountId: $0.account.id).commands } ?? [] },
            toggleFavoriteCommand: { [weak live] command in
                guard let live else { return }
                CommandFavorites(accountId: live.account.id).toggle(command)
            })
        let drawer = ComposerDrawerController(composer: composer, completing: live, host: host)
        self.drawer = drawer
        let panel = drawer.panel
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let sides = [panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: dockSideInset),
                     view.safeAreaLayoutGuide.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: dockSideInset)]
        dockSides += sides
        let top = panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                                             constant: ChatMetrics.statusLineHeight + 44)
        top.priority = UILayoutPriority(240)   // over the drawer's own height (200), under anything that places the composer
        NSLayoutConstraint.activate(sides + [panel.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8), top])
        drawer.watchTaps(on: tableView)
    }

    /// The side inset of what sits at the bottom: the composer row's (it follows the keyboard), or the question dock's.
    var dockSideInset: CGFloat {
        guard let promptDock else { return composer.currentSideInset - composer.boxOutset }   // [desktoplook2] the box's edges
        return promptDock is ComposerRowDock ? ChatMetrics.composerSideDown + composer.columnMargin : 8 + composer.columnMargin   // [talk]
    }

    /// The docked cards follow the row's side inset in the same pass (inside the keyboard's animation).
    private func followDockSide() {
        let side = dockSideInset
        guard let first = dockSides.first, abs(first.constant - side) > 0.25 else { return }
        dockSides.forEach { $0.constant = side }
        activity.setSideInset(side)
    }

    private var edgeHostBottom: NSLayoutConstraint!

    /// [mac-ui-issues] The Mac draws no soft edge at the transcript's foot, so the rows showed again in the strip
    /// between the message box and the window's bottom edge (words under the box, in both looks). The rows now end
    /// inside the box's lower rim: behind the box they still show (through its glass in the iOS look), under it nothing.
    private func clipUnderMacBox() {
        guard DeviceWord.isMac else { return }
        var lift: CGFloat = 0
        if let box = composer.macBoxFrame, composer.window != nil, !composer.isHidden, composer.alpha > 0.01 {
            let bottom = composer.convert(box, to: view).maxY
            lift = max(0, view.bounds.maxY - bottom + 7)
        }
        if !edgeHost.clipsToBounds { edgeHost.clipsToBounds = true }
        if abs(edgeHostBottom.constant + lift) > 0.25 { edgeHostBottom.constant = -lift }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.followPosition()
        followDockSide()
        clipUnderMacBox()
        if edgeHost.contentSize != edgeHost.bounds.size { edgeHost.contentSize = edgeHost.bounds.size }
        updateBarBacking()
        // The table always covers the whole view: an inverted table pins its content to its frame's bottom, so a
        // frame that shrank with the keyboard would carry everything up with it. The keyboard only changes the
        // visual-bottom inset (`updateInsets`). Bounds and centre, never `frame`, on a transformed view.
        // [duo] Inside the side safe area: the iPhone Duo's open screen puts the status bar and the bar buttons in a
        // column down one edge (iOS 27.2 SDK), and its ⋯ sat on the first bubble. The composer, the docks and the
        // column guide keep to the same safe area. Zero on every other iPhone, iPad and Mac.
        let safe = view.safeAreaInsets
        let target = view.convert(view.bounds.inset(by: UIEdgeInsets(top: 0, left: safe.left, bottom: 0, right: safe.right)), to: edgeHost)
        if tableView.bounds.size != target.size {
            tableView.bounds = CGRect(origin: tableView.bounds.origin, size: target.size)
        }
        let center = CGPoint(x: target.midX, y: target.midY)
        if tableView.center != center { tableView.center = center }
        // [m9/ipad] Rows are laid out for the readable column (the pane's width up to 760 pt), centred in the pane.
        let column = ReadableColumn.fit(pane: tableView.bounds.width)
        if composer.columnMargin != column.margin {
            composer.columnMargin = column.margin
            // The composer and the cards on its edges (the Talk tip, the docks) take the new column in this same pass:
            // they were placed above with the old margin, and nothing laid the screen out again, so after Hide Sidebar
            // the Talk tip stuck out past the composer on both sides (stress test 2026-10-31).
            composer.followPosition()
            followDockSide()
        }
        if abs(column.width - layoutWidth) > 0.5 && tableView.bounds.width > 0, let shown = presentedViewController,
           shown.isBeingPresented || shown.isBeingDismissed {
            // Owner 2026-11-01: a photo's zoom in and out lays the chat out at another width for a moment (402 → 440 →
            // 402 on an iPhone 17 Pro); the full relayout that took put the chat back at its newest end, so closing a
            // photo from higher up lost the place. The width is judged again once the pop-up has come or gone.
            if !widthCheckQueued, let coordinator = shown.transitionCoordinator {
                widthCheckQueued = true
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.widthCheckQueued = false
                    self?.view.setNeedsLayout()
                }
            }
        } else if abs(column.width - layoutWidth) > 0.5 && tableView.bounds.width > 0 && !holdsWidthRelayout() {
            // [diagnostics] log study 2026-10-28: the Mac did 34 of these on opening a chat; the widths say why.
            let was = layoutWidth
            layoutWidth = column.width
            relayoutEverything(reason: "column width changed \(Int(was.rounded())) → \(Int(column.width.rounded()))"
                               + (view.window == nil ? ", off screen" : ""))
        }
        activity.layoutChanged()         // [activity] an opened card's cap follows the keyboard in this same pass
        updateInsets()
        updateBottomEdge()
        if promptDock != nil { updateJumpButton() }   // [questions] a dock that grew may leave it no room
        voice.layout()   // VOICE: the recorder's circle rides the keyboard
        TalkAwayPill.anchorChanged()   // [talk] the pill rides whatever sits above the composer
        // [perf] A hidden placeholder isn't resized: each size change re-runs its stack's fitting pass, and the keyboard
        // moves the dock on every frame of a swipe-down. It takes the current frame as it un-hides.
        if !placeholder.isHidden { updatePlaceholderFrame() }
        roomChrome?.layoutEmpty(in: transcriptRoom)   // [groups] the empty room keeps to the same room, above the keys
        if lead != nil { layoutLead() }   // [tasks]
        if !firstContentLogged && !tableView.visibleCells.isEmpty {
            firstContentLogged = true
            ChatPerf.firstContentLaidOut()
        }
    }

    /// The placeholder fills the transcript's room: under the status line, above the composer (and queue card).
    private func updatePlaceholderFrame() {
        let placeholderFrame = transcriptRoom
        if placeholder.frame != placeholderFrame { placeholder.frame = placeholderFrame }
    }

    private var transcriptRoom: CGRect {
        let dockTop = transcriptBottom   // [questions] composer or dock, queue card, prompt chip; VOICE memo notice; [activity] shelf
        let top = view.safeAreaInsets.top + ChatMetrics.statusLineHeight - 4 + ChatMetrics.transcriptTopGap
        return CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, dockTop - ChatMetrics.composerContentGap - top))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ChatPerf.mark("chat.viewWillAppear")
        applyChatColour()   // [bot-colour] the face may have changed while this chat was covered
        if attached { activity.setAttached(true) }     // [activity] uncovered by a pop: this chat's polls run again
        if isMovingToParent { fadeBottomBarWithTabBar(appearing: true) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { fadeBottomBarWithTabBar(appearing: false) }
    }

    /// [swipe-back] The tab bar fades in place (iOS 26's floating bar, and the Desktop Look's own) while this page and
    /// its composer slide: left alone, the two bars sat on top of each other for the whole swipe. The chat's bottom
    /// bar fades the other way, so only one bottom bar shows at a time. Only when the page on the other side has a
    /// tab bar.
    private func fadeBottomBarWithTabBar(appearing: Bool) {
        guard !movingBetweenPanes, let coordinator = transitionCoordinator, coordinator.isAnimated, tabBarController != nil,
              let stack = navigationController?.viewControllers else { return }
        let others = appearing ? Array(stack.dropLast()) : stack.filter { $0 !== self }
        guard !others.contains(where: \.hidesBottomBarWhenPushed) else { return }
        let bar = ([composer, composerNotices, queueCard, voice.notice, promptDock, drawer?.panel] as [UIView?])
            .compactMap { $0 }.filter { !$0.isHidden && $0.alpha > 0.01 }
        let alphas = bar.map(\.alpha)
        let restore = { zip(bar, alphas).forEach { view, alpha in view.alpha = alpha } }
        if appearing {
            // A push: the tab bar fades out with the old page, the chat's bar comes in over the push's second part.
            bar.forEach { $0.alpha = 0 }
            coordinator.animate(alongsideTransition: { _ in
                UIView.animateKeyframes(withDuration: 0, delay: 0, animations: {   // motion-ok: opacity only, on the push's own clock
                    UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.75, animations: restore)
                })
            }, completion: { _ in restore() })
        } else {
            // A pop: the tab bar shows at full strength the moment a swipe back starts, however slow the finger, so
            // the chat's bar goes on the clock, not with the finger. A cancelled swipe drops the tab bar at its end:
            // the chat's bar comes back after it.
            HQMotion.animate(0.15, changes: { bar.forEach { $0.alpha = 0 } })
            coordinator.animate(alongsideTransition: nil, completion: { context in
                if context.isCancelled { HQMotion.animate(0.2, changes: restore) } else { restore() }
            })
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        #if targetEnvironment(macCatalyst)
        // [mac-audit #4] A width change it missed off screen: laid out once, now, before it shows.
        if widthHeldOffScreen {
            widthHeldOffScreen = false
            view.setNeedsLayout()
        }
        #endif
        if focusesOnAppear {
            focusesOnAppear = false
            focusComposer()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if !firstContentLogged { ChatPerf.mark("chat.viewWillLayoutSubviews") }
    }

    /// [keys-return] Every pop-up the chat opens passes here: one opened over the keys gets them back when it closes.
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        noteKeys(for: controller)
        super.present(controller, animated: animated, completion: completion)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ChatPerf.mark("chat.viewDidAppear")
        edgeStandIn.handOver()
        // [desktoplook4] Panels that joined the window during the push sat under its dimming wrapper then: flatten
        // whatever is still glass now that it's done.
        if Theme.isDesktop { ThemeChrome.restyleGlass(in: view) }
        if movingBetweenPanes { movingBetweenPanes = false; attach(); reclaimTitle() }   // [m9/ipad] landed in the other pane
        promptsUI?.chatAppeared()   // [questions] a waiting password sheet shows now (Q14)
        #if DEBUG
        LinkDebugHook.runIfAsked(from: self)   // [transcript] -HQNDebugOpenLink
        #endif
        if !didAppear {
            didAppear = true
            AppLog.trace("chatui", "appear \(logTag): \(rows.count) rows")
            // Older rows are measured and shown only now, after the push: the rows built in init already cover
            // several screens, and the push is the moment the chat is judged.
            startFill()
            revealIfNeeded()
        }
        voice.screenAppeared()   // VOICE
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if movingBetweenPanes || landedInOtherPane { return }   // [m9/ipad] the same screen is going to the other pane: nothing ends
        voice.screenLeft()   // VOICE: a take left behind becomes a draft chip here
        // [tasks] A chat inside a sheet (a task's own chat) leaves with the sheet: its navigation is the one going down.
        if isMovingFromParent || isBeingDismissed || navigationController == nil || navigationController?.isBeingDismissed == true {
            detach()
            MainTrail.set("chatRows", nil)                // [diagnostics] build 292
        }
    }

    /// Removed from the navigation stack by any route (a pop, popToRoot from a screen above, setViewControllers, a
    /// root swap): a chat that isn't on top gets no appearance callbacks then.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if movingBetweenPanes { return }   // [m9/ipad] moved between the list stack and the right pane: stays attached
        if parent == nil { if !landedInOtherPane { detach() } } else if isViewLoaded { attach() }
    }

    /// [m9/ipad] Set by Next / Previous Chat just before the list opens the next chat (`push` reads and clears it).
    static var replacesTopOnNextPush = false

    /// [m9/ipad] Built for a row whose chat is already on show and never shown: ends what loading it started.
    func discardUnshown() {
        readyWaiter = nil
        detach()
    }

    private func attach() {
        guard !attached else { return }
        attached = true
        session.onChange = { [weak self] change in self?.handle(change) }
        if deliveryObserver == nil {   // [groups] the roster arrived or changed: the senders' names and faces follow
            deliveryObserver = DeliveryRoster.observe { [weak self] in
                guard let self, self.showsDeliveries else { return }
                self.activityRebuildAll()
            }
        }
        session.start()
        activity.setAttached(true)       // [activity] the chat's polls run while it shows
    }

    private func detach() {
        guard attached else { return }
        attached = false
        session.onChange = nil
        if let deliveryObserver { DeliveryRoster.stopObserving(deliveryObserver); self.deliveryObserver = nil }   // [groups]
        if let live = session as? LiveChatSession {   // [diagnostics] read by a reopen that finds a reply missed here
            LeftChatProbe.of(live).screenNote = "following \(following), \(unseen) unseen, \(rows.count) rows"
        }
        if unseen > 0 { AppLog.note("chat", "left with \(unseen) new message(s) below the screen") }   // [diagnostics]
        AppLog.trace("chatui", "close \(logTag): \(rows.count) rows, \(unseen) unseen, following=\(following)")
        cancelQueueEdit()   // [composer] leaving the chat while a queued message is edited is Cancel (spec §15.5)
        session.stopObserving()
        activity.setAttached(false)      // [activity]
        TileMaker.screenClosed(session)  // [dashboard] a New Tile still being made keeps watching
        endLift()
        stopGlide()
        stopStreamGlide()
        throttledApply?.invalidate()
        throttledApply = nil
        trimTimer?.invalidate()
        trimTimer = nil
    }

    /// The bar only re-reads a title view's size when the view is installed again. That must never happen from
    /// inside the bar's own layout or constraint pass: a text-size change reaches the title view while
    /// `_UINavigationBarTitleControl` is updating its constraints, and pulling the view out of the bar at that moment
    /// makes UIKit activate a constraint against a view that is no longer in the bar (NSGenericException, the
    /// Large <-> Extra Large crash). So: nothing happens when the size is unchanged, and a changed size is installed
    /// on the next turn of the main run loop, once, however many callers asked.
    private func sizeTitle() {
        let size = titleView.intrinsicContentSize
        guard titleInBar else {
            titleView.frame.size = size
            putTitleInBar()
            installedTitleSize = size
            return
        }
        guard size != installedTitleSize, !titleReinstallQueued else { return }
        titleReinstallQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titleReinstallQueued = false
            let size = self.titleView.intrinsicContentSize
            guard size != self.installedTitleSize else { return }
            self.installedTitleSize = size
            self.titleView.frame.size = size
            self.takeTitleDown()
            self.putTitleInBar()
            self.titleReinstalls += 1
        }
    }
    /// [m9/ipad] Moved between panes, the bar the chat left can take the title view down after the new bar put it up
    /// (stress test 2026-10-28, Mac: one pane and back to two, and the chat's bar had no title). Once both bars have
    /// laid out, a title view out of the window goes back in.
    private func reclaimTitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil, self.titleInBar, self.titleView.window == nil else { return }
            AppLog.note("screen", "chat title put back after a move between panes")
            self.takeTitleDown()
            self.putTitleInBar()
        }
    }
    /// The face, the name and its status line sit in the middle of the bar, on the Mac as on the iPhone. (The Mac led
    /// the bar with them from the layout study of 2026-11-03 until the owner saw it in Mac 915, 2026-11-09: "This
    /// looks odd left aligned. It's centered on iOS".)
    private var titleInBar: Bool { navigationItem.titleView === titleView }
    private func putTitleInBar() { navigationItem.titleView = titleView }
    private func takeTitleDown() { navigationItem.titleView = nil }
    private var installedTitleSize: CGSize = .zero
    private var titleReinstallQueued = false
    /// How many times a changed title size was installed again (tests read it).
    private(set) var titleReinstalls = 0

    #if targetEnvironment(macCatalyst)
    /// [mac-layout] ◨ at the bar's trailing end: the inspector shown or hidden (⌘I).
    private func makeInspectorButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "sidebar.trailing"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if let inspector = MacInspector.beside(self) { inspector.toggle() } else { self.menus?.perform(.info) }
        })
        item.accessibilityLabel = "Inspector"
        item.accessibilityIdentifier = "chat.inspector"
        return item
    }
    #endif

    /// The bar's ⋯, where Share and Delete Chat were picked: their sheet and question point at it. [mac] Mac polish #82:
    /// the Mac's bar puts the Inspector button first, so `rightBarButtonItem` was that, not the ⋯.
    var moreBarItem: UIBarButtonItem? {
        navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "chat.more" } ?? navigationItem.rightBarButtonItem
    }

    private func updateMoreButton() {
        guard isViewLoaded else { return }
        if let moreMenu {
            let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu)
            item.accessibilityLabel = session is ChatRoomSurface ? "Group chat actions" : "Chat Actions"   // [groups]
            item.accessibilityIdentifier = "chat.more"
            // [settings] File Browser on, and this chat has a folder: Files sits beside the ⋯ (3x-settings §12).
            let items = showsFilesButton ? [item, makeFilesButton()] : [item]
            filesButtonShown = showsFilesButton
            #if targetEnvironment(macCatalyst)
            readAloudButtonShown = showsReadAloudButton
            navigationItem.rightBarButtonItems = [makeInspectorButton()] + items + (readAloudButtonShown ? [makeReadAloudButton()] : [])
            #else
            navigationItem.rightBarButtonItems = items
            #endif
        } else {
            navigationItem.rightBarButtonItems = nil
            filesButtonShown = false
            #if targetEnvironment(macCatalyst)
            readAloudButtonShown = false
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    // MARK: [mac-audit] Read Replies Aloud in the bar

    // Owner 2026-11-02 (Mac audit #26): once its notice had gone, nothing said Read Replies Aloud was on, and a reply
    // could start speaking out of nowhere. While it is on, a quiet speaker sits beside the ⋯ (with Files, the bar's
    // other "this is on" glyph); its menu says what it is and turns it off. The iPhone has its voice dock for this.

    private var showsReadAloudButton: Bool {
        moreMenu != nil && menus?.slotItems[.readAloud] != nil && TalkController.readsRepliesAloud
    }

    private func makeReadAloudButton() -> UIBarButtonItem {
        let off = UIAction(title: "Stop Reading Replies Aloud", image: UIImage(systemName: "speaker.slash")) { [weak self] _ in
            Haptics.play(.selection)
            TalkController.readsRepliesAloud = false
            self?.showNotice("Read Replies Aloud is off")
        }
        off.accessibilityIdentifier = "chat.readAloud.off"
        let item = UIBarButtonItem(image: UIImage(systemName: "speaker.wave.2"),
                                   menu: UIMenu(title: "Replies are read aloud", children: [off]))
        item.accessibilityLabel = "Read Replies Aloud is on"
        item.accessibilityIdentifier = "chat.readAloud"
        return item
    }

    /// The switch changed, or this chat's Read Aloud came in: the bar is touched only when the speaker comes or goes.
    func updateReadAloudButton() {
        guard isViewLoaded, showsReadAloudButton != readAloudButtonShown else { return }
        updateMoreButton()
    }
    #endif

    // MARK: [settings] File Browser (docs/spec/3x-settings.md §12)

    private var filesButtonShown = false
    #if targetEnvironment(macCatalyst)
    private var readAloudButtonShown = false
    #endif
    private var filesWatch: [NSObjectProtocol] = []

    /// The switch is on, the chat has a ⋯ with Files in it, and it has a folder to list. Never a dead button.
    private var showsFilesButton: Bool {
        guard moreMenu != nil, menus != nil, !(session is ChatRoomSurface), let actions = session as? ChatSessionMoreActions else { return false }
        return FileBrowserPref.showsButton(on: FileBrowserPref.isOn, directory: actions.workingDirectory)
    }

    private func makeFilesButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "folder"), primaryAction: UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.menus?.performListAction(.files)
        })
        item.accessibilityLabel = "Files"
        item.accessibilityIdentifier = "chat.files"
        return item
    }

    /// The switch or the chat's folder changed. The bar is touched only when the button comes or goes: handing the
    /// bar new items would close an open ⋯ menu.
    private func updateFilesButton() {
        guard isViewLoaded, showsFilesButton != filesButtonShown else { return }
        updateMoreButton()
    }

    private func watchFileBrowser() {
        guard filesWatch.isEmpty else { return }
        let center = NotificationCenter.default
        filesWatch = [
            center.addObserver(forName: FileBrowserPref.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFilesButton() }
            },
            // Any chat's folder: the check below is cheap and touches the bar only when this chat's answer changed.
            center.addObserver(forName: LiveChatSession.workingDirectoryChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFilesButton() }
            },
        ]
        #if targetEnvironment(macCatalyst)
        filesWatch.append(center.addObserver(forName: TalkController.readRepliesAloudChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReadAloudButton() }
        })
        #endif
    }

    /// [talk] An item that keeps the ⋯ menu open changed what the menu shows (Read Replies Aloud's checkmark): the open
    /// menu's rows are redrawn in place. Handing the bar a new item would close the menu. The bar's own control holds
    /// the menu's interaction; with no ⋯ menu open nothing happens (docs/spec/3x-talk.md §7.3).
    func refreshVisibleMoreMenu() {
        guard let bar = navigationController?.navigationBar, let menus else { return }
        func controls(in view: UIView) -> [UIControl] {
            view.subviews.flatMap { child in ((child as? UIControl).map { [$0] } ?? []) + controls(in: child) }
        }
        for control in controls(in: bar) {
            control.contextMenuInteraction?.updateVisibleMenu { [weak menus] current in
                guard current.identifier == ChatMenus.moreMenuIdentifier, let menus else { return current }
                return current.replacingChildren(menus.moreMenuElements())
            }
        }
    }

    /// ⋯ › Share Transcript: the system share sheet with the chat as text.
    func shareTranscript(_ text: String) {
        guard !text.isEmpty else { showNotice("Nothing to share yet."); return }
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        share.popoverPresentationController?.sourceItem = moreBarItem
        present(share, animated: true)
    }

    /// The table's visual-bottom inset follows the composer (moving in the keyboard's own animation); the top one
    /// reserves the bar and the status line.
    /// Shows or hides the queue card for the session's queued sends (it moves the jump button and the transcript's
    /// bottom with it, in one animation).
    /// [m9/composer] A hardware Return in the empty field (docs/spec/3x-composer.md §1.2): idle with messages waiting,
    /// the next one goes out; while a reply runs, Send Now on the head row. A paused queue needs Resume.
    private func hardwareReturnInEmptyField() {
        // [composer] Editing a queued message: an empty Return keeps editing (it never sends the queue).
        guard let queue = session as? ChatQueueing, queue.queueEditingId == nil, let head = queue.queuedMessages.first else { return }
        let rule = EmptyReturn.decide(running: session.isRunning, waiting: queue.queuedMessages.count, paused: queue.isQueueParked,
                                      canAct: !questionWaiting)
        AppLog.note("keys", "return in the empty field: \(rule)")
        switch rule {
        case .nothing: return
        case .sendNext: (session as? ChatQueueResuming)?.sendNextQueued()
        case .sendNowHead: queue.sendQueuedNow(head.id)
        }
    }

    private func updateQueueCard() {
        guard let queue = session as? ChatQueueing, isViewLoaded else { return }
        let items = queue.queuedMessages
        let show = !items.isEmpty
        let sending = Set(items.lazy.map(\.id).filter { queue.isQueuedSending($0) })
        let changed = queueCard.update(items, parked: queue.isQueueParked, running: session.isRunning, sending: sending,
                                       editing: queue.queueEditingId)
        guard changed || show == queueCard.isHidden else { return }
        let animate = view.window != nil && !HQMotion.reduced
        if show && queueCard.isHidden { queueCard.alpha = 0; queueCard.isHidden = false }
        queueCollapsed.isActive = !show
        queueGap.constant = show ? -8 : 0
        promptQueueGap?.constant = queueGap.constant   // [questions] the queue card sits 8 pt above the dock too (Q13)
        let changes = {
            self.queueCard.alpha = show ? 1 : 0
            self.view.layoutIfNeeded()
        }
        // Only while it is still meant to be away: a queued message shown during the fade-out (a chat opening as a
        // reply starts, then a send) was hidden again by this completion, its card gone with a message waiting.
        let done: (Bool) -> Void = { _ in if !show, self.queueCollapsed.isActive { self.queueCard.isHidden = true; self.updateInsets() } }
        if animate {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: done)   // motion-ok: `animate` is false under Reduce Motion
        } else {
            changes(); done(true)
        }
    }

    /// The system's soft edge reaches about 40 pt above the composer, so the newest bubble, resting 8 pt above it, sat
    /// in the blur at rest in every chat (verification round 2). Nothing is under the composer while the list follows
    /// its newest end (a streaming reply's glide included, so the edge doesn't blink with each delta), so the edge
    /// shows only once the reader has moved away or a held reply runs on under it.
    /// [desktop-frost] The chat's look-dependent chrome. The chat keeps the system's soft edges in both looks (main,
    /// 2026-10-18); in the Desktop Look its bar stays clear over them (the look's other bars are frosted, ThemeChrome;
    /// on the Mac the chat's is frosted too, mac-audit #5)
    /// and the jump is a flat round button (the glass circle off the look, same place).
    private func applyChatLook() {
        let desktop = Theme.isDesktop
        keysGaps.forEach { $0.constant = -ChatMetrics.composerBottomUp }
        jumpButton.applyLook()
        jumpWidth.constant = jumpButton.preferredWidth
        jumpHeight.constant = jumpButton.preferredHeight
        activity.jumpWidthChanged(jumpButton.preferredWidth)
        statusPillTop.constant = ChatMetrics.statusPillTop
        var clear: UINavigationBarAppearance? = desktop ? ThemeChrome.solidBar() : nil
        #if targetEnvironment(macCatalyst)
        // [mac-audit #5] Owner 2026-11-02: in the Desktop Look the chat's bar showed the list pane's band (and a
        // hairline) only until the sidebar folded or the window was resized, then went flat until the chat was opened
        // again. The band was the system's top edge effect over the still edge host, which the Mac fades out for good
        // after the host's first size change (nothing scrolls it, so nothing brings it back). The chat takes the list
        // pane's own bar instead (the look's frost, no hairline, `ListBarAppearance`), and that edge stays off.
        edgeHost.topEdgeEffect.isHidden = desktop
        if desktop { clear = ThemeChrome.solidBar(frosted: true) }
        // [mac] Stress test 2026-10-28 #57 (round 2): in the iOS look the chat pane's bar drew a hairline under it and
        // the list pane's bar beside it none. The system's own bar, without its line, so the two pane headers match.
        if !desktop {
            let plain = UINavigationBarAppearance()
            plain.configureWithDefaultBackground()
            plain.shadowColor = .clear
            plain.shadowImage = nil
            clear = plain
        }
        #endif
        navigationItem.standardAppearance = clear
        navigationItem.scrollEdgeAppearance = clear
        navigationItem.compactAppearance = clear
        navigationItem.compactScrollEdgeAppearance = clear
    }

    private func updateBottomEdge() {
        guard isViewLoaded else { return }
        let under = tableView.contentOffset.y - minOffset - ChatMetrics.composerContentGap > 0.5
        let hide = (following && glideLink == nil) || !under
        guard edgeHost.bottomEdgeEffect.isHidden != hide else { return }
        if Self.traceScroll { print("[Scroll] bottom edge \(hide ? "hidden" : "shown")") }
        if view.window != nil && !HQMotion.reduced {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.edgeHost.bottomEdgeEffect.isHidden = hide
            }
        } else {
            edgeHost.bottomEdgeEffect.isHidden = hide
        }
    }

    private func updateInsets() {
        let dockTop = transcriptBottom   // [questions] composer or dock, queue card, prompt chip; VOICE memo notice; [activity] shelf
        let bottom = max(0, view.bounds.maxY - dockTop) + ChatMetrics.composerContentGap
        let top = view.safeAreaInsets.top + ChatMetrics.statusLineHeight - 4 + ChatMetrics.transcriptTopGap + findInset
        let old = tableView.contentInset
        // The scroll bar runs the whole height the rows can show in: down behind the composer to the screen's bottom
        // edge (above the home indicator), or to the keys when they're up. Owner 2026-11-01: ended at the composer's
        // top, it never reached the bottom with the chat at its newest end.
        let keysTop = view.keyboardLayoutGuide.layoutFrame.minY
        let barBottom = max(view.safeAreaInsets.bottom, view.bounds.maxY - keysTop)
        let bar = UIEdgeInsets(top: barBottom, left: 0, bottom: top - 12, right: 0)
        if tableView.verticalScrollIndicatorInsets != bar { tableView.verticalScrollIndicatorInsets = bar }
        guard abs(old.top - bottom) > 0.25 || abs(topInset - top) > 0.25 else { return }
        #if DEBUG
        activity.motionProbe?.note(String(format: "insets %.1f -> %.1f dockTop=%.1f composer=%.1f dock=%.1f queue=%@ anim=%.2f following=%d anchor=%d glide=%d stream=%d lift=%d",
                                          old.top, bottom, dockTop, composer.frame.minY, promptDock?.frame.minY ?? -1,
                                          queueCard.isHidden ? "-" : String(format: "%.1f", queueCard.frame.minY),
                                          UIView.inheritedAnimationDuration, following ? 1 : 0, anchorMessageId != nil ? 1 : 0,
                                          glideLink != nil ? 1 : 0, streamLink != nil ? 1 : 0, lift != nil ? 1 : 0))
        #endif
        let offset = tableView.contentOffset.y
        topInset = top
        tableView.contentInset = UIEdgeInsets(top: bottom, left: 0, bottom: top + glideHeadroom, right: 0)
        // [tasks] The keys came for a field in the lead (it shows), or the page holds the lead's top.
        defer { if lead != nil { if leadPinEnded { revealLeadField(animated: false) } else { layoutLead() } } }
        // The jump glide reads the live end every frame; during an interactive keyboard dismissal the finger owns
        // the offset (the content stays under it); a held reply stays where it is (spec 06 §4.3, §5.3).
        if glideLink != nil || tableView.isTracking || lift?.drivesOffset == true { return }
        if anchorMessageId != nil && !following { return }
        if activity.shelfChanging && !following { return }      // [activity] a chip came or went: rows on screen stay put
        if Self.traceScroll {
            print(String(format: "[Scroll] insets bottom %.1f -> %.1f top %.1f -> %.1f following=%d glide=%d", old.top, bottom, old.bottom, top,
                         following ? 1 : 0, streamLink != nil ? 1 : 0))
        }
        if following {
            if streamLink != nil, streamTarget == nil, UIView.inheritedAnimationDuration == 0 {
                // Verify round 2: a dock that changed size at once (the recorder closing, a card leaving) under a glide
                // toward the newest end: the glide carries on from the new end. Stopping it here snapped the rows to the
                // end for a frame and the next update started a new glide from below (the memo bubble's restarts). An
                // animated change (the shelf's spring, the keyboard) still carries the rows in its own animation.
                ensureHeadroom(for: -bottom + streamRemaining)
                tableView.contentOffset.y = -bottom + streamRemaining
            } else {
                stopStreamGlide()
                tableView.contentOffset.y = -bottom
            }
        } else {
            // Keep what sits just above the composer where it is.
            tableView.contentOffset.y = offset - (bottom - old.top)
        }
    }

    // MARK: Data source

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        #if DEBUG
        if Self.traceApply { heightQueries += 1 }
        #endif
        return indexPath.row < layouts.count ? layouts[indexPath.row].height : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        #if DEBUG
        noteFirstCell()
        #endif
        let row = rows[indexPath.row]
        var reuse: String
        switch row.kind {
        case .bubble: reuse = ChatBubbleCell.reuse
        case .toolRun, .thought, .backgroundResult: reuse = ChatToolCell.reuse
        case .updateMember: reuse = UpdateMemberCell.reuse                                     // [updates]
        case .day, .notice, .caption, .stoppedEarly, .sendState, .slashOutput: reuse = ChatLineCell.reuse
        case .error: reuse = ChatErrorCell.reuse
        case .waiting: reuse = ChatWaitingCell.reuse
        case .actions: reuse = ChatActionsCell.reuse
        case .prompt: reuse = ChatPromptCell.reuse   // [questions]
        case .reactions: reuse = ChatReactionsCell.reuse
        case .activity: reuse = ""          // [activity] set below
        }
        if case .activity(let kind) = row.kind { reuse = ActivityCells.reuse(for: kind) }    // [activity]
        let cell = tableView.dequeueReusableCell(withIdentifier: reuse, for: indexPath)
        if cell.alpha < 1 { cell.alpha = 1 }      // a cell hidden as its row was deleted (`apply`)
        if let chat = cell as? ChatBaseCell {
            chat.delegate = self
            chat.configure(row, layout: layouts[indexPath.row])
        }
        if let bubble = cell as? ChatBubbleCell { bubble.setFind(findController?.highlight(forRow: row.id)) }   // MENUS: Find
        if let chat = cell as? ChatBaseCell { chat.setSpoken(isSpoken(row)) }   // [talk] the reply being read aloud
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // A cell hidden as its row was deleted (`apply`) that the table prepared ahead for another row shows again.
        if cell.alpha < 1 { cell.alpha = 1 }
        // A reply taller than the screen draws only the text near it (positioned now, before the first draw).
        if indexPath.row < layouts.count, layouts[indexPath.row].height > tableView.bounds.height {
            (cell as? ChatBaseCell)?.updateWindowRect(in: tableView)
        }
    }

    // [talk] The reply being read aloud is marked in the list (docs/spec/3x-talk.md §7.5): its bubbles carry the bar,
    // its action row shows Stop.
    private func isSpoken(_ row: ChatRow) -> Bool {
        guard case .bubble(let bubble) = row.kind, !bubble.mine else { return false }
        return voice.talkSpokenMessageId == row.messageId
    }

    func talkRefreshSpokenCells() {
        guard isViewLoaded else { return }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] where indexPath.row < rows.count {
            guard let cell = tableView.cellForRow(at: indexPath) as? ChatBaseCell else { continue }
            cell.setSpoken(isSpoken(rows[indexPath.row]))
            (cell as? ChatActionsCell)?.refreshReadAloud()
        }
    }

    /// Lays out upcoming rows' text off the main thread so their cells draw without measuring.
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        warm(rows: indexPaths.map(\.row))
    }

    /// Text layouts requested ahead of display (main thread only), so a row is queued once.
    private var warmRequested = Set<ObjectIdentifier>()
    private var lastWarmRange: ClosedRange<Int>?
    private var lastWarmOffset: CGFloat = 0

    private func warm(rows indices: [Int]) {
        var items: [(NSAttributedString, CGFloat?)] = []
        for i in indices where i >= 0 && i < layouts.count {
            guard case .bubble(let b) = layouts[i].content else { continue }
            for block in b.blocks {
                for piece in block.pieces.prefix(4) {
                    let id = ObjectIdentifier(piece.text)
                    if warmRequested.contains(id) || TextKitPool.pooled(piece.text, width: block.layoutWidth) != nil { continue }
                    warmRequested.insert(id)
                    items.append((piece.text, block.layoutWidth))
                }
            }
        }
        if warmRequested.count > 4000 { warmRequested.removeAll() }
        guard !items.isEmpty else { return }
        let box = UncheckedSendable(items)
        warmQueue.async {
            for (text, width) in box.value where TextKitPool.pooled(text, width: width) == nil {
                _ = TextKitPool.layout(text, width: width)
            }
        }
    }

    /// Our own look-ahead (the table's prefetch is tuned for finger speeds): the rows within 1.5 screens beyond the
    /// visible ones, in the direction of travel.
    private func warmAhead(towardOlder: Bool) {
        guard let visible = tableView.indexPathsForVisibleRows, let lo = visible.map(\.row).min(),
              let hi = visible.map(\.row).max() else { return }
        let range = lo...hi
        guard range != lastWarmRange else { return }
        lastWarmRange = range
        let budget = tableView.bounds.height * 1.5
        var indices: [Int] = []
        var total: CGFloat = 0
        var i = towardOlder ? hi + 1 : lo - 1
        while i >= 0 && i < layouts.count && total < budget {
            indices.append(i)
            total += layouts[i].height
            i += towardOlder ? 1 : -1
        }
        warm(rows: indices)
    }

    // MARK: Changes from the session

    private static let traceRows = ProcessInfo.processInfo.arguments.contains("-HQDemoTraceRows")

    /// Notes what changed; the rows are rebuilt and applied once per delivery (a frame's `.appended`, `.updated`
    /// and `.state` arrive together), on the next turn of the main queue.
    private func handle(_ change: ChatChange) {
        if Self.traceRows { print("[Rows] change \(change)") }
        switch change {
        case .reset, .removed:
            pendingReset = true
            if awaitingReply, let u = session.messages.lastIndex(where: { $0.role == .user }) { awaitFromIndex = u }
        case .updated(let ids):
            pendingTouched += ids
        case .appended(let ids):
            noteAppended(ids)
            pendingTouched += ids
        case .prependedOlder(let count):
            ChatPerf.mark("chat.prependedOlder \(count)")
            awaitFromIndex += count
            // Indices shift now; pending touches resolve by id at the flush.
            model.rebuildOldest(input(), added: count)
        case .state:
            applyState()
            // The waiting capsule depends on isRunning.
            pendingNewest = true
        }
        // [drafts] A draft answered some other way than its card's buttons: that card is drawn again.
        switch change {
        case .appended, .state, .removed: pendingTouched += draftMessagesToRebuild()
        case .reset: _ = draftMessagesToRebuild()   // everything is rebuilt; only the answers are noted
        default: break
        }
        activity.sessionChanged()        // [activity] the live Steps sheet, an open step sheet
        voice.talkSessionChanged()       // [talk] Read Replies Aloud reads a reply that completes on screen
        // MENUS: Find follows the transcript, and its Search Earlier row the paging state.
        if case .state = change { findController?.sessionStateChanged() } else { findController?.messagesChanged() }
        scheduleFlush()
    }

    private func noteAppended(_ ids: [String]) {
        let messages = session.messages
        followSpokenSend(ids, in: messages)
        for id in ids {
            guard awaitingReply, let index = messages.lastIndex(where: { $0.id == id }), messages[index].role != .user else { continue }
            var user = index - 1
            while user >= 0 && messages[user].role != .user { user -= 1 }
            if user >= awaitFromIndex {
                anchorMessageId = id
                awaitingReply = false
            }
        }
        if !following { unseen += ids.count; jumpButton.setCount(unseen) }
    }

    /// [talk] A spoken request goes from the conversation straight to the session, past `sendComposer`: its bubble
    /// arrived below the screen when a long reply had stopped the following (owner, build 409: "it isn't scrolling down
    /// to show all of what i said"; the tool rows of its turn then ran off screen too). Our own new bubble during a
    /// conversation is taken as the send it is: to the end, following, the reply anchored under it.
    private func followSpokenSend(_ ids: [String], in messages: [ChatMessage]) {
        guard !awaitingReply, (session as? ChatVoiceTurns)?.voiceHold == true,
              let index = messages.lastIndex(where: { ids.contains($0.id) && $0.role == .user && $0.isPending }) else { return }
        awaitingReply = true
        awaitFromIndex = index
        lastSendTime = CACurrentMediaTime()
        if !isAtBottom { scrollToBottom(animated: true) }
        following = true
        AppLog.trace("scroll", "spoken send \(logTag): to the end, following")
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let span = MainTrail.begin(pendingReset ? "chat.flush.reset" : "chat.flush")   // [diagnostics] build 292
        defer { MainTrail.end(span) }
        let reset = pendingReset
        #if DEBUG
        let started = CACurrentMediaTime()
        defer {
            if Self.traceApply {
                print(String(format: "[Apply] flush %.2f ms (rebuild + apply)%@", (CACurrentMediaTime() - started) * 1000, reset ? " reset" : ""))
            }
            activity.motionProbe?.note(String(format: "flush %.1f ms%@", (CACurrentMediaTime() - started) * 1000, reset ? " reset" : ""))
        }
        #endif
        // Verify round 2 (a trap seen under load): messages that shrank without a reset leave the model built from the
        // old, longer list; rebuilding only the newest rows then read past the end. A full rebuild instead.
        if !pendingReset && model.isStale(forMessageCount: session.messages.count) { pendingReset = true }
        if pendingReset {
            // Only the shown region has to be rebuilt now (the table is a few screens); the fill rebuilds the rest
            // off the main thread.
            model.rebuildAll(input(), syncMessages: rows.isEmpty ? Self.syncBuildMessages : 8, oldestShown: rows.last?.messageId)
            if rows.isEmpty { model.reveal(40) }
            fillGeneration += 1
        } else if !pendingTouched.isEmpty {
            model.rebuildNewest(input(), touching: pendingTouched)
        } else if pendingNewest {
            model.rebuildNewest(input(), fromMessage: max(0, session.messages.count - 1))
        }
        pendingReset = false
        pendingTouched = []
        pendingNewest = false
        if Self.traceRows {
            print("[Rows] all=\(model.allRows.prefix(6).map(\.id)) shown=\(model.shownCount) hidden=\(model.hiddenOlder) built=\(model.builtFrom)")
        }
        requestApply()
        if reset { fillDoneLogged = false }
        startFill()
        // After every delivery (rows, or the open's end): the placeholder that fits, and a held push.
        updatePlaceholder(animated: true)
        pushIfWaiting()
    }

    /// The bot was renamed or got a new head while this chat is open (Edit Bot / Edit Head, here or elsewhere): the
    /// title, its subtitle, the field's "Message <name>" and the empty chat's intro follow now (1x-settings §7.5; the
    /// head itself is the title accessory, redrawn by its owner). Verify round 2: they waited for the chat to reopen.
    func botIdentityChanged() {
        guard isViewLoaded else { return }
        noteTitleHead()
        applyState()
        updatePlaceholder(animated: false)
    }

    // [connect-fast] "Reconnecting…" waits 2 s, as the headers' subtitle does: a quick reconnect shows nothing.
    private var reconnectWords = ReconnectWordsGate()
    private var reconnectWordsTimer: Timer?

    /// Whether the chat's "Reconnecting…" may show now; while it is held, a timer reads the state again when it ends.
    private func reconnectWordsShown() -> Bool {
        let reconnecting: Bool
        if case .reconnecting = session.connection { reconnecting = true } else { reconnecting = session.statusText == HeaderLink.reconnecting }
        let (show, recheck) = reconnectWords.note(reconnecting: reconnecting)
        if let recheck {
            if reconnectWordsTimer == nil {
                let timer = Timer(timeInterval: recheck + 0.05, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.reconnectWordsTimer = nil
                        self.applyState()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                reconnectWordsTimer = timer
            }
        } else {
            reconnectWordsTimer?.invalidate()
            reconnectWordsTimer = nil
        }
        return show
    }

    private func applyState() {
        let wasRunning = composer.isRunning && roomChrome == nil
        // [groups] A room's round shows the same Stop square as a bot chat (it stops the room; owner 2026-11-06).
        composer.isRunning = session.isRunning || (session as? ChatRoomSurface)?.roomRunning == true
        // A bot answers a page's button by rewriting the page: its open sheet reloads, its card is pictured again.
        if wasRunning, !session.isRunning, let context = mediaContext { PageSnapshots.noteTurnEnded(context) }
        if wasRunning, !session.isRunning { TileMaker.turnEnded(session) }   // [dashboard] a New Tile asked in this chat
        let reconnectShown = reconnectWordsShown()   // [connect-fast]
        // [connect-fast] The first 2 s of a reconnect read as connecting (a send waits for the socket).
        var link = session.connection
        if case .reconnecting = link, !reconnectShown { link = .connecting }
        switch link {
        case .offline, .reconnecting:
            composer.allowsDeferredSend = (session as? LiveChatSession)?.canQueueWhileDisconnected == true
        case .connecting, .ready, .signedOut:
            composer.allowsDeferredSend = false
        }
        // Text and attachments can queue while the gateway is away. Voice and live controls still need the link.
        switch link {
        case .reconnecting:
            composer.isEnabled = false
            composer.placeholder = "Reconnecting…"
        case .offline:
            composer.isEnabled = false
            composer.placeholder = "Offline"
        case .signedOut:
            composer.isEnabled = false
            composer.placeholder = "Signed Out"
        case .connecting, .ready:
            composer.isEnabled = true
            let name = botName.trimmingCharacters(in: .whitespaces)
            composer.placeholder = name.isEmpty ? "Message" : "Message \(name)"
            if let room = session as? ChatRoomSurface {   // [groups]
                composer.placeholder = room.replyTarget != nil ? "Reply in thread…" : "Message \(room.roomName)"
            }
        }
        var statusText = session.statusText == HeaderLink.reconnecting && !reconnectShown ? nil : session.statusText   // [connect-fast]
        // [toolnow] At the Bottom: what the bot is doing shows once, under the typing dots, not in the pill as well.
        if ToolCallSettings.style == .bottom, (session as? LiveChatSession)?.statusIsWork() == true { statusText = nil }
        statusPill.set(statusText)
        let edge = statusText == nil ? Self.topEdgeBelowStatus : Self.topEdgeBelowShownStatus
        if let topEdgeBottom, topEdgeBottom.constant != edge { topEdgeBottom.constant = edge }
        // MENUS (spec 1x §7.1): ☰ is off only while signed out (offline it still opens: cached list or the error).
        if case .signedOut = session.connection { composer.commandsEnabled = false } else { composer.commandsEnabled = true }
        // [composer-expand] The bar is always two rows (owner 2026-11-01), so its model bubble reads the chat's model when
        // that changes, not only on focus as when the bubble came with the keyboard.
        if let live = session as? LiveChatSession {
            var ready = false
            if case .ready = session.connection { ready = true }
            if live.modelState != chipModelState || ready != chipLinkReady {
                chipModelState = live.modelState
                chipLinkReady = ready
                composer.refreshModelChip()
            }
        }
        updateQueueCard()
        updateComposerNotices()          // [transcript] the chat's problem card, "Couldn’t Send"
        // [transcript] §4.2: the link came back: a failed read of earlier messages tries once by itself.
        var linkReady = false
        if case .ready = session.connection { linkReady = true }
        if linkReady, !wasLinkReady {
            (session as? ChatOlderPaging)?.retryOlder()
            // [attachments] §7.4: failed photos on screen retry too (off-screen ones retry when they scroll back).
            for case let cell as ChatBubbleCell in tableView.visibleCells { cell.retryFailedMedia() }
        }
        wasLinkReady = linkReady
        loadOlderIfNear()
        activity.stateChanged()          // [activity] In Header's tap, Previous tasks once idle
        // A session that isn't the bot's own chat names its bot under the title (spec 06 §4.1).
        let owner = botName.trimmingCharacters(in: .whitespaces)
        var subtitle = owner.isEmpty || owner == shownTitle.trimmingCharacters(in: .whitespaces) ? nil : owner
        if let room = session as? ChatRoomSurface { subtitle = room.roomStatusLine }   // [groups] who is replying, else the members
        #if targetEnvironment(macCatalyst)
        // [mac-layout] The Mac's bar says what the bot is up to under its name: Working… while a turn runs, otherwise
        // the model it answers with (after a session's bot name: "Otto · Claude Opus 4.5").
        if !(session is ChatRoomSurface) {
            var parts = [subtitle].compactMap { $0 }
            if session.isRunning {
                parts.append("Working…")
            } else if let state = (session as? ChatModelControlling)?.modelState, !state.model.isEmpty {
                parts.append(ModelNames.displayModelName(state.model, provider: state.provider))   // [provider-manager]
            }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        #endif
        roomChrome?.stateChanged()                                                     // [groups]
        if titleView.title != shownTitle || titleView.subtitle != subtitle {
            let renamed = titleView.title != shownTitle
            titleView.title = shownTitle
            titleView.subtitle = subtitle
            sizeTitle()
            if renamed { updatePlaceholder(animated: false) }   // a named chat drops the intro's Name Chat
        }
        if wasRunning && !session.isRunning { runningEndedAt = CACurrentMediaTime() }
    }

    /// UX study #248: a bell.slash after the name while this chat's bot is muted (a group room has its own mute).
    private func updateTitleMute() {
        let muted = !(session is ChatRoomSurface) && BotMuteCenter.shared.isMuted(session.profile)
        guard titleView.muted != muted else { return }
        titleView.muted = muted
        sizeTitle()
    }

    // MARK: Applying rows to the table

    /// Brings the table up to the model's shown rows. Layouts missing from the cache are measured off the main
    /// thread first (or right here when they are small), then applied in one batch with no animation.
    /// `urgent`: the reader is waiting for it (a reveal, a toggle); otherwise a big table deep in history takes
    /// newest-end updates at most five times a second (the held position doesn't move either way).
    private func requestApply(urgent: Bool = false) {
        guard isViewLoaded else {
            // Before the view exists (changes between init and viewDidLoad): just take the rows.
            rows = Array(model.shown)
            layouts = rows.map { TextLayout.layout($0, width: layoutWidth, style: style, keep: true) }
            return
        }
        if layoutInFlight { return }   // the measure in flight applies when it lands
        if !urgent && !following && rows.count > Self.heavyTableRows {
            let wait = lastApplyTime + 0.2 - CACurrentMediaTime()
            if wait > 0 {
                if throttledApply == nil {
                    let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.throttledApply = nil
                            self?.requestApply(urgent: true)
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    throttledApply = timer
                }
                return
            }
        }
        throttledApply?.invalidate()
        throttledApply = nil
        // [perf] The rows this round shows, kept as they are now: a measure off-main applies exactly what it measured
        // when it lands, even if the reply has moved on since (it would otherwise start over on every delta).
        let target = model.shown
        let d = ChatRowDiff.make(old: rows, new: target)
        guard !d.isEmpty else { return }
        var missing: [ChatRow] = []
        var cost = 0
        for i in d.inserts + d.changed {
            let row = target[i]
            if TextLayout.cached(row, width: layoutWidth, style: style) == nil {
                missing.append(row)
                cost += Self.measureCost(row)
            }
        }
        if missing.isEmpty || (cost < 1200 && missing.count <= 4) || syncApply {
            for row in missing { _ = TextLayout.layout(row, width: layoutWidth, style: style, keep: true) }
            apply(d, shown: target)
            return
        }
        layoutInFlight = true
        let width = layoutWidth, style = style, box = UncheckedSendable(missing), measured = UncheckedSendable(target)
        let generation = fillGeneration
        layoutQueue.async { [weak self] in
            let rowsToMeasure = box.value
            if rowsToMeasure.count > 64 {
                // Many rows at once (a reset): two workers, not every core.
                let half = rowsToMeasure.count / 2
                DispatchQueue.concurrentPerform(iterations: 2) { part in
                    let slice = part == 0 ? rowsToMeasure[..<half] : rowsToMeasure[half...]
                    for row in slice { _ = TextLayout.layout(row, width: width, style: style) }
                }
            } else {
                for row in rowsToMeasure { _ = TextLayout.layout(row, width: width, style: style, keep: true) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.layoutInFlight = false
                // One visible step per measure: what was measured goes on screen, then the follow-up catches up
                // with the model (and measures again if the reply grew meanwhile). After a reset or relayout the
                // snapshot is stale: skip it.
                if generation == self.fillGeneration {
                    let d = ChatRowDiff.make(old: self.rows, new: measured.value)
                    if !d.isEmpty { self.apply(d, shown: measured.value) }
                }
                self.requestApply(urgent: true)
                if self.rows.isEmpty { self.updatePlaceholder(animated: true); self.pushIfWaiting() }
            }
        }
    }

    /// What measuring a row costs, roughly in characters: a tool row's wording reads its arguments (bounded).
    private static func measureCost(_ row: ChatRow) -> Int {
        switch row.kind {
        case .bubble(let b): return b.text.utf8.count
        case .toolRun(let t): return 80 + t.tools.reduce(0) { $0 + min($1.argsText?.utf8.count ?? 0, ChatRunSummary.argsParseLimit) }
        case .thought(let t): return 80 + (t.expanded ? t.text.utf8.count : 0)
        case .backgroundResult(let b): return 80 + (b.expanded ? b.result.utf8.count : 0)
        case .updateMember(let m): return 120 + (m.expanded ? m.full.utf8.count : 0)
        default: return 80
        }
    }

    private func layoutFor(_ index: Int, in shown: ArraySlice<ChatRow>) -> RowLayout {
        TextLayout.layout(shown[index], width: layoutWidth, style: style, keep: true)
    }

    /// Updates the cells of rows that changed in place. `reconfigureRows` also reaches cells the table prepared
    /// ahead of display (cell prefetching), which aren't among the visible rows and would keep stale content.
    private func reconfigure(_ changed: [Int]) {
        guard !changed.isEmpty else { return }
        tableView.reconfigureRows(at: changed.map { IndexPath(row: $0, section: 0) })
    }

    #if DEBUG
    private static let traceApply = ProcessInfo.processInfo.arguments.contains("-HQDemoTraceApply")
    private var heightQueries = 0
    #endif

    /// `shown`: the rows `d` was made against (`model.shown` then); every row and layout here comes from it.
    private func apply(_ d: ChatRowDiff, shown: ArraySlice<ChatRow>) {
        if d.isEmpty { return }
        let span = MainTrail.begin("chat.apply")          // [diagnostics] build 292
        defer {
            MainTrail.end(span)
            MainTrail.set("chatRows", "\(rows.count)", aged: false)
        }
        lastApplyTime = CACurrentMediaTime()
        #if DEBUG
        let started = lastApplyTime
        heightQueries = 0
        defer {
            if Self.traceApply {
                print(String(format: "[Apply] %.2f ms table=%d ins=%d del=%d chg=%d heights=%d", (CACurrentMediaTime() - started) * 1000,
                             rows.count, d.inserts.count, d.deletes.count, d.changed.count, heightQueries))
            }
        }
        #endif
        let oldCount = rows.count
        let targetCount = shown.count

        // Rows that changed in place and kept their heights need no table update at all: only their cells.
        if d.inserts.isEmpty && d.deletes.isEmpty && oldCount == targetCount && d.front + d.back >= oldCount {
            var fresh: [(Int, RowLayout)] = []
            var keepsHeights = true
            for i in d.changed {
                let l = layoutFor(i, in: shown)
                fresh.append((i, l))
                if abs(l.height - layouts[i].height) > 0.01 { keepsHeights = false }
            }
            if keepsHeights {
                for (i, l) in fresh { rows[i] = shown[i]; layouts[i] = l }
                UIView.performWithoutAnimation { reconfigure(d.changed) }
                if Self.traceRows { print("[Rows] reconfigure chg=\(d.changed)") }
                AppLog.trace("chatui", "apply \(logTag): 0 inserted, 0 removed, \(d.changed.count) updated, cells only (heights unchanged)")
                return
            }
        }

        activity.willApply()             // [activity] the fold's slide: where rows were
        // Where to hold the view still.
        let anchor = captureAnchor()
        // A lift that still carries the rows above (its offset share) hands what is left of it to the stream glide;
        // its stand-in keeps flying to wherever the bubble now rests.
        let liftCarry = lift?.drivesOffset == true ? max(0, tableView.contentOffset.y - minOffset) : 0
        if liftCarry > 0 || lift?.drivesOffset == true { lift?.drivesOffset = false }
        let glideCarry = streamLink != nil && streamTarget == nil ? max(0, tableView.contentOffset.y - minOffset) : liftCarry
        let holdGliding = streamLink != nil && streamTarget != nil
        let offsetBefore = tableView.contentOffset.y

        // New rows and layouts: replace the window, update changed rows in place.
        let windowNew = d.front..<(targetCount - d.back)
        let windowOld = d.front..<(oldCount - d.back)
        var windowLayouts: [RowLayout] = []
        windowLayouts.reserveCapacity(windowNew.count)
        var oldIndexById: [String: Int] = [:]
        for i in windowOld { oldIndexById[rows[i].id] = i }
        let changedSet = Set(d.changed)
        for i in windowNew {
            if let oi = oldIndexById[shown[i].id], !changedSet.contains(i) {
                windowLayouts.append(layouts[oi])
            } else {
                windowLayouts.append(layoutFor(i, in: shown))
            }
        }
        // The rows this update deletes, by id, read while `rows` still matches the table (see the batch below).
        let deletedIds = Set(d.deletes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        var outside: [(new: Int, old: Int, layout: RowLayout)] = []
        for i in d.changed where !windowNew.contains(i) {
            outside.append((i, i < d.front ? i : oldCount - (targetCount - i), layoutFor(i, in: shown)))
        }
        // Build 559 crash ("I unlocked my phone"): `rows` changes inside the batch, not before it. A table that takes a
        // text-size or Bold Text change in the batch (none laid out since: a background launch, the phone just unlocked)
        // drops its row counts and reads them again at the start; with `rows` already changed it read the new count as
        // the old one, and UIKit threw "Invalid batch updates detected".
        let commitRows = {
            for o in outside { self.rows[o.old] = shown[o.new]; self.layouts[o.old] = o.layout }
            self.rows.replaceSubrange(windowOld, with: shown[windowNew])
            self.layouts.replaceSubrange(windowOld, with: windowLayouts)
        }

        let bigChange = d.inserts.count + d.deletes.count > 400 && !d.deletes.isEmpty
        let reloadReason = bigChange ? "big change" : oldCount == 0 ? "table was empty" : tableView.window == nil ? "off screen" : nil
        var growth: CGFloat = 0
        var arrived: [Int] = []
        UIView.performWithoutAnimation {
            if bigChange || oldCount == 0 || tableView.window == nil {
                commitRows()
                tableView.reloadData()
                // Commit the reload now: a batch update queued on top of an uncommitted reload leaves ghost cells.
                tableView.layoutIfNeeded()
            } else {
                tableView.performBatchUpdates {
                    commitRows()
                    if !d.deletes.isEmpty { tableView.deleteRows(at: d.deletes.map { IndexPath(row: $0, section: 0) }, with: .none) }
                    if !d.inserts.isEmpty { tableView.insertRows(at: d.inserts.map { IndexPath(row: $0, section: 0) }, with: .none) }
                }
                // Verify round 2: a deleted row's cell stays in the table until the update's completion, a frame later,
                // where it was: the "Waiting for …" line drew over the question note that replaced it. It goes now.
                // Found among the table's subviews after the batch: asking the table for cells between a `rows`
                // change and the batch could make it lay out against rows it hasn't been told about yet.
                if !deletedIds.isEmpty {
                    let showing = Set(tableView.visibleCells.map(ObjectIdentifier.init))
                    for case let cell as ChatBaseCell in tableView.subviews
                    where cell.alpha > 0 && deletedIds.contains(cell.rowId) && !showing.contains(ObjectIdentifier(cell))
                        && tableView.indexPath(for: cell) == nil {
                        cell.alpha = 0
                    }
                }
                // Rows that changed in place (new indices): update their cells; the batch already re-read the heights.
                reconfigure(d.changed)
                arrived = d.inserts
            }
            growth = restore(anchor, carry: glideCarry)
        }
        AppLog.trace("chatui", "apply \(logTag): \(d.inserts.count) inserted, \(d.deletes.count) removed, \(d.changed.count) updated, "
                     + (reloadReason.map { "full reload (\($0)), not animated" } ?? "batch update, not animated"))
        if promptGapPending { promptGapPending = false; closePromptGap(growth) }   // [questions]
        if !arrived.isEmpty { tableView.layoutIfNeeded(); slideIn(arrived) }
        let slid = activity.didApply()   // [activity] rows that moved slide home; revealed steps fade in
        if Self.traceRows {
            print("[Rows] apply del=\(d.deletes.count) ins=\(d.inserts.count) chg=\(d.changed) f=\(d.front) b=\(d.back) table=\(tableView.numberOfRows(inSection: 0)) rows=\(rows.count) growth=\(growth)")
            for ip in tableView.indexPathsForVisibleRows ?? [] {
                let cellId = (tableView.cellForRow(at: ip) as? ChatBaseCell)?.rowId ?? "?"
                if cellId != rows[ip.row].id { print("[Rows] MISMATCH at \(ip.row): cell \(cellId) vs row \(rows[ip.row].id)") }
            }
        }
        // While a reply is live, new lines glide up instead of jumping (spec 06 §5.4). Growth is measured at the
        // newest end only (where a row on screen moved to), so rows added at the far end never glide.
        if slid && glideCarry < 0.5 {
            // [activity] The fold's slide moves the rows (the reply's action row with them): no glide on top of it.
        } else if case .bottom = anchor, following, glideLink == nil {
            if pendingLift != nil, beginLift(growth: max(0, growth) + glideCarry) {
                // The send lift carries the rows above and the new bubble (spec 06 §5.2: no stream glide during it).
            } else if growth > 0.5 && isLiveForGlide {
                startStreamGlide(carry: glideCarry, growth: growth)
            } else if glideCarry > 0 {
                startStreamGlide(carry: glideCarry, growth: 0)
            }
        } else if holdGliding, case .row = anchor, streamLink != nil, let target = streamTarget {
            // More of the reply landed while it glides to its hold: the hold (its top at the bar) moved with it.
            streamTarget = target + (tableView.contentOffset.y - offsetBefore)
        } else if streamLink != nil, streamTarget == nil {
            stopStreamGlide()
        }
        updateJumpButton()
        loadOlderIfNear()
        revealIfNeeded()
        if following { scheduleTrim() }
        updatePlaceholder(animated: true)
        pushIfWaiting()
        if pendingFindRow != nil { scrollToPendingFind() }   // MENUS: a find match that just reached the table
    }

    // MARK: Stream glide

    private var streamLink: CADisplayLink?
    /// Where the glide ends: nil = the live end; set = the held reply's position (its top 4 pt under the bar), so the
    /// step that engages the hold glides there instead of jumping (verification round 2: up to 264 pt in one frame).
    private var streamTarget: CGFloat?
    private var streamFrom: CGFloat = 0
    private var streamClock = GlideClock()
    private var streamDuration: CFTimeInterval = 0.2
    private var streamCurve = UnitBezier(0.22, 0.8, 0.25, 1)
    private var runningEndedAt: CFTimeInterval = 0
    /// Reply, thought and tool lines that have had their entrance (`useEnterAnimation`'s played keys).
    private var entered = Set<String>()

    /// The desktop's entrance (V:lib/use-enter-animation.ts): a reply, a thought or a tool line that arrives while the
    /// turn runs rises 0.375 rem into place over 180 ms on cubic-bezier(0.16, 1, 0.3, 1). A move only, never a fade or
    /// a height, once per line (a reply's later paragraphs don't replay it); none under Reduce Motion.
    private func slideIn(_ inserts: [Int]) {
        guard session.isRunning, !HQMotion.reduced else { return }
        for i in inserts where i < rows.count {
            let row = rows[i]
            let key: String
            switch row.kind {
            case .bubble(let b) where !b.mine: key = "reply:" + row.messageId
            case .toolRun, .thought, .activity: key = row.id
            default: continue
            }
            guard !entered.contains(key), let cell = tableView.cellForRow(at: IndexPath(row: i, section: 0)) else { continue }
            entered.insert(key)
            let rise = CABasicAnimation(keyPath: "transform.translation.y")   // HQMotion.reduced checked above
            rise.fromValue = -6                                             // the table is flipped: below on screen
            rise.toValue = 0
            rise.duration = 0.18
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            rise.fillMode = .backwards
            cell.layer.add(rise, forKey: "enter")
        }
    }

    /// A live turn, a send in the last 2 s, or within 1.5 s after a turn ended (late layout).
    private var isLiveForGlide: Bool {
        let now = CACurrentMediaTime()
        return session.isRunning || now - lastSendTime < 2 || now - runningEndedAt < 1.5
    }

    /// Growth ≤ 44 pt glides over 200 ms, ≤ 110 over 320, ≤ 280 over 420; more is instant. A growth that lands
    /// mid-glide carries on from where the text is.
    private func startStreamGlide(carry: CGFloat, growth: CGFloat) {
        let total = carry + growth
        guard total > 0.5, total <= 280, !HQMotion.reduced else { stopStreamGlide(); return }
        streamTarget = nil
        if growth > 0.5 {
            streamDuration = total <= 44 ? 0.2 : total <= 110 ? 0.32 : 0.42
            streamCurve = total <= 44 ? UnitBezier(0.22, 0.8, 0.25, 1) : UnitBezier(0.3, 0.1, 0.2, 1)
            streamClock.start()
            streamFrom = total
        }
        ensureHeadroom(for: minOffset + total)
        tableView.contentOffset.y = minOffset + total
        if streamLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(streamStep(_:)))   // motion-ok: the glide is refused under Reduce Motion in the guard above
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            streamLink = link
        }
    }

    /// How far the stream glide still has to go now.
    private var streamRemaining: CGFloat {
        let t = min(1, streamClock.peek() / streamDuration)
        return streamFrom * (1 - CGFloat(streamCurve.solve(t)))
    }

    @objc private func streamStep(_ link: CADisplayLink) {
        let t = min(1, streamClock.tick() / streamDuration)
        let remaining = streamFrom * (1 - CGFloat(streamCurve.solve(t)))
        tableView.contentOffset.y = (streamTarget ?? minOffset) + remaining
        if Self.traceScroll {
            print(String(format: "[Scroll] glide %@ offset=%.1f remaining=%.1f t=%.2f", streamTarget == nil ? "end" : "hold",
                         tableView.contentOffset.y, remaining, t))
        }
        if t >= 1 { stopStreamGlide() }
    }

    /// The growth step that engages the hold glides from where the text was to the hold, with the stream glide's
    /// timing for that distance (spec 06 §5.4: growth up to 280 pt glides).
    private func startHoldGlide(from start: CGFloat, to hold: CGFloat) {
        let distance = start - hold
        guard distance > 0.5, distance <= 280, !HQMotion.reduced else {
            stopStreamGlide()
            tableView.contentOffset.y = hold
            return
        }
        streamDuration = distance <= 44 ? 0.2 : distance <= 110 ? 0.32 : 0.42
        streamCurve = distance <= 44 ? UnitBezier(0.22, 0.8, 0.25, 1) : UnitBezier(0.3, 0.1, 0.2, 1)
        streamClock.start()
        streamFrom = distance
        streamTarget = hold
        ensureHeadroom(for: start)
        tableView.contentOffset.y = start
        if streamLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(streamStep(_:)))   // motion-ok: the glide is refused under Reduce Motion in the guard above
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            streamLink = link
        }
    }

    private func stopStreamGlide() {
        streamLink?.invalidate()
        streamLink = nil
        streamTarget = nil
        releaseHeadroom()
    }

    // MARK: Send lift (spec 06 §5.2)

    /// A send waiting for its bubble's first apply: the message and where the draft's text was drawn (view coordinates).
    private var pendingLift: (messageId: String, source: CGRect, at: CFTimeInterval)?

    /// The bubble rises from the composer: its text starts on the draft's (last line on the draft's last line, first
    /// character on the draft's), solid, while the bubble opens out around it; the rows above rise with it. A stand-in
    /// flies above the composer (the field's glass would blur the real row) and hands over to the row at the end.
    private struct Lift {
        var rowId: String
        var standIn: ChatBubbleCell
        /// The start minus the real row's live place when the lift began (screen points, the rows' rise included): the
        /// stand-in sits at the row's live place plus this × (1 − progress), so it lands exactly on the row wherever the
        /// row ends up (a reply that lands mid-lift hands the rows' rise to the stream glide).
        var delta: CGPoint
        /// The rows' rise (content offset still owed) while the lift drives the offset.
        var growth: CGFloat
        var drivesOffset = true
        /// The tight shape around the text, inside the bubble (pad 6), opening to 24 pt beyond it.
        var startInsets: UIEdgeInsets
        var start: CFTimeInterval?
        var last: CFTimeInterval = 0
    }
    private var lift: Lift?
    private var liftLink: CADisplayLink?
    static let liftDuration: CFTimeInterval = 0.34
    private static let liftCurve = UnitBezier(0.22, 0.8, 0.25, 1)

    /// Starts the lift for the pending send if its bubble is in the table (called right after the apply that added
    /// it, with the content offset at the end). `growth`: how far the rows above moved up.
    private func beginLift(growth: CGFloat) -> Bool {
        guard let pending = pendingLift else { return false }
        if CACurrentMediaTime() - pending.at > 0.5 { pendingLift = nil; return false }
        guard let index = rows.lastIndex(where: { row in
            guard row.messageId == pending.messageId, case .bubble = row.kind else { return false }
            return true
        }) else { return false }        // not in this apply: wait for the one that brings it
        pendingLift = nil
        endLift()
        guard index < layouts.count, case .bubble(let b) = layouts[index].content else { return false }
        // [attachments] A bubble with photos or files lifts out of the tray and the text box together, and not at all
        // when it is taller than 60 % of the screen (docs/spec/1x-attachments.md §6.4 step 2).
        let hasMedia = !b.mediaGroups.isEmpty || !b.fileRows.isEmpty
        let target = hasMedia ? AttachmentBubbleLayout.liftBox(b, text: ChatBubbleCell.textBox(b)) : ChatBubbleCell.textBox(b)
        guard let text = target, view.window != nil, !HQMotion.reduced,
              !(hasMedia && layouts[index].height > view.bounds.height * 0.6),
              layouts[index].height < (composer.frame.minY - view.safeAreaInsets.top) * 0.7 else { return false }
        tableView.layoutIfNeeded()
        guard let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? ChatBubbleCell else { return false }
        let rest = cell.contentView.convert(cell.contentView.bounds, to: view)
        let source = pending.source
        // `rest` is the row at the end (offset at its minimum); the lift starts with the rows `growth` lower.
        let delta = CGPoint(x: source.minX - (rest.minX + text.minX), y: source.maxY - (rest.minY + text.maxY) - growth)
        let pad: CGFloat = 6
        var inBubble = text.offsetBy(dx: -b.frame.minX, dy: -b.frame.minY)
        if hasMedia {
            // [attachments] The bubble opens out from the tray's size at its leading bottom: the photos rise out of it.
            let w = min(inBubble.width, source.width), h = min(inBubble.height, source.height)
            inBubble = CGRect(x: inBubble.minX, y: inBubble.maxY - h, width: w, height: h)
        }
        let startInsets = UIEdgeInsets(top: max(0, inBubble.minY - pad), left: max(0, inBubble.minX - pad),
                                       bottom: max(0, b.frame.height - inBubble.maxY - pad),
                                       right: max(0, b.frame.width - inBubble.maxX - pad))
        let standIn = ChatBubbleCell.liftStandIn(rows[index], layout: layouts[index], width: rest.width, host: view, above: composer)
        cell.contentView.isHidden = true
        stopStreamGlide()
        lift = Lift(rowId: rows[index].id, standIn: standIn, delta: delta, growth: growth, startInsets: startInsets)
        ensureHeadroom(for: minOffset + growth)
        renderLift(progress: 0)
        let link = CADisplayLink(target: self, selector: #selector(liftStep(_:)))   // motion-ok: the lift is refused under Reduce Motion in the guard above
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        liftLink = link
        updateJumpButton()
        if Self.traceScroll {
            print(String(format: "[Lift] begin row=%@ delta=(%.1f, %.1f) growth=%.1f", rows[index].id, delta.x, delta.y, growth))
        }
        return true
    }

    /// One frame of the lift at eased progress `e` (0 → 1).
    private func renderLift(progress e: CGFloat) {
        guard let l = lift else { return }
        let r = 1 - e
        if l.drivesOffset { tableView.contentOffset.y = minOffset + l.growth * r }
        guard let index = rows.firstIndex(where: { $0.id == l.rowId }),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) else {
            endLift()
            return
        }
        if !cell.contentView.isHidden { cell.contentView.isHidden = true }   // reconfigured or a new cell
        // The real row's live place (it moves with the offset), plus the share of the flight still to go.
        let live = cell.contentView.convert(cell.contentView.bounds, to: view)
        l.standIn.frame = CGRect(x: live.minX + l.delta.x * r, y: live.minY + l.delta.y * r, width: live.width, height: live.height)
        let s = l.startInsets
        let open: CGFloat = -24
        l.standIn.setReveal(UIEdgeInsets(top: s.top + (open - s.top) * e, left: s.left + (open - s.left) * e,
                                         bottom: s.bottom + (open - s.bottom) * e, right: s.right + (open - s.right) * e))
    }

    @objc private func liftStep(_ link: CADisplayLink) {
        guard var l = lift else { link.invalidate(); liftLink = nil; return }
        let now = link.timestamp
        if l.start == nil { l.start = now; l.last = now }
        // Start on the first calm frame (spec 06 §5.2): a long frame early on doesn't eat into the motion.
        let gap = now - l.last
        if gap > link.duration * 1.5, now - (l.start ?? now) < 0.25 { l.start = (l.start ?? now) + gap - link.duration }
        l.last = now
        lift = l
        let t = min(1, max(0, (link.targetTimestamp - (l.start ?? now)) / Self.liftDuration))
        renderLift(progress: CGFloat(Self.liftCurve.solve(t)))
        if Self.traceScroll {
            print(String(format: "[Lift] t=%.2f offset=%.1f min=%.1f standIn=%.1f", t, tableView.contentOffset.y, minOffset,
                         lift?.standIn.frame.minY ?? -1))
        }
        if t >= 1 { endLift() }
    }

    /// Ends the lift where it is headed: the row shows again, the stand-in goes.
    private func endLift() {
        liftLink?.invalidate()
        liftLink = nil
        guard let l = lift else { return }
        lift = nil
        l.standIn.removeFromSuperview()
        for cell in tableView.visibleCells where cell.contentView.isHidden { cell.contentView.isHidden = false }
        if let index = rows.firstIndex(where: { $0.id == l.rowId }),
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) { cell.contentView.isHidden = false }
        if l.drivesOffset, following, glideLink == nil, streamLink == nil { tableView.contentOffset.y = minOffset }
        releaseHeadroom()
        updateBottomEdge()
        updateJumpButton()
    }

    // MARK: Holding the view still

    private struct RowRef {
        let id: String
        let index: Int
        /// The row's visual top in content coordinates (rect.maxY: the table is flipped).
        let maxY: CGFloat
    }

    private enum Anchor {
        /// Following the newest end. `refs`: rows on screen, to measure how far content moved at the newest end.
        case bottom(refs: [RowRef])
        /// Hold this row's visual top where it is (`top` = its maxY minus the offset). `fallbacks`: the rows under it on
        /// screen, held instead when an update replaced it (a Tool Calls style switch rebuilds a step block under new ids).
        case row(id: String, index: Int, top: CGFloat, fallbacks: [(id: String, index: Int, top: CGFloat)] = [])
    }

    private var minOffset: CGFloat { -tableView.contentInset.top }

    /// The transcript's top inset (the bar and the status line; the flipped table's `contentInset.bottom` less
    /// `glideHeadroom`).
    private var topInset: CGFloat = 0
    /// Room past the oldest row while a glide or the send lift holds the rows above their resting place. Verify round 2:
    /// in a chat shorter than the screen that offset lay past the end of the content, and UIKit pulled it back whenever
    /// it laid the table out — the rows showed at their final place for a frame and the motion started again from
    /// below (the memo bubble's restarts, the one-frame flash on a send or a reply's arrival).
    private var glideHeadroom: CGFloat = 0
    /// A width change seen while a pop-up came or went waits for its end (`viewDidLayoutSubviews`).
    private var widthCheckQueued = false
    #if targetEnvironment(macCatalyst)
    /// [mac-audit #4] A width change held back: off screen, or inside a live resize (`holdsWidthRelayout`).
    private var widthSettle: DispatchWorkItem?
    private var lastWidthChange: CFTimeInterval = 0
    private var widthSettled = false
    private var widthHeldOffScreen = false
    #endif

    /// [mac-audit #4] Owner 2026-11-02: dragging the Mac window's edge stalled it 0.3–0.9 s, each step of the live
    /// resize a full relayout (106 of them on Mac 650–667, `main.hang … window.resize×7`), and chats not in the window
    /// did the same. A chat off screen only notes the change and lays out once it is shown again; one on screen lays
    /// out at once for a single change (the sidebar folding, a chat opening) but holds back while the window is being
    /// resized, or while changes keep coming within 0.3 s, until the width has rested 150 ms. Meanwhile the rows keep
    /// their old width (centred in the pane as before) and only the composer follows the edge.
    private func holdsWidthRelayout() -> Bool {
        #if targetEnvironment(macCatalyst)
        guard let window = view.window else {
            widthHeldOffScreen = true
            return true
        }
        let now = CACurrentMediaTime()
        let resizing = window.windowScene?.effectiveGeometry.isInteractivelyResizing == true
        let soon = now - lastWidthChange < 0.3
        lastWidthChange = now
        if !widthSettled && (resizing || soon) {
            widthSettle?.cancel()
            let settle = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.widthSettle = nil
                self.widthSettled = true
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
                self.widthSettled = false
            }
            widthSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
            return true
        }
        widthSettle?.cancel()
        widthSettle = nil
        return false
        #else
        return false
        #endif
    }

    /// Makes `offset` reachable for the motion about to start (a no-op when the chat is taller than the screen).
    private func ensureHeadroom(for offset: CGFloat) {
        let maxOffset = tableView.contentSize.height + topInset - tableView.bounds.height
        let need = ceil(max(0, offset - maxOffset)) + 1
        guard offset > maxOffset, need > glideHeadroom else { return }
        glideHeadroom = need
        tableView.contentInset.bottom = topInset + glideHeadroom
    }

    /// The motion is over: the extra room goes, once nothing sits in it.
    private func releaseHeadroom() {
        guard glideHeadroom > 0, streamLink == nil, liftLink == nil, glideLink == nil else { return }
        let maxOffset = max(minOffset, tableView.contentSize.height + topInset - tableView.bounds.height)
        guard tableView.contentOffset.y <= maxOffset + 0.5 else { return }
        glideHeadroom = 0
        tableView.contentInset.bottom = topInset
    }

    private var isAtBottom: Bool { tableView.contentOffset.y <= minOffset + 2 }

    private func visibleRefs() -> [RowRef] {
        guard let visible = tableView.indexPathsForVisibleRows else { return [] }
        return visible.sorted { $0.row > $1.row }.prefix(6).compactMap { ip in
            ip.row < rows.count ? RowRef(id: rows[ip.row].id, index: ip.row, maxY: tableView.rectForRow(at: ip).maxY) : nil
        }
    }

    private func captureAnchor() -> Anchor {
        if let hold = holdRowId, let index = rows.firstIndex(where: { $0.id == hold }) {
            holdRowId = nil
            let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
            return .row(id: hold, index: index, top: rect.maxY - tableView.contentOffset.y)
        }
        if following || rows.isEmpty { return .bottom(refs: visibleRefs()) }
        // The row at the visual top of the screen (the highest index on screen), and the rows under it as fallbacks.
        guard let visible = tableView.indexPathsForVisibleRows, let top = visible.max(by: { $0.row < $1.row }) else {
            return .bottom(refs: [])
        }
        let rect = tableView.rectForRow(at: top)
        let fallbacks = visible.filter { $0.row != top.row && $0.row < rows.count }.sorted { $0.row > $1.row }.prefix(8).map { ip in
            (id: rows[ip.row].id, index: ip.row, top: tableView.rectForRow(at: ip).maxY - tableView.contentOffset.y)
        }
        return .row(id: rows[top.row].id, index: top.row, top: rect.maxY - tableView.contentOffset.y, fallbacks: Array(fallbacks))
    }

    /// Puts the view back where the anchor says. For `.bottom`, returns how far the content on screen moved up
    /// (growth at the newest end).
    /// `carry`: how far a stream glide still had to go when the update landed (where the text was, above the end).
    @discardableResult
    private func restore(_ anchor: Anchor, carry: CGFloat = 0) -> CGFloat {
        switch anchor {
        case .bottom(let refs):
            var growth: CGFloat = 0
            for ref in refs {
                if let index = findRow(ref.id, near: ref.index) {
                    growth = tableView.rectForRow(at: IndexPath(row: index, section: 0)).maxY - ref.maxY
                    break
                }
            }
            if Self.traceScroll {
                print(String(format: "[Scroll] restore(.bottom) growth=%.1f glide=%d offset=%.1f min=%.1f", growth,
                             glideLink != nil ? 1 : 0, tableView.contentOffset.y, minOffset))
            }
            if glideLink != nil {
                // The jump glide owns the offset and lands on the live end by itself. Keep what's on screen still
                // (move by the growth) and let the glide carry on from there.
                if abs(growth) > 0.01 {
                    tableView.contentOffset.y += growth
                    glideStart = (GlideClock.started(), tableView.contentOffset.y)
                }
                AppLog.trace("scroll", "restore \(logTag): jump glide in flight, growth=\(Int(growth))")
            } else {
                tableView.contentOffset.y = minOffset
                AppLog.trace("scroll", "restore \(logTag): stayed pinned to bottom, growth=\(Int(growth))")
                // Where the text was before this update: the hold, if it engages, glides from there.
                holdReplyTopIfNeeded(glideFrom: isLiveForGlide ? minOffset + carry + max(0, growth) : nil)
            }
            return growth
        case .row(let id, let guess, let held, let fallbacks):
            // The first of the rows on screen that the update kept (verify round 2: a style switch replaced the top
            // row's step block, the hold fell through, and the row being read moved by the block's change in height).
            var found: (index: Int, top: CGFloat)?
            for ref in [(id: id, index: guess, top: held)] + fallbacks {
                if let index = findRow(ref.id, near: ref.index) { found = (index, ref.top); break }
            }
            guard let (index, top) = found else {
                AppLog.trace("scroll", "restore \(logTag): held row gone, \(following ? "back to bottom" : "left where it was")")
                if following && glideLink == nil { tableView.contentOffset.y = minOffset }
                return 0
            }
            let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
            let maxOffset = max(minOffset, tableView.contentSize.height + topInset - tableView.bounds.height)
            tableView.contentOffset.y = min(maxOffset, max(minOffset, rect.maxY - top))
            if following && !isAtBottom { following = false }
            AppLog.trace("scroll", "restore \(logTag): kept the reader's place at row \(index)")
            return 0
        }
    }

    private func findRow(_ id: String, near guess: Int) -> Int? {
        if rows.isEmpty { return nil }
        let g = min(max(0, guess), rows.count - 1)
        for delta in 0..<rows.count {
            let a = g + delta, b = g - delta
            if a < rows.count, rows[a].id == id { return a }
            if b >= 0, rows[b].id == id { return b }
            if a >= rows.count && b < 0 { break }
        }
        return nil
    }

    /// While following a new reply: once its top would pass under the bar, stop following and keep the top in
    /// place, 4 pt below the bar (spec 06 §5.3).
    private func holdReplyTopIfNeeded(glideFrom start: CGFloat? = nil) {
        guard following, glideLink == nil, let anchorId = anchorMessageId else { return }
        var top: Int?
        for i in 0..<min(rows.count, 400) where rows[i].messageId == anchorId { top = i }
        guard let top else { return }
        let replyTop = tableView.rectForRow(at: IndexPath(row: top, section: 0)).maxY
        let visibleTop = tableView.contentOffset.y + tableView.bounds.height - topInset
        if replyTop + 4 > visibleTop {
            following = false
            stopStreamGlide()
            let hold = replyTop + 4 - tableView.bounds.height + topInset
            if Self.traceScroll { print(String(format: "[Scroll] hold engages: from %.1f to %.1f", start ?? -1, hold)) }
            AppLog.trace("scroll", "hold engages \(logTag): reply passed the bar, following stopped")
            if let start, start > hold + 0.5 {
                startHoldGlide(from: start, to: hold)
            } else {
                tableView.contentOffset.y = hold
            }
        }
    }

    // MARK: Background fill of older rows

    /// Measures hidden rows (in order from the shown boundary), then builds older messages in chunks, one serial
    /// utility job at a time. Nothing here touches the table: rows are shown by `revealIfNeeded` as the reader nears
    /// them, so the fill never lands on the main thread in big applies.
    private func startFill() {
        guard didAppear, isViewLoaded, !fillInFlight else { return }
        if let batch = model.nextToMeasure(max: Self.fillBatch), let firstId = batch.first?.id {
            fillInFlight = true
            fillDoneLogged = false
            let box = UncheckedSendable(Array(batch))
            let width = layoutWidth, style = style, generation = fillGeneration
            fillQueue.async { [weak self] in
                for row in box.value { _ = TextLayout.layout(row, width: width, style: style) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fillInFlight = false
                    if generation == self.fillGeneration { self.model.markMeasured(box.value.count, firstId: firstId) }
                    self.revealIfNeeded()
                    self.startFill()
                }
            }
            return
        }
        if let range = model.nextChunk(size: Self.chunkMessages) {
            buildChunk(range)
            return
        }
        if !fillDoneLogged {
            fillDoneLogged = true
            ChatPerf.mark("chat.fill.done rows=\(rows.count) built=\(model.allRows.count)")
        }
    }

    /// Builds and measures older messages off the main thread; their rows join the hidden old end.
    private func buildChunk(_ range: Range<Int>) {
        ChatPerf.mark("chat.buildChunk \(range)")
        fillInFlight = true
        fillDoneLogged = false
        let snapshot = input()
        let generation = model.generation, fill = fillGeneration
        let width = layoutWidth, style = style
        fillQueue.async { [weak self] in
            let built = ChatRowBuilder.build(snapshot, range: range)
            for row in built { _ = TextLayout.layout(row, width: width, style: style) }
            let box = UncheckedSendable(built)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fillInFlight = false
                self.model.appendBuilt(box.value, range: range, generation: generation, measured: fill == self.fillGeneration)
                self.revealIfNeeded()
                self.startFill()
            }
        }
    }

    /// Near the oldest shown row (within 2 screens): show more rows at the old end. Measured rows show at once; with
    /// none measured yet, the reader at the very end gets rows measured off the main thread first.
    private func revealIfNeeded() {
        guard didAppear, isViewLoaded, !revealing, !layoutInFlight, model.hiddenOlder > 0 else { return }
        let h = max(1, tableView.bounds.height)
        let remaining = tableView.contentSize.height + topInset - (tableView.contentOffset.y + h)
        guard remaining < h * 2 else { return }
        let average = rows.isEmpty ? 60 : max(16, tableView.contentSize.height / CGFloat(rows.count))
        var count = max(40, Int(h * 4 / average), rows.count / 2)
        if model.measuredHidden > 0 {
            count = min(count, model.measuredHidden)
        } else if remaining > h / 2 {
            return   // the fill measures them first
        }
        revealing = true
        model.reveal(count)
        requestApply(urgent: true)
        revealing = false
    }

    /// Back at the newest end: hide the old rows beyond six screens again, so the table stays small while replies
    /// stream. Runs when scrolling settles (its timer doesn't fire while a finger is down).
    private func scheduleTrim() {
        guard rows.count > 160 else { return }
        trimTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.trimIfFar() } }
        RunLoop.main.add(timer, forMode: .default)
        trimTimer = timer
    }

    private func trimIfFar() {
        trimTimer = nil
        guard isViewLoaded, !layoutInFlight, glideLink == nil, !tableView.isTracking, !tableView.isDecelerating else { return }
        let h = max(1, tableView.bounds.height)
        let fromEnd = tableView.contentOffset.y - minOffset + h      // content from the newest end to the screen's top
        guard fromEnd < h * 2 else { return }
        var y: CGFloat = 0, keep = 0
        while keep < layouts.count && (y < fromEnd + h * 6 || keep < 40) {
            y += layouts[keep].height
            keep += 1
        }
        guard rows.count > keep + max(100, keep / 2) else { return }
        ChatPerf.mark("chat.trim \(rows.count) → \(keep)")
        model.hide(keeping: keep)
        requestApply(urgent: true)
    }

    /// Width or text size changed: measure the newest screen again synchronously and refill the rest.
    private var themeWatch: NSObjectProtocol?      // [desktoplook]
    private var backdropWatch: NSObjectProtocol?   // [backdrop]
    private var muteWatch: UUID?                   // UX study #248: the title's muted bell

    #if DEBUG
    /// [mac-audit B] Full relayouts so far, for `-HQDebugMacShotsResize`.
    static var debugRelayouts = 0
    func debugRelayout() { relayoutEverything(reason: "debug") }
    #endif

    private func relayoutEverything(reason: String) {
        #if DEBUG
        Self.debugRelayouts += 1
        #endif
        let span = MainTrail.begin("chat.relayout")       // [diagnostics] build 292
        defer { MainTrail.end(span) }
        endLift()
        fillGeneration += 1
        let height = view.bounds.height > 0 ? view.bounds.height : 874
        TextLayout.screenHeight = view.window?.bounds.height ?? TextLayout.screenHeight   // [m9/ipad] the window's, not the screen's
        model.rebuildAll(input(), syncMessages: Self.syncBuildMessages, oldestShown: nil)
        layoutInitialScreen(height: height)
        UIView.performWithoutAnimation { tableView.reloadData(); tableView.layoutIfNeeded() }
        following = true
        tableView.contentOffset.y = minOffset
        fillDoneLogged = false
        AppLog.trace("chatui", "apply \(logTag): full reload (\(reason)), not animated, \(rows.count) rows")
        startFill()
    }

    // MARK: Scrolling

    /// [mac] The bar's backing (`barBacking`): how far the transcript reaches up under the bar sets how much shows.
    private func updateBarBacking() {
        #if targetEnvironment(macCatalyst)
        guard barBacking.superview != nil else { return }
        let barBottom = view.safeAreaInsets.top
        let height = barBottom + 16
        let frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        if barBacking.frame != frame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            barBacking.frame = frame
            barBackingFade.frame = barBacking.bounds
            barBackingFade.locations = [0, NSNumber(value: Double(barBottom / max(height, 1))), 1]
            CATransaction.commit()
        }
        barBacking.backgroundColor = ChatPalette.page
        // The table is flipped: the end of its content is the transcript's top on screen.
        let contentTop = tableView.convert(CGPoint(x: 0, y: tableView.contentSize.height), to: view).y
        let under = barBottom - contentTop
        // Owner 2026-11-09 ("Why no top bar here?"): over a chat background too. It was left clear there so the picture
        // showed behind the bar, and the messages ran through the bot's name and the bar's buttons; the picture still
        // shows there while nothing is under the bar. There it is the blur (`barBlur`), reaching a little further down.
        let alpha = min(max(under / 10, 0), 1)
        let picture = Backdrop.chats.shows
        let solidAlpha = picture ? 0 : alpha
        if barBacking.alpha != solidAlpha { barBacking.alpha = solidAlpha }
        let blurHeight = barBottom + 28
        let blurFrame = CGRect(x: 0, y: 0, width: view.bounds.width, height: blurHeight)
        if barBlur.frame != blurFrame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            barBlur.frame = blurFrame
            barBlurMask.frame = barBlur.bounds
            barBlurFade.frame = barBlurMask.bounds
            barBlurFade.locations = [0, NSNumber(value: Double(barBottom / max(blurHeight, 1))), 1]
            CATransaction.commit()
        }
        let blurAlpha = picture ? alpha : 0
        if barBlur.alpha != blurAlpha { barBlur.alpha = blurAlpha }
        // The notice's backing: from the top down past the notice, in at the notice's pace and out at its fade.
        let noticeBottom = noticeToast.frame.maxY
        let noticeFrame = CGRect(x: 0, y: 0, width: view.bounds.width, height: noticeBottom + 16)
        if noticeBacking.frame != noticeFrame, noticeBottom > 0 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            noticeBacking.frame = noticeFrame
            noticeBackingFade.frame = noticeBacking.bounds
            noticeBackingFade.locations = [0, NSNumber(value: Double(noticeBottom / noticeFrame.height)), 1]
            CATransaction.commit()
        }
        noticeBacking.backgroundColor = ChatPalette.page
        let covers: CGFloat = noticeToast.isShowing && contentTop < noticeBottom ? 1 : 0
        if noticeBacking.alpha != covers {
            HQMotion.animate(covers > 0 ? 0.2 : 0.3, options: [.beginFromCurrentState], changes: { self.noticeBacking.alpha = covers })
        }
        #endif
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isDecelerating { lastMomentum = CACurrentMediaTime() }
        updateBarBacking()
        let y = scrollView.contentOffset.y
        if abs(y - lastWarmOffset) > 1 {
            warmAhead(towardOlder: y > lastWarmOffset)
            lastWarmOffset = y
        }
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            if scrollView.isTracking { leadPinEnded = true }   // [tasks] your scroll wins
            let atBottom = isAtBottom
            if atBottom != following {
                following = atBottom
                if atBottom { anchorMessageId = nil; unseen = 0; jumpButton.setCount(0) }
            }
        }
        updateJumpButton()
        updateBottomEdge()
        if glideHeadroom > 0 { releaseHeadroom() }
        loadOlderIfNear()
        revealIfNeeded()
        let tall = tableView.bounds.height
        for cell in tableView.visibleCells where cell.bounds.height > tall {
            (cell as? ChatBaseCell)?.updateWindowRect(in: tableView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleTrim() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleTrim() }
    }

    /// Within six screens of the oldest loaded row (counting built rows not shown yet at their average height), with
    /// every message built: page older history in. Waiting until every built row was shown and the reader was 1.5
    /// screens from the end left ~0.13 s of runway at 10,000 pt/s, and a fast flick ran into the end of the loaded
    /// rows at a page boundary (verification round 2). Also checked after updates, since a reader parked at the end
    /// produces no scroll events.
    private func loadOlderIfNear() {
        let table = tableView
        let h = max(1, table.bounds.height)
        let remaining = table.contentSize.height + topInset - (table.contentOffset.y + h)
        let average = rows.isEmpty ? 60 : max(16, table.contentSize.height / CGFloat(rows.count))
        let ahead = remaining + CGFloat(model.hiddenOlder) * average
        if ahead < h * 6 && model.builtFrom == 0 && session.hasOlder && !session.isLoadingOlder {
            ChatPerf.mark(String(format: "chat.loadOlder ahead %.1f screens (shown rows %.1f)", ahead / h, remaining / h))
            session.loadOlder()
        }
        updateEarlierPill(remaining: remaining)
    }

    // MARK: [transcript] Earlier messages (docs/spec/3x-transcript.md §4.2)

    private func installEarlierPill() {
        earlierPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(earlierPill)
        NSLayoutConstraint.activate([
            earlierPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            earlierPill.topAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: 8),
            earlierPill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            earlierPill.widthAnchor.constraint(lessThanOrEqualToConstant: ReadableColumn.maxWidth - 48),
        ])
        earlierPill.onLoad = { [weak self] in
            guard let self else { return }
            if let paging = self.session as? ChatOlderPaging, paging.olderFailed { paging.retryOlder() } else { self.session.loadOlder() }
            self.loadOlderIfNear()
        }
    }

    /// Shown only while the reader is at the top of what is loaded (every built row on show) and there is more before it.
    private func updateEarlierPill(remaining: CGFloat) {
        let atTop = remaining < 120 && model.builtFrom == 0 && model.hiddenOlder == 0 && !rows.isEmpty
        let failed = (session as? ChatOlderPaging)?.olderFailed == true
        let state: ChatEarlierPill.State
        // While finding, the find bar's own Search Earlier Messages row pages earlier messages in instead.
        if !atTop || !session.hasOlder || findInset > 0 || transcriptCovered { state = .hidden }
        else if session.isLoadingOlder { state = .loading }
        else if failed { state = .failed }
        else { state = .idle }
        let offline: Bool = if case .offline = session.connection { true } else { false }
        earlierPill.set(state, offline: offline)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === tableView, !rows.isEmpty { onEngage?(.drag) }   // [tasks] the pinned panel rolls up
        endLift()
        stopGlide()
        stopStreamGlide()
        trimTimer?.invalidate()
        trimTimer = nil
    }

    private func updateJumpButton() {
        defer { voice.talkTipCheck() }   // [talk] the Talk tip steps aside for the jump button
        if streamLink != nil || lift != nil { jumpButton.setShown(false); return }
        if promptDockCrowdsJump { jumpButton.setShown(false); return }   // [questions]
        if transcriptCovered { jumpButton.setShown(false); return }   // [tasks] the task covers the chat
        if lead != nil, rows.isEmpty { jumpButton.setShown(false); return }   // [tasks] a task's page, no chat yet: nothing newer
        #if DEBUG
        // [desktop-frost] Screenshots of the approval state: `-HQDebugJumpApproval YES` shows it as if one waited.
        if UserDefaults.standard.bool(forKey: "HQDebugJumpApproval") { jumpButton.setApproval(true); jumpButton.setShown(true); return }
        #endif
        let approvalOut = approvalOutOfSight
        jumpButton.setApproval(approvalOut)
        if approvalOut { jumpButton.setShown(true); return }
        // DECISION (L422): with the approval's buttons in sight the plain jump arrow would sit over Run; the card is the
        // newest thing in the chat, so there is nothing below it to jump to.
        if approvalIndex != nil, promptDock == nil { jumpButton.setShown(false); return }
        let away = tableView.contentOffset.y - minOffset > 120
        jumpButton.setShown(away || (!following && glideLink == nil && tableView.contentOffset.y - minOffset > 2))
    }

    // MARK: Jump to approval (L422)

    private var approvalIndex: Int? { rows.firstIndex { $0.id == "\(PromptRows.tailMessageId)|approval" } }

    /// The approval's Run / Reject row, in this view's coordinates; nil when its cell is not on screen.
    private func approvalActionsRect() -> CGRect? {
        guard let index = approvalIndex, let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? ChatPromptCell else { return nil }
        return cell.actionsRect(in: view)
    }

    /// An approval waits and its buttons are not wholly between the bar and the composer.
    private var approvalOutOfSight: Bool {
        guard approvalIndex != nil, promptDock == nil else { return false }
        guard let rect = approvalActionsRect() else { return true }
        return !(rect.minY >= view.safeAreaInsets.top && rect.maxY <= composer.frame.minY)
    }

    /// Lands the Run / Reject row 16 pt above the composer (the web's `approvalScrollDelta`).
    func jumpToApproval() {
        guard let index = approvalIndex else { return }
        leadPinEnded = true   // [tasks]
        Haptics.play(.selection)
        endLift(); stopGlide(); stopStreamGlide()
        anchorMessageId = nil
        tableView.setContentOffset(tableView.contentOffset, animated: false)
        if approvalActionsRect() == nil {
            tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            tableView.layoutIfNeeded()
        }
        guard let rect = approvalActionsRect() else { return }
        let delta = rect.maxY - (composer.frame.minY - 16)
        let target = max(minOffset, tableView.contentOffset.y - delta)
        following = target <= minOffset + 2
        if HQMotion.reduced {
            tableView.contentOffset.y = target
            updateJumpButton()
        } else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                self.tableView.contentOffset.y = target
            } completion: { _ in self.updateJumpButton() }
        }
    }

    /// One tap: stop any coast, cut to 1.5 screens from the end if farther, then glide there over 320 ms, reading the
    /// live end every frame (spec 06 §4.4).
    func jumpToLatest() {
        AppLog.trace("scroll", "jumped to bottom \(logTag): was \(unseen) unseen")
        leadPinEnded = true   // [tasks] the newest end wins
        endLift()
        anchorMessageId = nil
        unseen = 0
        jumpButton.setCount(0)
        tableView.setContentOffset(tableView.contentOffset, animated: false)
        stopStreamGlide()
        #if DEBUG
        let began = CACurrentMediaTime()   // [a11y] UI test E1 reads how long the jump took to be at the end
        HQA11yAudit.jumpSettleMs = nil
        #endif
        if HQMotion.reduced {
            tableView.contentOffset.y = minOffset
            following = true
            updateJumpButton()
            scheduleTrim()
            #if DEBUG
            HQA11yAudit.jumpSettleMs = (CACurrentMediaTime() - began) * 1000
            #endif
            return
        }
        #if DEBUG
        jumpBegan = began
        #endif
        let cut = tableView.bounds.height * 1.5
        if tableView.contentOffset.y - minOffset > cut { tableView.contentOffset.y = minOffset + cut }
        glideStart = (GlideClock.started(), tableView.contentOffset.y)
        glideLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(glideStep(_:)))   // motion-ok: Reduce Motion returned above (at the end at once)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        glideLink = link
        following = true
        jumpButton.setShown(false)
    }

    private static let traceScroll = ProcessInfo.processInfo.arguments.contains("-HQDemoTraceScroll")

    /// The visual position of a row on screen (its top, from the screen's top), for traces.
    private func screenTop(ofRow id: String) -> CGFloat? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
        return tableView.bounds.height - (rect.maxY - tableView.contentOffset.y)
    }

    @objc private func glideStep(_ link: CADisplayLink) {
        let t = min(1, glideStart.clock.tick() / 0.32)
        let eased = 1 - pow(1 - t, 3)
        tableView.contentOffset.y = glideStart.offset + (minOffset - glideStart.offset) * eased
        if Self.traceScroll {
            print(String(format: "[Scroll] glide t=%.2f offset=%.1f min=%.1f", t, tableView.contentOffset.y, minOffset))
        }
        if t >= 1 {
            stopGlide()
            following = true
            #if DEBUG
            if let began = jumpBegan { HQA11yAudit.jumpSettleMs = (CACurrentMediaTime() - began) * 1000; jumpBegan = nil }
            #endif
            holdReplyTopIfNeeded()
            updateJumpButton()
            scheduleTrim()
        }
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
        releaseHeadroom()
    }

    func scrollToBottom(animated: Bool) {
        leadPinEnded = true   // [tasks] a send or the jump: the newest end wins
        following = true
        if animated && !isAtBottom {
            jumpToLatest()
        } else if glideLink == nil {
            tableView.contentOffset.y = minOffset
            anchorMessageId = nil
            updateJumpButton()
            scheduleTrim()
        }
    }

    // MARK: Composer

    /// MENUS × attachments (spec 1x §8.1: "Not when the send carries attachments"): a send with files in the tray is a
    /// message even when its caption starts with "/". The attachments stream answers this (integration:
    /// `{ [weak self] in self?.attachments?.hasAttachments == true }`).
    var sendHasAttachments: () -> Bool = { false }

    /// MENUS (spec 1x §7.4, §8.1): a slash command through the dispatcher at once (never queued), with no bubble; a
    /// reader scrolled up is taken to the end first, so the output row is seen landing. False when this chat has no
    /// dispatcher.
    @discardableResult
    func runCommand(_ text: String) -> Bool {
        guard let runner = session as? ChatSlashRunning else { return false }
        AppLog.trace("composer", "slash command run \(logTag)")
        if !isAtBottom { scrollToBottom(animated: true) }
        runner.runSlash(text)
        return true
    }

    /// For logs only: "2 image, 1 file" — never the names.
    private static func attachmentKindsSummary(_ attachments: [DraftAttachment]) -> String {
        guard !attachments.isEmpty else { return "none" }
        var counts: [DraftAttachment.Kind: Int] = [:]
        for a in attachments { counts[a.kind, default: 0] += 1 }
        return counts.map { "\($0.value) \($0.key.rawValue)" }.sorted().joined(separator: ", ")
    }

    /// [tasks] A card's own message (Ask Hermes to Help): goes out as a typed one would, with `display` in your bubble.
    /// `engage: false` ([tasks] an answer tapped on the task's view): the words go out, and the task's view stays.
    func sendFromCard(_ text: String, display: String, engage: Bool = true) {
        leadPinEnded = true   // [tasks] a send: the newest end wins over the task's details
        if engage { onEngage?(.send) }
        anchorMessageId = nil
        awaitingReply = true
        awaitFromIndex = session.messages.count
        lastSendTime = CACurrentMediaTime()
        if !isAtBottom { scrollToBottom(animated: true) }
        following = true
        if let live = session as? LiveChatSession { live.send(text, display: display) } else { session.send(text) }
    }

    private func send(_ text: String) {
        // [groups] A room refuses slash commands and a send with no member to take it (the words go back to the field).
        if let roomChrome, roomChrome.refuses(text) { return }
        // MENUS: Edit's resend (the message is sent again as typed, truncating the chat before it).
        if let sendOverride, sendOverride(text) { return }
        // [talk] A bare stop phrase typed while a conversation is live ends it and is not sent (docs/spec/3x-talk.md §6.7).
        if voice.talkTypedSend(text, hasAttachments: sendHasAttachments()) { return }
        // MENUS (spec 1x §8.1): a typed slash command runs through the dispatcher instead of going out as a message.
        if SlashCommand.matches(text), !sendHasAttachments(), runCommand(text) { return }
        let text = takeReplyQuote(into: text)
        leadPinEnded = true   // [tasks] a send: the newest end wins over the task's details
        onEngage?(.send)
        anchorMessageId = nil
        awaitingReply = true
        awaitFromIndex = session.messages.count
        lastSendTime = CACurrentMediaTime()
        let atEnd = isAtBottom
        if !atEnd { scrollToBottom(animated: true) }
        following = true
        let source = composer.liftSource.map { view.convert($0, from: nil) }
        let before = session.messages.last?.id
        // [send-while-busy] While a reply runs this one waits in the queue instead of going into the reply: ⌘Return,
        // Send › Queue, or a tap with Settings › Chat › Send While Replying set to Queue.
        if composer.sendsToQueue { (session as? ChatSendQueueing)?.queuesNextSend = true }
        if let attachments, attachments.hasAttachments, let sender = session as? ChatAttachmentSending {
            let taken = attachments.takeForSend()                                                  // [attachments]
            AppLog.trace("composer", "send tapped \(logTag): \(taken.count) attachment(s) (\(Self.attachmentKindsSummary(taken)))")
            sender.send(text, attachments: taken)
        } else {
            AppLog.trace("composer", "send tapped \(logTag): no attachments")
            session.send(text)
        }
        guard let sent = session.messages.last, sent.id != before, sent.role == .user else { return }
        // The bubble lifts out of the draft (spec 06 §5.2), from a reader already at the end (a send from higher up
        // glides down to it instead).
        if atEnd, let source { pendingLift = (sent.id, source, CACurrentMediaTime()) }
        // Its row reaches the table now, in the frame the field clears: no frame shows neither (verification round 3:
        // two main-queue hops left ~65 ms with the text nowhere and Stop showing first).
        (session as? ChatChangeFlushing)?.flushChanges()
        if flushScheduled {
            syncApply = true
            flush()
            syncApply = false
        }
        // "Sending…" under it once it has waited 2 s (spec 06 §5.6.4).
        let id = sent.id
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatRowBuilder.sendingDelay + 0.05) { [weak self] in
            guard let self, self.session.messages.last(where: { $0.id == id })?.isPending == true else { return }
            self.rebuildMessage(id)
        }
    }

    /// Swipe to Reply: the words a send carries, under the reply's quote (Hermes has no reply-to of its own); the quote
    /// and its banner are spent. The words alone when not replying.
    private func takeReplyQuote(into text: String) -> String {
        guard let quote = replyQuote else { return text }
        replyQuote = nil
        composer.editBanner = nil
        return text.isEmpty ? quote : quote + "\n\n" + text
    }

    /// Coast catch: a tap on the composer within 120 ms of a momentum scroll stops the coast and doesn't focus it.
    private func composerMayFocus() -> Bool {
        if tableView.isDecelerating || CACurrentMediaTime() - lastMomentum < 0.12 {
            tableView.setContentOffset(tableView.contentOffset, animated: false)
            return false
        }
        return true
    }

    /// For logs only: a quoted title or file name inside a UI string is not the app's own words.
    private static func logSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "“[^”]*”|\"[^\"]*\"", with: "“…”", options: .regularExpression)
    }

    /// A one-line notice under the title for 3 s (Stop that came too late, a refused send's reason). [questions] With an
    /// action ("Reconnect"), 5 s and tappable.
    func showNotice(_ text: String, action: (title: String, handler: () -> Void)? = nil, duration: TimeInterval? = nil) {
        guard isViewLoaded else { return }
        AppLog.trace("chatui", "notice shown \(logTag): \(Self.logSafe(text))")
        if let duration {   // [talk] the iPhone-voice notice stays 8 s
            noticeToast.show(text, duration: duration, spinner: false, action: action)
        } else {
            noticeToast.show(text, action: action)
        }
    }

    // settings stream: a longer notice (New Bot without a model provider) wraps fully and stays until it is tapped.
    func showLongNotice(_ text: String) {
        guard isViewLoaded else { return }
        AppLog.trace("chatui", "notice shown \(logTag): \(Self.logSafe(text))")
        noticeToast.show(text, lines: 0, seconds: nil)
    }

    /// MENUS (spec 1x §5.3): a notice that stays (`duration` nil) until replaced, with a spinner ("Switching to …").
    func showNotice(_ text: String, duration: TimeInterval?, spinner: Bool) {
        guard isViewLoaded else { return }
        AppLog.trace("chatui", "notice shown \(logTag): \(Self.logSafe(text))")
        noticeToast.show(text, duration: duration, spinner: spinner)
    }

    func hideNotice() { noticeToast.hide() }

    func focusComposer() {
        // VOICE: a held memo sent with the keyboard down keeps it down for 1.5 s (only programmatic focus waits).
        guard CACurrentMediaTime() >= composer.focusSuppressedUntil else { return }
        composer.textView.becomeFirstResponder()
    }

    // MARK: VOICE (spec 1x-voice; App/Chat/Voice/)

    /// Sends a voice memo (with words typed beside it) as this chat's next message: the screen follows it like a send.
    func sendMemo(_ memo: MemoFile, text: String) {
        guard let memos = session as? ChatVoiceMemos else { return }
        if let roomChrome, roomChrome.refusesMemo(memo, typed: text) { return }   // [groups] no one to send to
        menus?.closeModelPanel()
        voice.memoSending()
        // A memo recorded under "Replying to …" goes out under the quote too (after the memo, which opens the message).
        let text = takeReplyQuote(into: text)
        anchorMessageId = nil
        awaitingReply = true
        awaitFromIndex = session.messages.count
        lastSendTime = CACurrentMediaTime()
        if !isAtBottom { scrollToBottom(animated: true) }
        following = true
        let before = session.messages.last?.id
        memos.sendMemo(memo, text: text)
        (session as? ChatChangeFlushing)?.flushChanges()
        if flushScheduled {
            syncApply = true
            flush()
            syncApply = false
        }
        guard let sent = session.messages.last, sent.id != before, sent.role == .user else { return }
        let id = sent.id
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatRowBuilder.sendingDelay + 0.05) { [weak self] in
            guard let self, self.session.messages.last(where: { $0.id == id })?.isPending == true else { return }
            self.rebuildMessage(id)
        }
    }

    /// The seam for memo entry points beyond the mic (+ menu, Bots, Action Button, Siri): the locked recorder here.
    func beginMemo(handsFree: Bool) { voice.beginMemo(handsFree: handsFree) }

    /// [talk] Every way into a live voice conversation ends here (docs/spec/3x-talk.md §5): the intro once, then Talk.
    func beginTalk() { voice.beginTalk() }

    /// Rebuilds the messages `match` picks (a memo's load state changed).
    func voiceRebuildMessages(where match: (ChatMessage) -> Bool) {
        let messages = session.messages
        let tail = messages.indices.suffix(600)
        let hits = tail.filter { match(messages[$0]) }
        guard !hits.isEmpty else { return }
        for index in hits { model.rebuildMessages(input(), index...index) }
        requestApply(urgent: true)
    }

    /// The jump-to-latest button is showing (tips wait for it to go).
    var isJumpButtonShown: Bool { jumpButton.isShown }

    /// Shows or hides the memo notice card above the queue card, moving the dock and the transcript's bottom with it.
    private func setMemoNotice(shown: Bool) {
        let card = voice.notice
        let animate = view.window != nil && !HQMotion.reduced
        if shown && card.isHidden { card.alpha = 0; card.isHidden = false }
        noticeCollapsed.isActive = !shown
        noticeGap.constant = shown ? -8 : 0
        let changes = {
            card.alpha = shown ? 1 : 0
            self.view.layoutIfNeeded()
        }
        let done: (Bool) -> Void = { _ in if !shown, self.noticeCollapsed.isActive { card.isHidden = true; self.updateInsets() } }   // as the queue card's
        if animate {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: done)   // motion-ok: `animate` is false under Reduce Motion
        } else {
            changes(); done(true)
        }
    }

    /// [transcript] Control-Return (L366): the hold menu of the newest message on screen, as a list. DECISION: the web
    /// opens the focused bubble's menu; bubbles take no keyboard focus here, so the newest one on screen stands in.
    @discardableResult
    func openMessageActionsForNewest() -> Bool {
        let cells = (tableView.indexPathsForVisibleRows ?? []).sorted { $0.row < $1.row }   // inverted: row 0 is newest
            .compactMap { tableView.cellForRow(at: $0) as? ChatBubbleCell }
        return cells.first?.openMessageActions() ?? false
    }

    // MARK: [transcript] The cards above the composer (docs/spec/3x-transcript.md §6.2, §6.3)

    private func installComposerNotices() {
        composerNotices.axis = .vertical
        composerNotices.spacing = 8
        composerNotices.isHidden = true
        composerNotices.translatesAutoresizingMaskIntoConstraints = false
        problemCard.isHidden = true
        sendFailureCard.isHidden = true
        ownerWaitCard.isHidden = true
        composerNotices.addArrangedSubview(problemCard)
        composerNotices.addArrangedSubview(sendFailureCard)
        composerNotices.addArrangedSubview(ownerWaitCard)
        ownerWaitCard.onClose = { [weak self] in (self?.session as? ChatComposerNotices)?.dismissOwnerWait() }
        ownerWaitCard.onPrimary = { [weak self] in
            Haptics.play(.rigid)   // Cancel Message stops the waiting turn, as Stop
            (self?.session as? ChatComposerNotices)?.cancelOwnerWait()
        }
        view.addSubview(composerNotices)
        problemCard.onClose = { [weak self] in (self?.session as? ChatComposerNotices)?.dismissSessionProblem() }
        problemCard.onPrimary = { [weak self] in
            guard let self, let source = self.session as? ChatComposerNotices, let problem = source.sessionProblem else { return }
            switch problem.primary {
            case .chooseModel: self.presentModelSheet()
            case .tryAgain: source.retryAfterProblem()
            case .newChat:
                // [locked-chat] The gateway won't open this chat: the same bot's new chat opens in its place, with the
                // words that couldn't go here in its field.
                guard let live = self.session as? LiveChatSession, let open = live.slashHooks.newChat else { return }
                if !open(self.composer.text) { HQAnnounce.say("Couldn’t open a new chat.", priority: .high, coalesce: true) }
            }
        }
        sendFailureCard.onClose = { [weak self] in (self?.session as? ChatComposerNotices)?.dismissSendFailure() }
        // Try Again sends what is in the field now (the returned words, and anything typed since).
        // With nothing left in the field there is nothing to send again: the card goes.
        sendFailureCard.onPrimary = { [weak self] in
            guard let self else { return }
            let empty = self.composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.sendHasAttachments()
            if empty { (self.session as? ChatComposerNotices)?.dismissSendFailure() } else { self.composer.submit() }
        }
    }

    private func updateComposerNotices() {
        let source = session as? ChatComposerNotices
        let problem = source?.sessionProblem.map(ChatNoticeCard.Content.init)
        let failure = source?.sendFailure.map(ChatNoticeCard.Content.init)
        let wait = source?.ownerWaitNotice.map(ChatNoticeCard.Content.init)
        guard problem != problemCard.shownContent || failure != sendFailureCard.shownContent
                || wait != ownerWaitCard.shownContent else { return }
        if let wait, wait != ownerWaitCard.shownContent {
            HQAnnounce.say("\(wait.title). \(wait.body)", priority: .high, coalesce: true)
            AppLog.trace("chatui", "owner-wait card shown \(logTag)")
        } else if wait == nil, ownerWaitCard.shownContent != nil {
            AppLog.trace("chatui", "owner-wait card cleared \(logTag)")
        }
        if let problem, problem != problemCard.shownContent {
            HQAnnounce.say("\(problem.title). \(problem.body)", priority: .high, coalesce: true)
            AppLog.note("chatui", "problem card shown \(logTag): \(problem.title)")
        } else if problem == nil, problemCard.shownContent != nil {
            AppLog.trace("chatui", "problem card cleared \(logTag)")
        }
        if let failure, failure != sendFailureCard.shownContent {
            Haptics.play(.error)
            HQAnnounce.say("\(failure.title). \(failure.body)", priority: .high, coalesce: true)
            AppLog.note("chatui", "send failure card shown \(logTag): \(failure.title)")
        } else if failure == nil, sendFailureCard.shownContent != nil {
            AppLog.trace("chatui", "send failure card cleared \(logTag)")
        }
        if let problem { problemCard.show(problem) }
        if let failure { sendFailureCard.show(failure) }
        if let wait { ownerWaitCard.show(wait) }
        problemCard.shownContent = problem
        sendFailureCard.shownContent = failure
        ownerWaitCard.shownContent = wait
        let shown = problem != nil || failure != nil || wait != nil
        let animate = view.window != nil && !HQMotion.reduced
        if shown && composerNotices.isHidden { composerNotices.alpha = 0; composerNotices.isHidden = false }
        problemCard.isHidden = problem == nil
        sendFailureCard.isHidden = failure == nil
        ownerWaitCard.isHidden = wait == nil
        composerNoticesCollapsed.isActive = !shown
        composerNoticesGap.constant = shown ? -8 : 0
        let changes = {
            self.composerNotices.alpha = shown ? 1 : 0
            self.view.layoutIfNeeded()
            self.updateInsets()
        }
        let done: (Bool) -> Void = { _ in
            if !shown, self.problemCard.shownContent == nil, self.sendFailureCard.shownContent == nil,
               self.ownerWaitCard.shownContent == nil { self.composerNotices.isHidden = true }
            self.updateInsets()
        }
        if animate {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: done)   // motion-ok: `animate` is false under Reduce Motion
        } else {
            changes(); done(true)
        }
    }

    // MARK: Cells

    func chatCellToggle(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        // A run of one opens its step sheet directly (spec 03 §8.4).
        if case .toolRun(let run) = row.kind, run.tools.count == 1, run.line?.thought == nil {
            chatCellOpenStep(rowId: rowId, index: 0)
            return
        }
        // [updates] A work line in an opened group acts as its One Line row: one step opens its sheet.
        if case .updateMember(let member) = row.kind, member.steps.count == 1, member.thought == nil {
            chatCellOpenStep(rowId: rowId, index: 0)
            return
        }
        if expanded.contains(rowId) { expanded.remove(rowId) } else { expanded.insert(rowId) }
        // The newest row, opened while the chat sits at its end (the files card's "Show All N Files" is usually
        // there): the end stays put and the row grows up into view. Held by its top it grew down, under the composer.
        if !(following && rows.first?.id == rowId) { holdRowId = rowId }
        rebuildMessage(row.messageId)
    }

    func chatCellToggleCode(rowId: String, block: Int) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        let key = "\(rowId)#c\(block)"
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        holdRowId = rowId
        rebuildMessage(row.messageId)
    }

    /// Rebuilds one message's rows in place (an expansion changed), however deep in history it is.
    func rebuildMessage(_ messageId: String) {
        let messages = session.messages
        guard let index = messages.lastIndex(where: { $0.id == messageId }) else { return }
        model.rebuildMessages(input(), index...index)
        requestApply(urgent: true)
    }

    func chatCellOpenStep(rowId: String, index: Int) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        // [files] A folded "N files changed" member: one of its files, or its last row, Review Changes.
        if case .updateMember(let member) = row.kind, !member.files.isEmpty {
            if index < member.files.count { activityCellOpenFile(path: member.files[index].path) }
            else { activityCellReviewChanges(highlighting: nil) }
            return
        }
        let tools: [ToolCall]
        switch row.kind {
        case .toolRun(let run): tools = run.tools
        case .updateMember(let member): tools = member.steps                       // [updates] a work line in a group
        default: return
        }
        guard index < tools.count else { return }
        activity.presentStep(messageId: row.messageId, call: tools[index])     // [activity] the complete step sheet (§12)
    }

    // MARK: [activity] Hooks for ChatActivityController

    /// Rebuilds these messages' rows (live subagents moved a delegate card, a fold, Show Steps).
    func activityRebuild(messageIds: [String]) {
        let messages = session.messages
        let indices = messageIds.compactMap { id in messages.lastIndex { $0.id == id } }
        guard !indices.isEmpty else { return }
        // [perf] Each run of adjacent messages on its own, not one span from the oldest to the newest: the replies between
        // two cards haven't changed.
        let rowsInput = input()
        for run in ChatRowModel.runs(of: indices) { model.rebuildMessages(rowsInput, run) }
        requestApply(urgent: true)
    }

    /// Rebuilds every row, holding the first visible row in place (a Tool Calls setting, display flags).
    func activityRebuildAll() {
        pendingReset = true
        scheduleFlush()
    }

    /// The row with this id, if the table shows it.
    func activityRow(id: String) -> ChatRow? { rows.first { $0.id == id } }

    /// The table still shows step rows of this reply (a fold's removal hasn't landed).
    func activityHasStepRows(of messageId: String) -> Bool { rows.contains { $0.messageId == messageId && $0.isStepBlock } }

    /// A stream glide, the send lift or a jump is moving the rows (the fold's slide waits for it).
    var activityMotionBusy: Bool { streamLink != nil || lift != nil || glideLink != nil }

    /// "Delivery Unconfirmed · Check": a read-only look in the stored chat (spec 04 §2.5). Never resends.
    func chatCellCheckDelivery(rowId: String) {
        // [groups] In a room the line under your bubble is "Not Delivered · Try Again".
        if let roomChrome, let row = rows.first(where: { $0.id == rowId }) { roomChrome.retry(row.messageId); return }
        guard let row = rows.first(where: { $0.id == rowId }), let checker = session as? ChatDeliveryChecking else { return }
        let messageId = row.messageId
        let key = ChatRowBuilder.checkingKey(messageId)
        guard !expanded.contains(key) else { return }
        expanded.insert(key)
        rebuildMessage(messageId)
        Task { [weak self] in
            let found = await checker.checkDelivery(messageId)
            guard let self else { return }
            self.expanded.remove(key)
            self.rebuildMessage(messageId)
            switch found {
            case true?: Haptics.play(.success)
            case false?:
                Haptics.play(.warning)
                self.showNotice("\(HostWord.sentence) doesn’t have this message yet.")
            case nil:
                Haptics.play(.error)
                self.showNotice("Couldn’t check right now. Try again in a moment.")
            }
        }
    }

    /// The error card's ✕: the card goes from this screen (the transcript keeps the turn).
    func chatCellDismissError(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }) else { return }
        Haptics.play(.selection)
        expanded.insert(ChatRowBuilder.dismissedErrorKey(row.messageId))
        rebuildMessage(row.messageId)
    }

    func chatCellChooseModel() { presentModelSheet() }

    func chatCellRetry(rowId: String) {
        guard let row = rows.first(where: { $0.id == rowId }), !session.isRunning else { return }
        let messages = session.messages
        guard let index = messages.lastIndex(where: { $0.id == row.messageId }) else { return }
        if case .error = row.kind {
            // The error card's Retry: the turn's own prompt, right above it (`ChatRowBuilder.retryPrompt`).
            guard let text = ChatRowBuilder.retryPrompt(forErrorAt: index, input: input()) else { return }
            send(text)
            return
        }
        // "Stopped before … replied": the newest turn's own prompt, words only (`ChatRowBuilder.retryPrompt(forStoppedAt:)`).
        guard let text = ChatRowBuilder.retryPrompt(forStoppedAt: index, input: input()) else { return }
        send(text)
    }

    func chatCellErrorDetails(rowId: String, details: String) {
        // [error-words] Try Again in the sheet is the error card's own Retry, offered where that is (not while a turn runs).
        let canRetry = !session.isRunning && rows.contains { row in
            guard row.id == rowId, case .error = row.kind else { return false }
            return true
        }
        present(ChatErrorDetailsSheet.make(details: details, retry: canRetry ? { [weak self] in self?.chatCellRetry(rowId: rowId) } : nil),
                animated: true)
    }

    func chatCellOpenTable(_ table: MarkdownTable) {   // [transcript] L309
        TableSheetController.open(table, from: self)
    }

    func chatCellOpen(url: URL) {
        if openMediaLink(url) { return }                                                          // [attachments] `#media:` links
        if openFileLink(url) { return }                                                           // a path in backticks: Files
        LinkOpener.open(url, from: self)   // [transcript] in-app Safari; a gateway-loopback page says why it can't open
    }

    // MARK: - Server requests [questions] (spec 1x §4; App/Questions/)

    /// The top of what sits at the bottom: the question dock in the composer's place, else the composer.
    private var bottomChromeTop: CGFloat { promptDock?.frame.minY ?? composer.frame.minY }

    /// The dock is so tall (AX sizes, the long set) that the jump button would sit on it or under the status line: no
    /// room for it (the transcript left above the dock is a sliver).
    private var promptDockCrowdsJump: Bool {
        guard let dock = promptDock, dock.frame.height > 0 else { return false }
        let room = dock.frame.minY - ChatMetrics.jumpAboveComposer - ChatMetrics.jumpSize
        return room < view.safeAreaInsets.top + ChatMetrics.statusLineHeight + 8
    }

    /// Where the transcript ends: above the composer (or dock), the queue card and a showing prompt chip; 52 pt
    /// higher while the voice pill floats over this chat. [talk]
    private var transcriptBottom: CGFloat { voice.talkPillTop(base: bottomStackTop) }

    /// The top of everything that sits at the bottom of the screen.
    private var bottomStackTop: CGFloat {
        var top = queueCard.isHidden ? bottomChromeTop : min(bottomChromeTop, queueCard.frame.minY)
        if !composerNotices.isHidden { top = min(top, composerNotices.frame.minY) }   // [transcript]
        if !voice.notice.isHidden { top = min(top, voice.notice.frame.minY) }   // VOICE
        top = activity.dockTop(base: top)                                        // [activity] the shelf
        if let chip = promptChip, !chip.isHidden, chip.alpha > 0.01 { top = min(top, chip.frame.minY) }
        top = voice.talkCaptionTop(base: top)                                    // [talk] "Voice chat ended" sits above all of it
        if let roomTop = roomChrome?.dockTop { top = min(top, roomTop) }         // [groups] reply chip, paused
        return top
    }

    #if DEBUG
    /// [desktop-frost] Layout tests: the jump's frame and the visible frames docked over the composer it must not meet.
    var jumpFrameForTests: CGRect { jumpButton.frame }
    var isAtBottomForTests: Bool { isAtBottom }
    var followingForTests: Bool { following }
    var jumpNeighboursForTests: [String: CGRect] {
        var out: [String: CGRect] = [:]
        if let chip = promptChip, !chip.isHidden, chip.alpha > 0.01 { out["chip"] = chip.frame }
        if !queueCard.isHidden, queueCard.frame.height > 0 { out["queue"] = queueCard.frame }
        if !voice.notice.isHidden, voice.notice.frame.height > 0 { out["memo"] = voice.notice.frame }
        if !activity.shelf.isHidden, activity.shelf.frame.height > 0 { out["shelf"] = activity.shelf.frame }
        out["composer"] = composer.frame
        return out
    }
    #endif

    /// The open requests changed: the newest rows (the card, the note) are rebuilt on the next apply. `closingGap`: an
    /// answered card's row goes now; at the newest end the rows above glide down into its place instead of jumping.
    func promptsDidChange(closingGap: Bool = false) {
        guard isViewLoaded else { return }
        if closingGap { promptGapPending = true }
        if let last = session.messages.last?.id { pendingTouched.append(last) } else { pendingNewest = true }
        scheduleFlush()
    }

    /// The chip came or went: the transcript's bottom follows in the same animation.
    func promptChipChanged() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func closePromptGap(_ growth: CGFloat) {
        guard growth < -0.5, following, glideLink == nil, streamLink == nil, lift == nil, view.window != nil,
              !HQMotion.reduced else { return }
        let end = minOffset
        tableView.contentOffset.y = end + growth
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.tableView.contentOffset.y = end
        }
    }

    /// The tucked-prompt chip: centred, 8 pt above the composer, the dock or the queue card (§4.5).
    func installPromptChip(_ chip: UIView) {
        promptChip = chip
        chip.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(chip, belowSubview: noticeToast)
        let chipAboveNotice = chip.bottomAnchor.constraint(equalTo: voice.notice.topAnchor, constant: -8)   // VOICE: over the memo notice too
        chipAboveNotice.priority = .defaultHigh
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            chipAboveNotice,
            // [activity] and over the shelf when it shows (an empty shelf's top is 6 pt above the notice's)
            chip.bottomAnchor.constraint(lessThanOrEqualTo: activity.shelf.topAnchor, constant: ActivityShelfView.gap - 8),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 256),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ])
    }

    /// The question dock replaces the composer (its draft is kept, hidden), pinned to the keyboard with its own gaps:
    /// 8 pt above the screen's bottom with the keyboard down, 4 pt above the keys with it up, 8 pt sides; at most the
    /// chat's height above the keyboard minus the bar, the status line and 30 pt. `nil` brings the composer back.
    // [talk] One dock slot, two owners (docs/spec/3x-talk.md §6.1, DECISION T12): a bot's question outranks the voice
    // dock; each owner keeps its view and the winner shows.
    enum DockOwner: Int { case voice = 0, question = 1 }
    private var docks: [DockOwner: UIView] = [:]

    func setDock(_ dock: UIView?, for owner: DockOwner, animated: Bool) {
        docks[owner] = dock
        showPromptDock(docks[.question] ?? docks[.voice], animated: animated)
        if owner == .question { voice.talkQuestionDock(shown: dock != nil) }
    }
    /// [groups] The room chrome reads these to place and hide its dock.
    var hasPromptDock: Bool { promptDock != nil }
    func roomChromeChanged(animated: Bool) {
        guard isViewLoaded else { return }
        applyState()
        let changes = { self.view.layoutIfNeeded(); self.updateInsets() }
        if animated, view.window != nil, !HQMotion.reduced {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
    /// [groups] The row for a message (the hold menu's source).
    func roomRow(id: String) -> ChatRow? { rows.first { $0.id == id } }

    func showPromptDock(_ dock: UIView?, animated: Bool) {
        guard isViewLoaded else { return }
        let old = promptDock
        guard old !== dock else { return }
        let fade = animated && view.window != nil && !HQMotion.reduced
        #if DEBUG
        activity.motionProbe?.note(String(format: "dock %@ fade=%d composer=%.1f hidden=%d", dock == nil ? "leaves" : "shows", fade ? 1 : 0,
                                          composer.frame.minY, composer.isHidden ? 1 : 0))
        #endif
        promptDock = dock
        if let dock {
            if composer.textView.isFirstResponder { composer.textView.resignFirstResponder() }
            voice.composerCovered()   // VOICE: a take never records on behind the dock (it becomes the draft chip)
            if fade {
                // Verify round 1: a cross-fade drew the half-clear card's text over the transcript's. The card is opaque
                // and rises from below the screen's edge instead, like the keyboard it often replaces. It starts there
                // at its own size, laid out before it joins the screen (so only its position animates, never its
                // contents growing from a zero frame), and the layout pass below moves it into place.
                let side = dock is ComposerRowDock ? ChatMetrics.composerSideDown + composer.columnMargin : 8 + composer.columnMargin
                let width = max(0, view.bounds.width - 2 * side)
                let height = dock.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                          withHorizontalFittingPriority: .required,
                                                          verticalFittingPriority: .fittingSizeLevel).height
                dock.translatesAutoresizingMaskIntoConstraints = true
                dock.frame = CGRect(x: side, y: view.bounds.maxY + 16, width: width, height: min(height, view.bounds.height))
                dock.layoutIfNeeded()
            }
            dock.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(dock, aboveSubview: composer)
            let guide = view.keyboardLayoutGuide
            // [talk] The voice bar and its notices sit exactly where the composer's row sits (26 pt sides, 29 pt above the
            // screen's bottom, 8 pt above the keys), so nothing reaches the screen's edges; the question dock keeps its
            // own 8 pt card place.
            let row = dock is ComposerRowDock
            let side = row ? ChatMetrics.composerSideDown : 8
            let bottom = row ? ChatMetrics.composerBottomDown : 8, keys = row ? ChatMetrics.composerBottomUp : 4
            let follow = dock.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -keys)
            follow.priority = .defaultHigh
            let gap = queueCard.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: queueGap.constant)
            queueGap.isActive = false
            promptQueueGap?.isActive = false
            promptQueueGap = gap
            // The shelf is the top of what sits on the dock; the dock's page scrolls inside what is left.
            let stackTop = activity.shelf.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                                                               constant: ChatMetrics.statusLineHeight + 8)
            stackTop.priority = .required - 1
            promptStackTop?.isActive = false
            promptStackTop = stackTop
            NSLayoutConstraint.activate([
                dock.leadingAnchor.constraint(equalTo: columnGuide.leadingAnchor, constant: side),
                dock.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor, constant: -side),
                dock.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -bottom),
                dock.bottomAnchor.constraint(lessThanOrEqualTo: guide.topAnchor, constant: -keys),
                follow,
                dock.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                                          constant: ChatMetrics.statusLineHeight + 30),
                gap,
                stackTop,
            ])
            dock.alpha = 1
        } else {
            promptQueueGap?.isActive = false
            promptQueueGap = nil
            promptStackTop?.isActive = false
            promptStackTop = nil
            queueGap.isActive = true
            composer.isHidden = false
            // [talk] The mic and the circle return under the finger that just dismissed the card: a second tap there
            // (a double tap on End) starts nothing.
            composer.quietActions()
        }
        // The card leaving slides down past the screen's bottom edge (opaque all the way), uncovering the composer.
        let drop = old.map { max(120, view.bounds.height - $0.frame.minY + 16) } ?? 0
        let changes = {
            self.composer.alpha = dock == nil ? 1 : 0
            if fade { old?.transform = CGAffineTransform(translationX: 0, y: drop) } else { old?.alpha = 0 }
            self.view.layoutIfNeeded()
        }
        let done: (Bool) -> Void = { _ in
            #if DEBUG
            self.activity.motionProbe?.note(String(format: "dock done composer=%.1f", self.composer.frame.minY))
            #endif
            if old !== self.promptDock { old?.removeFromSuperview() }   // [talk] a dock that came back stays
            old?.transform = .identity
            if old === self.promptDock { old?.alpha = 1 }
            if self.promptDock != nil { self.composer.isHidden = true }
            self.updateInsets()
            self.updateJumpButton()
        }
        roomChrome?.stateChanged()   // [groups] its dock gives way to the question dock
        if fade {
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,   // motion-ok: `fade` is false under Reduce Motion
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: done)
        } else {
            changes(); done(true)
        }
    }

    // MARK: MENUS: Find in chat

    /// ⋯ › Find: the find bar under the status line, its field focused.
    func showFind() {
        let find = findController ?? ChatFindController(chat: self)
        findController = find
        find.open()
    }

    private static var findBarSide: CGFloat { DeviceWord.isMac ? ChatMetrics.sideInset : 12 }

    /// [mac] Stress test 2026-10-28 #79: the notice's top constraint, moved under `anchor` (6 pt gap); the old one goes.
    private func noticeTop(under anchor: UIView) -> NSLayoutConstraint {
        noticeToastTop?.isActive = false
        let top = noticeToast.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 6)
        noticeToastTop = top
        return top
    }

    func showFindBar(_ bar: ChatFindBar) {
        guard bar.superview == nil else { return }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.alpha = 0
        // [mac] Stress test 2026-10-28 #79: notices ("Read Replies Aloud is on") draw over the bar and sit under it, not
        // hidden behind it (the Desktop Look bar is opaque; the glass one faded them).
        view.insertSubview(bar, belowSubview: noticeToast)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: 4),
            // [mac] Stress test 2026-10-28 #53: on the composer's and the bubbles' edges (it was 4 to 14 pt wider).
            bar.leadingAnchor.constraint(equalTo: columnGuide.leadingAnchor, constant: Self.findBarSide),
            bar.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor, constant: -Self.findBarSide),
        ])
        NSLayoutConstraint.activate([noticeTop(under: bar)])
        findInset = ChatFindBar.height + 8
        onEngage?(.find)   // [tasks] the pinned panel rolls up while you find
        // Two lines at large text, the Search Earlier row: the transcript starts under the bar as drawn.
        bar.onHeightChange = { [weak self] height in
            guard let self, self.findInset > 0 else { return }
            self.findInset = height + 8
            self.updateInsets()
        }
        updateInsets()
        UIView.animate(withDuration: HQMotion.reduced ? 0 : 0.2) { bar.alpha = 1 }
    }

    func hideFindBar(_ bar: ChatFindBar) {
        findInset = 0
        NSLayoutConstraint.activate([noticeTop(under: statusPill)])
        pendingFindRow = nil
        updateInsets()
        UIView.animate(withDuration: HQMotion.reduced ? 0 : 0.2, animations: { bar.alpha = 0 }) { _ in
            bar.removeFromSuperview()
        }
    }

    /// The matches or the current one changed: the bubbles on screen draw them again.
    func findHighlightsChanged() {
        for case let cell as ChatBubbleCell in tableView.visibleCells {
            cell.setFind(findController?.highlight(forRow: cell.rowId))
        }
    }

    /// The part indices of a reply's built bubbles, oldest first (nil while its rows aren't built). A reply's text parts
    /// with nothing drawn between them are one bubble, under its first part's id (`ChatRowBuilder.appendAssistant`), so
    /// Find puts a match in a later part into the bubble that starts at or before it.
    func findBubbleParts(ofMessage messageId: String) -> [Int]? {
        var parts: [Int] = []
        for row in model.allRows where row.messageId == messageId {
            if case .bubble(let b) = row.kind, !b.mine, row.id == "\(messageId)|b\(b.partIndex)" { parts.append(b.partIndex) }
        }
        return parts.isEmpty ? nil : parts.sorted()
    }

    /// Brings a match into view: its row is shown first (revealed from the hidden old end, or built down to it), then
    /// the current occurrence lands a third of the way down the room between the find bar and the composer.
    func revealFindMatch(_ match: ChatFindMatch) {
        var target = findController?.drawnPlace(of: match).rowId ?? match.rowId
        // [exchange] A reply folded into a talk between bots: its line and its card row open, and Find goes there.
        if let at = session.messages.lastIndex(where: { $0.id == match.messageId }),
           let open = UpdateGroups.opening(rowId: match.rowId, message: at, input: input()) {
            target = open.member
            if !expanded.isSuperset(of: [open.line, open.member]) {
                expanded.formUnion([open.line, open.member])
                model.rebuildMessages(input(), at...at)
            }
        }
        pendingFindRow = target
        if rows.contains(where: { $0.id == target }) {
            scrollToPendingFind()
            return
        }
        if let index = model.allRows.firstIndex(where: { $0.id == target }) {
            model.reveal(index - model.shownCount + 20)
        } else if session.messages.contains(where: { $0.id == match.messageId }) {
            fillGeneration += 1
            model.rebuildAll(input(), syncMessages: Self.syncBuildMessages, oldestShown: match.messageId)
            model.reveal(20)
            // Its rows exist now: the bubble that draws the match (a later part joined into an earlier one).
            pendingFindRow = findController?.drawnPlace(of: match).rowId ?? target
        } else {
            pendingFindRow = nil
            return
        }
        requestApply(urgent: true)
        if pendingFindRow != nil { scrollToPendingFind() }
        startFill()
    }

    private func scrollToPendingFind() {
        guard let id = pendingFindRow, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        pendingFindRow = nil
        leadPinEnded = true   // [tasks]
        stopGlide()
        stopStreamGlide()
        following = false
        anchorMessageId = nil
        let room = max(1, tableView.bounds.height - topInset - tableView.contentInset.top)
        let minimum = minOffset
        func place(_ pointY: CGFloat) {
            let maxOffset = max(minimum, tableView.contentSize.height + topInset - tableView.bounds.height)
            let target = pointY + room / 3 - tableView.bounds.height + topInset
            tableView.contentOffset.y = min(maxOffset, max(minimum, target))
        }
        let rect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
        place(rect.maxY)
        tableView.layoutIfNeeded()
        // A tall reply: the occurrence itself, not the bubble's top.
        if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? ChatBubbleCell, let box = cell.currentFindRect(),
           box.minY > room / 2 {
            place(rect.maxY - box.minY + 8)
            tableView.layoutIfNeeded()
        }
        updateJumpButton()
        updateBottomEdge()
        revealIfNeeded()
        findHighlightsChanged()
    }

    // MARK: [tasks] Lead

    /// [tasks] A task's details above its chat (owner 2026-11-05: the conversation lives on the task page). The lead
    /// scrolls with the rows and shows once every built row is held (a long chat brings it in as you scroll back;
    /// older history read later comes in under it). Its box fills the room a short chat leaves, so the rows sit by the
    /// composer as in any chat and the lead stays at the top. No placeholder shows while there is a lead.
    /// [tasks] Owner 2026-11-07 ("I love all of that. Go." to the Pinned Task design, step 3): a page's own panel
    /// pinned under the bar, outside the transcript, so it never scrolls away with the rows nor waits for them all to be
    /// built (the lead showed only then, so a long chat opened with no task at all). The safe area grows by the panel's
    /// height, as Sessions' chips do: the status line, the notices, the find bar, the empty chat's intro and the rows
    /// all start under it, and the rows scroll up under its edge.
    func setTopAccessory(_ controller: UIViewController) {
        guard topAccessory == nil else { return }
        loadViewIfNeeded()
        topAccessory = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        // Over the rows and the top edge's own views (the Mac's bar backing, the edge element and its stand-in: the
        // Mac's hard edge drew over a panel put under them), under the status line, the notices and the composer.
        view.insertSubview(controller.view, aboveSubview: edgeStandIn)
        // The empty chat's intro goes under it: the task's view covers the chat, and the intro had drawn over the task.
        if placeholder.superview === view { view.insertSubview(placeholder, belowSubview: controller.view) }
        let height = controller.view.heightAnchor.constraint(equalToConstant: 0)
        let top = controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top,
            height,
        ])
        controller.didMove(toParent: self)
        topAccessoryHeight = height
        topAccessoryTop = top
        tableView.alwaysBounceVertical = true   // a short chat can still be pulled, which rolls the panel up
    }

    /// [tasks] The pinned panel's height (the page measures what it draws and caps it); 0 lays it away. `insets`: the
    /// transcript starts under it (a bar); false, it covers the transcript and the chat's layout stays as it is.
    func setTopAccessoryHeight(_ value: CGFloat, insets: Bool = true, animated: Bool) {
        guard let topAccessoryHeight else { return }
        let scale = max(view.window?.screen.scale ?? traitCollection.displayScale, 1)
        let target = max(0, (value * scale).rounded(.up) / scale)   // to the pixel: a fraction left a line of rows above it
        let inset = insets ? target : 0
        guard abs(topAccessoryHeight.constant - target) > 0.5 || abs(additionalSafeAreaInsets.top - inset) > 0.5 else { return }
        let change = {
            topAccessoryHeight.constant = target
            self.topAccessoryTop?.constant = -inset
            self.additionalSafeAreaInsets.top = inset
            self.view.layoutIfNeeded()
        }
        if animated, view.window != nil, !HQMotion.reduced {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { change() }   // motion-ok: off under Reduce Motion
        } else {
            change()
        }
    }

    /// [tasks] The room between the bar and the composer (the pinned panel keeps some of it for the chat).
    var roomUnderBar: CGFloat {
        let barBottom = view.safeAreaInsets.top - additionalSafeAreaInsets.top
        return max(0, transcriptBottom - barBottom)
    }

    /// [tasks] The room from the bar down to the composer's top (a panel covering the transcript ends there).
    var roomToComposer: CGFloat {
        let barBottom = view.safeAreaInsets.top - additionalSafeAreaInsets.top
        return max(0, composer.frame.minY - barBottom)
    }

    func setLead(_ controller: UIViewController) {
        guard lead == nil else { return }
        lead = controller
        addChild(controller)
        controller.view.backgroundColor = .clear
        leadUpright.addSubview(controller.view)
        controller.didMove(toParent: self)
        if isViewLoaded { installLead(); updatePlaceholder(animated: false) }
    }

    /// [tasks] A view at the foot of the lead's box: it stays right above the first message (or the bar while the
    /// chat is empty), however much room the box fills.
    func setLeadFoot(_ controller: UIViewController) {
        guard leadFoot == nil else { return }
        leadFoot = controller
        addChild(controller)
        controller.view.backgroundColor = .clear
        leadUpright.addSubview(controller.view)
        controller.didMove(toParent: self)
        if isViewLoaded, lead != nil { layoutLead() }
    }

    private func installLead() {
        leadUpright.transform = CGAffineTransform(scaleX: 1, y: -1)   // upright in the inverted table
        leadBox.addSubview(leadUpright)
        leadBox.accessibilityIdentifier = "chat.lead"
        leadSizeWatch = tableView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.queueLeadLayout() }
        }
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(leadFieldBegan(_:)), name: name, object: nil)
        }
        layoutLead()
    }

    @objc private func leadFieldBegan(_ note: Notification) {
        guard let field = note.object as? UIView, field.isDescendant(of: leadUpright) else { return }
        leadPinEnded = true   // writing in the lead: the field's place wins over the lead's top
        DispatchQueue.main.async { [weak self] in self?.revealLeadField(animated: true) }
    }

    /// [tasks] A field in the lead that takes the keys (a step, the notes) stays in sight between the top bar and what
    /// sits on the keys. The chat keeps what is just above the composer as the keys rise, which lifted a field near
    /// the top out of view.
    private func revealLeadField(animated: Bool) {
        guard lead != nil, lead?.view.isHidden == false, !tableView.isTracking,
              let field = Self.firstResponder(in: leadUpright) else { return }
        let rect = field.convert(field.bounds, to: view)
        let top = topInset + 8, bottom = transcriptBottom - 8
        guard bottom - top > 44 else { return }
        var shift: CGFloat = 0   // how far the content moves up the screen
        if rect.maxY > bottom { shift = rect.maxY - bottom }
        if rect.minY - shift < top { shift = rect.minY - top }
        guard abs(shift) > 0.5 else { return }
        leadPinEnded = true
        stopGlide()
        stopStreamGlide()
        following = false
        anchorMessageId = nil
        // Upside down: a larger offset moves the table's content down the screen.
        let low = -tableView.contentInset.top
        let high = max(low, tableView.contentSize.height + tableView.contentInset.bottom - tableView.bounds.height)
        let y = min(max(tableView.contentOffset.y - shift, low), high)
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews { if let hit = firstResponder(in: sub) { return hit } }
        return nil
    }

    /// Off the table's own update: the footer is set again once its rows have settled.
    private func queueLeadLayout() {
        guard !leadLayoutQueued else { return }
        leadLayoutQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.leadLayoutQueued = false
            self?.layoutLead()
        }
    }

    private func layoutLead() {
        guard let lead, isViewLoaded, tableView.bounds.width > 0 else { return }
        let all = model.hiddenOlder == 0 && model.builtFrom == 0
        let boxNow = tableView.tableFooterView === leadBox ? leadBox.bounds.height : 0
        let rowsHeight = max(0, tableView.contentSize.height - boxNow)
        let room = tableView.bounds.height - tableView.contentInset.top - topInset
        let width = tableView.bounds.width
        let column = ReadableColumn.fit(pane: width)
        let foot = leadFoot.map {
            $0.view.systemLayoutSizeFitting(CGSize(width: column.width, height: UIView.layoutFittingCompressedSize.height),
                                            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height.rounded(.up)
        } ?? 0
        let height = all ? max(leadHeight + foot, room - rowsHeight).rounded(.up) : 0
        if tableView.tableFooterView !== leadBox || abs(boxNow - height) > 0.5 || leadBox.bounds.width != width {
            leadBox.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableFooterView = leadBox
        }
        leadUpright.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        leadUpright.center = CGPoint(x: width / 2, y: height / 2)
        let frame = CGRect(x: column.margin, y: 0, width: column.width, height: max(leadHeight, 1))
        if lead.view.frame != frame { lead.view.frame = frame }
        lead.view.isHidden = !all
        if let leadFoot {
            let place = CGRect(x: column.margin, y: max(leadHeight, height - foot), width: column.width, height: foot)
            if leadFoot.view.frame != place { leadFoot.view.frame = place }
            leadFoot.view.isHidden = !all
        }
        // The page opens on the task: its top stays put as history, replies, the keys or a tip card come, as any chat
        // scrolled up keeps its place (a task with no chat opened at the bottom of a long lead).
        guard all, leadHeight > 0, !leadPinEnded else { return }
        if tableView.isTracking { leadPinEnded = true; return }
        if tableView.contentSize.height > room + 1 { showLead(animated: false) }
    }

    /// [tasks] The lead in view, the transcript's start (Ask's first look, the title's tap).
    func showLead(animated: Bool) {
        guard lead != nil, tableView.tableFooterView === leadBox else { return }
        stopGlide()
        stopStreamGlide()
        following = false
        anchorMessageId = nil
        let top = max(tableView.contentSize.height + topInset - tableView.bounds.height, -tableView.contentInset.top)
        tableView.setContentOffset(CGPoint(x: 0, y: top), animated: animated)
    }

    // MARK: Debug

    /// Rows the table holds / rows built, and whether older history can still arrive (perf probe).
    var debugCounts: (shown: Int, built: Int, canGrowOlder: Bool) {
        (rows.count, model.allRows.count, model.hiddenOlder > 0 || model.builtFrom > 0 || session.hasOlder || session.isLoadingOlder)
    }

    #if DEBUG
    /// Tests: the layouts of the rows the table holds.
    var debugLayouts: [RowLayout] { layouts }

    /// Tests: holds the layout queue until the returned closure runs, so a measure lands after newer deltas.
    func debugHoldLayoutQueue() -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        layoutQueue.async { gate.wait() }
        return { gate.signal() }
    }

    /// [updates] Opens every grouped line (screenshots: `-HQDemoOpenGroups`); `member` (1 = the top one) then opens
    /// that member of the first group (`-HQDemoOpenMember <n>`).
    func debugOpenGroups(member: Int?) {
        for row in model.allRows where row.id.hasSuffix(UpdateGroups.lineSuffix) { expanded.insert(row.id) }
        activityRebuildAll()
        guard let member else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let line = self.model.allRows.lastIndex(where: { $0.id.hasSuffix(UpdateGroups.lineSuffix) }) else { return }
            // Newest first: the first line's members sit just before it, the top one nearest.
            let members = Array(self.model.allRows[..<line].reversed().prefix { if case .updateMember = $0.kind { return true } else { return false } })
            guard member >= 1, member <= members.count, case .updateMember = members[member - 1].kind else { return }
            self.expanded.insert(members[member - 1].id)
            self.activityRebuildAll()
        }
    }

    /// Opens the tool rows of the newest message that has them (screenshots).
    func debugExpandNewestTools() {
        var lowest: String?
        for row in rows.prefix(40) {
            switch row.kind {
            case .toolRun(let t) where t.tools.count > 1: expanded.insert(row.id); lowest = row.messageId
            case .thought: expanded.insert(row.id); lowest = row.messageId
            case .backgroundResult(let b) where b.group?.count == 1: expanded.insert(row.id); lowest = row.messageId
            default: break
            }
        }
        if let lowest, let index = session.messages.lastIndex(where: { $0.id == lowest }) {
            model.rebuildNewest(input(), fromMessage: max(0, index - 1))
            requestApply(urgent: true)
        }
    }

    func debugSendComposer() { composer.submit() }

    /// Scrolls toward older rows by `points` and stops following (screenshots).
    func debugScroll(by points: CGFloat) {
        following = false
        tableView.contentOffset.y = min(tableView.contentOffset.y + points,
                                        max(minOffset, tableView.contentSize.height + topInset - tableView.bounds.height))
        updateJumpButton()
        revealIfNeeded()
    }

    /// The held reply's first row: its top, from the screen's top (keyboard checks).
    var debugAnchorRowTop: CGFloat? {
        guard let anchorMessageId, let id = rows.last(where: { $0.messageId == anchorMessageId })?.id else { return nil }
        return screenTop(ofRow: id)
    }

    /// The row ids on screen, top to bottom (tests and traces).
    var debugVisibleRowIds: [String] {
        (tableView.indexPathsForVisibleRows ?? []).sorted { $0.row > $1.row }.map { rows[$0.row].id }
    }
    #endif
}

/// CSS cubic-bezier timing (x(t) solved by Newton's method, bisection fallback).
nonisolated struct UnitBezier {
    let ax, bx, cx, ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    func solve(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        var t = p
        for _ in 0..<8 {
            let e = x(t) - p
            if abs(e) < 1e-6 { return y(t) }
            let d = dx(t)
            if abs(d) < 1e-6 { break }
            t -= e / d
        }
        var lo = 0.0, hi = 1.0
        t = p
        for _ in 0..<30 {
            let v = x(t)
            if abs(v - p) < 1e-6 { break }
            if v < p { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return y(t)
    }
}

/// Hands immutable values (attributed strings) to a background queue.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A display-link glide's own clock (verify round 3): a frame counts its real length, but a gap longer than `hitch` (a
/// main-thread hitch) counts as one ordinary frame, so the glide pauses for it instead of skipping the rest of its way in
/// one frame. After the question dock left, the keyboard's teardown held the main thread ~200 ms and the reply's
/// wall-clock glide jumped its last 24-37 pt. Ordinary long frames (load, 30-50 ms) keep the glide's own duration.
struct GlideClock {
    static let hitch: CFTimeInterval = 0.05
    static let pausedFrame: CFTimeInterval = 1.0 / 60
    private(set) var elapsed: CFTimeInterval = 0
    private var last: CFTimeInterval = 0

    static func started(_ now: CFTimeInterval = CACurrentMediaTime()) -> GlideClock {
        var clock = GlideClock()
        clock.start(now)
        return clock
    }

    mutating func start(_ now: CFTimeInterval = CACurrentMediaTime()) {
        elapsed = 0
        last = now
    }

    private static func step(_ gap: CFTimeInterval) -> CFTimeInterval {
        let dt = max(0, gap)
        return dt > hitch ? pausedFrame : dt
    }

    /// Advances to `now` and returns the time elapsed on this clock.
    mutating func tick(_ now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        elapsed += Self.step(now - last)
        last = now
        return elapsed
    }

    /// What `tick` would return now, without advancing.
    func peek(_ now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        elapsed + Self.step(now - last)
    }
}

// [talk] The away pill rests above everything at this screen's bottom (docs/spec/3x-talk.md §6.6).
extension ChatViewController: TalkPillAnchoring {
    var talkPillBottomInWindow: CGFloat {
        guard isViewLoaded else { return 0 }
        return view.convert(CGPoint(x: 0, y: bottomStackTop), to: nil).y
    }
}

/// The chat's table. A drag that starts on a row's button (a tool, delivery or note line, a link chip) scrolls the
/// chat; by default a scroll view leaves a touch that began on a control with the control (owner, 2026-10-18).
final class ChatTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    /// [tinted-bubbles] Every scroll step and row move lays the table out: tinted bubbles line their slice of the Chat
    /// Background's soft copy up with it again. [reply-backing] A glass bubble taller than the screen moves its glass to
    /// the part on screen.
    override func layoutSubviews() {
        super.layoutSubviews()
        TintedBubbles.realign()
        GlassBubbles.realign()
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac audit 2026-11-02 #11: a drag that starts on a message's text selects it instead of scrolling the chat
    /// (ChatTextSelection.swift); a trackpad or wheel still scrolls.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if textSelectionClaims(gestureRecognizer) { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    #endif
}
