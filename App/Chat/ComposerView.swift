import UIKit

/// [composer] A view over the composer (an edit's banner) that follows the field's words.
protocol ComposerFieldWatching: AnyObject {
    func composerTextChanged(_ text: String)
}

/// The composer row (spec 06 §4.3): one growing glass bar holding ☰, +, the field, the mic and the primary circle
/// (Talk / Send / Stop). Telegram's placement: glass 26 pt from the screen's sides and 29 pt above its bottom with the
/// keyboard down, 8 pt from the sides and above the keys with it up. The view controller pins this view to the keyboard
/// layout guide; the side inset follows the row's own distance from the screen bottom, so it changes inside the
/// keyboard's animation.
final class ComposerView: UIView, UITextViewDelegate, HoldsOwnGlass, KeepsKeyboardOnTap {
    /// VOICE: `.talk` starts a live conversation and `.stopDictation` ends a dictation (docs/spec/3x-talk.md §5.1, §8).
    enum Primary: Equatable { case send, stop, disabled, talk, stopDictation }

    var onSend: ((String) -> Void)?
    /// For the length of a send: whether, while a reply runs, the message waits in the queue instead of going into the
    /// reply. A tap on Send or Return follows Settings › Chat › Send While Replying (`SendWhileBusy`); ⌘Return does
    /// the other one (the desktop's ⌘Enter, `use-composer-submit.ts:360-367`); Send's hold menu says which.
    var sendsToQueue: Bool { pickedQueue ?? SendWhileBusy.queues(chosen: SendWhileBusy.chosen) }
    /// Set for the length of a ⌘Return send or one picked from Send's hold menu; nil, a tap.
    private var pickedQueue: Bool?
    var onStop: (() -> Void)?
    /// Asked before the field takes focus (coast catch: a tap that stops a flick must not raise the keyboard).
    var shouldBeginEditing: (() -> Bool)?
    /// Called when the row's height changes (the field grew or shrank).
    var onHeightChange: (() -> Void)?
    /// [attachments] The field's text changed (typed or set): the chat's draft keeps it (docs/spec/1x-attachments.md §6.6).
    var onTextChange: ((String) -> Void)?
    /// [composer-drawers] The text or the caret moved: the slash / @ drawer follows (docs/spec/3x-composer.md §9, §10).
    var onDrawerInput: (() -> Void)?

    var placeholder: String = "Message" { didSet { placeholderLabel.text = placeholder; setNeedsLayout() } }

    /// [a11y] What the field shows for `placeholder` in `width`: the whole line when it fits at its full size, else
    /// plain "Message" for a "Message <name>" that would be cut ("Message Her…" at the largest sizes).
    static func shownPlaceholder(_ placeholder: String, font: UIFont, width: CGFloat) -> String {
        guard placeholder.hasPrefix("Message "), width > 0 else { return placeholder }
        let needed = ceil((placeholder as NSString).size(withAttributes: [.font: font]).width)
        return needed > width ? "Message" : placeholder
    }
    var isRunning = false { didSet { if isRunning != oldValue { updatePrimary(animated: true) } } }
    /// [groups] false in a room: a send mid-round joins the round, so Send has no Steer / Queue hold.
    var offersSteerQueue = true
    /// Sending allowed (the field stays editable either way, so a draft can be typed while reconnecting).
    var isEnabled = true { didSet { updatePrimary(animated: false); updateMic() } }   // VOICE: the mic dims too
    var allowsDeferredSend = false { didSet { if oldValue != allowsDeferredSend { updatePrimary(animated: false) } } }

    // MENUS (spec 1x §7.1): the ☰ commands button at the bar's leading end (the attachments stream's + goes between it
    // and the text). Hidden until the chat screen shows it (1:1 chats on iPhone).
    var onCommands: (() -> Void)? { didSet { commandsButton.onTap = onCommands } }
    var showsCommands = false { didSet { setNeedsLayout() } }
    private var commandsInRow: Bool { showsCommands }
    var commandsEnabled = true { didSet { commandsButton.isEnabled = commandsEnabled } }
    let commandsButton = ComposerGlassButton(symbol: "line.3.horizontal", label: "Commands", identifier: "composer.commands")

    // MARK: [attachments] docs/spec/1x-attachments.md §4.1, §6.2

    /// Buttons left of the text after ☰ (the + menu; spec 06 §4.3 order `[☰][+][field][primary]`), plain glyphs on the
    /// bar in 44 pt slots 36 pt apart. Setting it never removes ☰.
    var leadingAccessories: [UIView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            leadingAccessories.forEach { glassContainer.contentView.addSubview($0) }
            setNeedsLayout()
        }
    }
    /// A view above the row that moves with it (the attachment tray); `topAccessoryHeight` is its height (0 = none).
    var topAccessory: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let topAccessory { insertSubview(topAccessory, at: 0) }
            setNeedsLayout()
        }
    }
    /// [composer] A queued message's words are in the field for an edit: the circle is Save (`choosePrimary`).
    var editingQueued = false { didSet { if editingQueued != oldValue { updatePrimary(animated: true); updateMic() } } }
    /// MENUS: Edit's banner ("Editing Message" and its ✕) over everything else in the composer (nil = not editing).
    var editBanner: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let editBanner { addSubview(editBanner) }
            invalidateIntrinsicContentSize(); onHeightChange?(); setNeedsLayout()
        }
    }
    /// The banner's height at the row's width: at least 44 (its ✕'s tap target), more when its words wrap at the
    /// largest text sizes. A text-size change re-measures it through `recomputeHeight`.
    private var editBannerHeight: CGFloat {
        guard let editBanner else { return 0 }
        let width = bounds.width > 0 ? max(0, bounds.width - 2 * currentSideInset) : 320
        let fitted = editBanner.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return max(44, ceil(fitted.height))
    }
    private var editExtra: CGFloat { editBanner == nil ? 0 : editBannerHeight + 8 }
    var topAccessoryHeight: CGFloat = 0 {
        didSet { if topAccessoryHeight != oldValue { invalidateIntrinsicContentSize(); onHeightChange?(); setNeedsLayout() } }
    }
    /// Attachments in the tray: Send works without text; none may still be preparing.
    var attachmentCount = 0 { didSet { if attachmentCount != oldValue { updatePrimary(animated: true); updateMic() } } }
    var attachmentsPreparing = false { didSet { if attachmentsPreparing != oldValue { updatePrimary(animated: false) } } }
    /// The field's leading edge in the composer's coordinates (the tray's first tile lines up with it).
    private(set) var fieldLeading: CGFloat = 0 {
        // Verify round 3: the tray follows the field when its side inset changes with the keyboard (26 ↔ 8 pt), in the
        // same layout pass (and so the same animation), not only when its tiles change.
        didSet { if abs(fieldLeading - oldValue) > 0.25 { onFieldLeadingChange?(fieldLeading) } }
    }
    /// The field's leading edge moved ([attachments]: the tray's first tile).
    var onFieldLeadingChange: ((CGFloat) -> Void)?
    /// The tray's tiles in window coordinates (nil when empty): a send with attachments lifts out of them and the
    /// text box together (spec §6.4 step 2).
    var accessoryLiftBox: (() -> CGRect?)?

    let textView: UITextView = ComposerTextView()
    /// What sits left of the field, in order: ☰ (when shown), then the accessories.
    /// [composer-expand] The bar puts + first, on its disc at the round end, and ☰ after it: the mirror of the mic and
    /// the circle at the other end.
    private var leadingViews: [UIView] {
        let commands: [UIView] = commandsInRow ? [commandsButton] : []
        return barMode ? leadingAccessories + commands : commands + leadingAccessories
    }
    private let glassContainer: UIVisualEffectView = {
        let container = UIGlassContainerEffect()
        container.spacing = ChatMetrics.glassSpacing
        return UIVisualEffectView(effect: container)
    }()
    private let field: UIVisualEffectView = {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        let view = UIVisualEffectView(effect: glass)
        view.cornerConfiguration = .corners(radius: .fixed(ChatMetrics.fieldRadius))
        return view
    }()
    private let placeholderLabel = UILabel()
    private let primaryButton = PrimaryButton()
    private var fieldHeight: CGFloat = ChatMetrics.control
    private(set) var primary: Primary = .disabled

    // MARK: VOICE (spec 1x-voice §3.1, §3.5, §3.6): the mic in the field, the recorder's row, the draft chip

    /// What the primary does while a memo is on screen: the composer's own rule, hidden (holding), or Send.
    enum MemoPrimary: Equatable { case normal, hidden, send(enabled: Bool) }
    /// The 44 pt mic at the field's trailing end (only on an empty composer).
    let mic = MemoMicControl()
    /// Voice is wired for this chat (a live chat with an account).
    var micAvailable = false { didSet { if micAvailable != oldValue { updateMic(); setNeedsLayout() } } }
    /// A take runs in this chat: the mic gives way to the recorder.
    var memoActive = false { didSet { if memoActive != oldValue { updateMic(); setNeedsLayout() } } }
    var memoPrimary: MemoPrimary = .normal { didSet { if memoPrimary != oldValue { updatePrimary(animated: true) } } }
    /// Send while the recorder shows Send, or with a draft chip (the field's words go with the memo).
    var onMemoSend: (() -> Void)?
    // [talk] Talk in the circle (docs/spec/3x-talk.md §5.1). `ChatVoiceHost` says when a conversation could start here.
    var talkAvailable = false { didSet { if talkAvailable != oldValue { updatePrimary(animated: true) } } }
    var talkName = "Hermes" { didSet { if talkName != oldValue { primaryButton.talkName = talkName; updatePrimary(animated: false) } } }
    var onTalk: (() -> Void)?
    /// [talk] The circle became something else (the Talk tip steps aside when it is no longer Talk).
    var onPrimaryChange: (() -> Void)?
    /// The voice options menu shown when Talk is held (nil: no menu).
    var talkMenu: (() -> UIMenu?)? { didSet { primaryButton.menuProvider = talkMenu } }
    /// VoiceOver's "Voice options" action on Talk (the same menu, as a list).
    var onTalkOptions: (() -> Void)? { didSet { primaryButton.onOptions = onTalkOptions } }
    func refreshTalkMenu() { primaryButton.refreshVisibleMenu() }
    /// A dictation records or transcribes: the circle is Stop Dictation (§8).
    var dictating = false { didSet { if dictating != oldValue { updatePrimary(animated: true); updateMic() } } }
    /// [talk] The words are being fetched: Stop Dictation has nothing left to stop, so it is dimmed (✕ still cancels).
    var dictationBusy = false { didSet { if dictationBusy != oldValue { updatePrimary(animated: true) } } }
    var onStopDictation: (() -> Void)?
    /// The primary circle (the Talk tip points at it).
    var primaryView: UIView { primaryButton }

    // [talk] A card that stood in the composer's place just left (End on the voice dock, an answered question). The
    // mic and the circle come back under the very finger that dismissed it, so the second tap of a double tap on End
    // used to start a hands-free memo (stress round 1). Touches that began before `quietUntil` (the same clock as a
    // touch's timestamp) are taken by the composer itself and do nothing: no recording, no conversation, no send. The
    // field, ☰ and + are not affected, and neither is VoiceOver's activation (it never asks which view was hit).
    static let quietAfterDock: TimeInterval = 0.8
    private(set) var quietUntil: TimeInterval = 0
    func quietActions(for seconds: TimeInterval = ComposerView.quietAfterDock, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        quietUntil = max(quietUntil, now + seconds)
    }

    /// What a touch that began at `time` on `hit` reaches: the composer itself (nothing) for the mic or the circle
    /// while it is quiet, otherwise `hit`.
    func target(for hit: UIView?, touchTime time: TimeInterval) -> UIView? {
        guard let hit, time < quietUntil else { return hit }
        return hit.isDescendant(of: mic) || hit.isDescendant(of: primaryButton) ? self : hit
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let event, event.type == .touches else { return hit }
        return target(for: hit, touchTime: event.timestamp)
    }
    /// The draft chip above the field (nil = none). The row grows by its height plus 8 pt.
    var memoChip: UIView? {
        didSet {
            guard memoChip !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let memoChip { glassContainer.contentView.addSubview(memoChip) }
            refitForRows(animated: false)   // [composer-expand] a draft memo has the bar in one row, as before
            updateMic()
            updatePrimary(animated: true)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            onHeightChange?()
        }
    }
    /// [ui-sizing 2026-11-09] At least 44, and room for the chip's title over its status: a fixed 44 held them
    /// touching at 100 % and clipped them from about 125 % (UI Scale or a larger text size).
    static var memoChipHeight: CGFloat {
        max(44, ceil(HQFont.preferred(.subheadline).lineHeight + HQFont.preferred(.caption1).lineHeight) + 10)
    }
    private var chipExtra: CGFloat { memoChip == nil ? 0 : Self.memoChipHeight + 8 }
    /// The recorder's row, inside the field's glass (the field keeps its height; the text view goes invisible).
    var recorderContent: UIView? {
        didSet {
            guard recorderContent !== oldValue else { return }
            defer { if heard != nil { heardChanged() } }   // [live words] the words row comes and goes with the recorder
            oldValue?.removeFromSuperview()
            if let recorderContent { field.contentView.addSubview(recorderContent) }
            let showText = recorderContent == nil
            textView.alpha = showText ? 1 : 0
            placeholderLabel.alpha = showText ? 1 : 0
            textView.accessibilityElementsHidden = !showText
            setNeedsLayout()
            refitForRows(animated: false)   // [composer-expand] the recorder's row stands in for the two rows (animated below)
            // Integration (verify round 1): the recorder takes the whole row, as Telegram's does: ☰ and + give way (and
            // in the Desktop Look the field widens over them), so "‹ Slide to cancel" and review's waveform get the room
            // the voice spec drew them for (~304 pt, not the ~212 pt the old row left beside ☰ and +).
            guard (oldValue == nil) != (recorderContent == nil) else { return }
            leadingRevealToken += 1
            let wide = recorderContent != nil
            guard window != nil, !HQMotion.reduced else { leadingHeld = false; return }
            if wide { leadingViews.forEach { $0.isHidden = true } }
            // Verify round 2: closing, ☰ and + stay hidden (at their own places) while the field narrows back, and fade
            // in as it reaches them — never un-hidden at once on top of a field that is still wide.
            if !wide { leadingHeld = true }
            recorderContent?.frame = field.contentView.bounds
            recorderContent?.layoutIfNeeded()
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {   // motion-ok: Reduce Motion returned in the guard above
                self.layoutIfNeeded()
            }
            if !wide { revealLeading(after: 0.15, token: leadingRevealToken) }
        }
    }
    /// The recorder shows: it has the whole row (☰ and + hidden).
    private var recorderTakesRow: Bool { recorderContent != nil }
    /// ☰ and + wait hidden while the field narrows back after the recorder closed.
    private var leadingHeld = false
    private var leadingRevealToken = 0

    private func revealLeading(after delay: TimeInterval, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.leadingRevealToken, self.leadingHeld, !self.recorderTakesRow else { return }
            self.leadingHeld = false
            for view in self.leadingViews {
                let target = view.alpha          // ☰ dims itself while disabled
                view.alpha = 0
                view.isHidden = false
                UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) { view.alpha = target }   // motion-ok: opacity only
            }
        }
    }

    // MARK: [live words] The words as you speak, where typed words go (docs/spec/3x-live-words.md §4)

    /// What the person is saying while a memo records or waits in review.
    struct Heard: Equatable {
        var words: LiveWordsText
        /// Still listening: with no words yet, "Listening…" holds their place.
        var listening: Bool
        /// The words can be fixed (a memo in review): a tap puts a caret in them.
        var editable = false
    }
    /// The heard words were fixed in review (every change).
    var onHeardEdited: ((String) -> Void)?
    /// The words row (nil: none). With the recorder on the bar, the bar grows to two rows as it does for typing: the
    /// words on top, where typed words go, and the recorder's row under them, where the buttons go. The recorder's row
    /// keeps its place and the bar grows upward, so nothing moves under a finger holding the mic.
    var heard: Heard? {
        didSet {
            guard heard != oldValue else { return }
            if let heard { heardView.update(heard.words, listening: heard.listening) }
            heardView.editable = heard?.editable ?? false
            heardChanged()
        }
    }
    /// While a memo is held the words stop at this x (in this view): clear of the lock and the halo above the
    /// recorder's circle. Nil: the field's own width.
    /// Set from the screen's layout pass: the next layout measures the bar again (`measureWidth`).
    var heardLimitX: CGFloat? { didSet { if heardLimitX != oldValue, heardShown { setNeedsLayout() } } }
    let heardView = LiveWordsView()
    /// The words row shows: the recorder has the bar and there are words (or the device is listening for them).
    private var heardShown: Bool { recorderContent != nil && heard != nil }
    /// The words row is showing or on its way in.
    private var heardVisible = false

    private func heardChanged() {
        let shown = heardShown
        heardView.maxLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 4
        recomputeHeight(notify: true)
        setNeedsLayout()
        guard shown != heardVisible else { return }
        heardVisible = shown
        if shown, heardView.isHidden {
            // In place before it fades in: it rides up with the top of the growing bar, never out of a zero frame.
            heardView.alpha = 0
            heardView.isHidden = false
            UIView.performWithoutAnimation { heardView.frame = heardFrame(fieldW: field.bounds.width, fieldX: fieldFrame.minX) }
        }
        HQMotion.animate(shown ? 0.2 : 0.12, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.heardView.alpha = shown ? 1 : 0
        } completion: { _ in
            if !self.heardVisible { self.heardView.isHidden = true }
        }
    }

    /// The words' frame in a field `fieldW` wide whose leading edge is at `fieldX` (in this view): where typed words
    /// start, above the recorder's row.
    private func heardFrame(fieldW: CGFloat, fieldX: CGFloat) -> CGRect {
        let lead = barMode ? barScaled(16) : ChatMetrics.fieldPadH
        var right = fieldW - lead
        if let heardLimitX { right = min(right, heardLimitX - fieldX) }
        let width = max(60, right - lead)
        return CGRect(x: lead, y: heardTop, width: width, height: heardView.height(for: width))
    }

    /// Above the words: as far as typed words sit from the top of the two-row bar (the one-line inset in the Desktop
    /// Look's box).
    private var heardTop: CGFloat {
        if barMode { return barScaled(16) }
        let line = textView.font?.lineHeight ?? 20
        return max(8, ((ChatMetrics.control - line) / 2).rounded(.down))
    }
    /// Between the words and the recorder's row (its own 44 pt keeps ~12 pt above its timer).
    private var heardGap: CGFloat { barMode ? barScaled(4) : 4 }
    /// A held memo just sent with the keyboard down: programmatic focus waits until then (spec §3.8). A tap on the
    /// field always focuses it.
    var focusSuppressedUntil: CFTimeInterval = 0
    /// The field's frame in this view (the recorder lays its rows out against it).
    var fieldFrame: CGRect { field.frame.offsetBy(dx: glassContainer.frame.minX, dy: glassContainer.frame.minY) }
    /// The mic's centre in this view.
    var micCenter: CGPoint {
        // [desktoplook] The Desktop Look keeps the mic 36 pt from the primary circle, as close as ☰ and + sit.
        // [mac] Owner 2026-10-28: centred on the field's one-line height (the control's), as the send/voice circle is,
        // and so on its line when the field grows. A fixed 20 was half the iPhone's 40 pt control, so on the Mac
        // (51 / 54) the mic sat 5–7 pt low.
        // [composer-bar] In the bar the mic's disc sits 8 pt before the circle.
        // [live words] From the row's own bottom, never the field's last frame: the screen asks while the bar is growing
        // to two rows, before the field has moved, and the recorder's circle drew 22 pt above its row.
        let y = bounds.height - ChatMetrics.control / 2 - toolbarPad
        if Self.oneBox { return CGPoint(x: primaryButton.frame.midX - 36, y: y) }
        let p = primaryButton.frame
        switch micPlacement {
        case .disc: return CGPoint(x: p.minX - barScaled(22), y: y)   // its disc 8 pt before the circle
        case .field: return CGPoint(x: p.minX - barScaled(14), y: y)
        }
    }
    /// The mic's square: 44 pt as a glyph, the bar's button size on a disc (so its disc matches the +'s on the Mac too).
    private var micSide: CGFloat { micPlacement == .disc ? ChatMetrics.control : 44 }
    /// The mic disc's radius (its control inset 4 pt each side).
    private var micDiscRadius: CGFloat { (ChatMetrics.control - 8) / 2
    }

    /// [composer-expand] Two rows: the text across the whole bar, the buttons in a row of their own below it. Always in
    /// the iOS look (owner 2026-11-01: "the text input section at the bottom should always be the 2x height version
    /// instead of starting 1x height and growing when you click it"); not while the recorder or a draft chip has the bar.
    private var expanded: Bool {
        barMode && recorderContent == nil && memoChip == nil
    }
    /// [model-panel] Set while the model panel has the keyboard's place. The bar is two rows anyway now (and keeps the
    /// chip the panel grew out of); a change only refits it.
    var holdsRows = false {
        didSet {
            guard holdsRows != oldValue else { return }
            refitForRows()
            if !holdsRows { setNeedsLayout() }
        }
    }
    /// [composer-expand] While typing in two rows the mic stays, as Dictate (the words go in at the cursor), so each
    /// end keeps two buttons: + and ☰, the mic and Send (owner: one button against two "doesn't look balanced").
    let dictateButton = ComposerGlassButton(symbol: "mic", label: "Dictate", identifier: "composer.dictate")
    var onDictate: (() -> Void)? { didSet { dictateButton.onTap = onDictate; setNeedsLayout() } }
    private var dictateShown: Bool {
        expanded && onDictate != nil && !micShown && !dictating && !memoActive && isEnabled
    }
    /// [composer-expand] The model's name ("Opus 5.5") on a 36 pt glass capsule like the + disc, as wide as the name and
    /// centred in the room from 8 pt after ☰'s disc to 8 pt before the next disc, so the gaps match; the words always
    /// fit (`ModelChip`). A tap opens the model panel. Owner 2026-10-31: "missing something", "in a bubble", "minimal
    /// info", then "that must be always even … never … an ellipsis"; 2026-11-01: only the name, the bubble small.
    /// Chats that can't switch models leave `modelChipTitle` nil and the row as it was. It stays while the chat is
    /// offline or reconnecting (the panel then says "Offline · changes wait for the gateway"): the bar keeps its shape.
    let modelChip = ModelChip()
    var modelChipTitle: (() -> ModelChip.Title?)? { didSet { refreshModelChip() } }
    private var modelChipShown: Bool { (expanded || macBoxChip) && modelChip.title != nil }
    /// [mac] Owner 2026-11-08 ("work in the model selector and have the pop up function the same in Mac as it does iOS"):
    /// in the Mac's one box the model's name sits at the box's trailing end, before the mic (or the circle), and opens
    /// the same model panel as the iPhone's bubble. Not while the recorder or a draft memo has the box.
    private var macBoxChip: Bool { DeviceWord.isMac && Self.oneBox && recorderContent == nil && memoChip == nil }
    private static let macChipHeight: CGFloat = 28
    /// The Mac chip's width in a field `fieldW` wide (0 when it doesn't show or has no room).
    private func macChipWidth(fieldW: CGFloat) -> CGFloat {
        guard macBoxChip, modelChip.title != nil, !recorderTakesRow, !leadingHeld else { return 0 }
        let w = modelChip.fittedWidth(in: min(240, fieldW * 0.4), height: Self.macChipHeight)
        return w >= 56 ? w : 0
    }

    /// Reads the title again (after a switch, and each time the bar grows to two rows). A bubble on screen eases to
    /// the new name's width.
    func refreshModelChip() {
        let title = modelChipTitle?().flatMap { $0.name.isEmpty ? nil : $0 }
        guard title != modelChip.title else { return }
        let resizes = modelChip.title != nil && !modelChip.isHidden && window != nil && !HQMotion.reduced
        modelChip.title = title
        setNeedsLayout()
        guard resizes else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {   // motion-ok: Reduce Motion skips it (above)
            self.layoutIfNeeded()
        }
    }

    /// The row of buttons under the text while `expanded` (the bar's height in one row).
    var toolbarHeight: CGFloat { expanded ? ChatMetrics.control + toolbarPad : 0 }
    /// [composer-expand] In two rows the buttons sit 4 pt further in from the card's edges (8 pt to the discs' edges),
    /// and the card's corner grows by as much, so the discs stay concentric with it and don't crowd its corners.
    private var toolbarPad: CGFloat { expanded ? barScaled(4) : 0 }
    /// Where the mic sits: a glyph in the field beside the circle (the Desktop Look), or [composer-expand] on its own
    /// disc 8 pt before the circle (the iOS look's bar, in one row or two). Owner 2026-10-31: ☰ and the mic gaining
    /// their glass only when the field was tapped "feels wrong", so the bar's buttons wear it from the start.
    enum MicPlacement { case field, disc }
    /// A touch it is tracking, or a take starting or on screen, keeps it where it began.
    var micPlacement: MicPlacement {
        if mic.isTracking || mic.pressed || memoActive { return mic.placement }
        return barMode ? .disc : .field
    }
    /// Only on an empty field with an empty tray (spec 1x-voice V5).
    private var micShown: Bool {
        micAvailable && !memoActive && !dictating && memoChip == nil && textView.text.isEmpty && attachmentCount == 0   // [talk] !dictating
            && !editingQueued   // [composer] a memo isn't a queued message's new words
    }

    /// The mic stays in place under a finger still holding it (hiding a tracking control would drop its touch); its
    /// glyph gives way to the recorder.
    func updateMic() {
        let shown = micShown
        let holding = memoActive && mic.isTracking
        // [perf] The row lays out again only when the mic comes or goes (its inset narrows the text), not per keystroke.
        let changed = mic.isHidden != !(shown || holding) || lastMicShown != shown
        lastMicShown = shown
        mic.isHidden = !(shown || holding)
        mic.contentHidden = !shown
        syncMicPlacement()
        mic.isEnabled = isEnabled || holding
        mic.alpha = isEnabled || holding ? 1 : 0.4
        if changed { setNeedsLayout() }
    }
    /// `micShown` as of the last `updateMic` (the text view's `micInset` follows it).
    private var lastMicShown: Bool?

    /// [composer-voice] The mic takes its place and its look.
    private func syncMicPlacement() {
        let placement = micPlacement
        guard mic.placement != placement else { return }
        mic.placement = placement
        mic.onDisc = placement == .disc
        setNeedsLayout()
    }

    /// [keyboard] The pull down on the message box that puts the keyboard away (see `init`).
    private let pullGate = ComposerPullGate()

    /// Downward, steeper than it is sideways, while the field has the keys and no memo holds the circle; in a field
    /// with more lines than it shows, only from its first line (further down the drag scrolls the words).
    private func pullMayBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard textView.isFirstResponder, memoPrimary == .normal else { return false }
        let v = pan.velocity(in: self)
        guard v.y > 0, v.y > abs(v.x) * 1.5 else { return false }
        let scrolls = textView.contentSize.height > textView.bounds.height + 1
        return !scrolls || textView.contentOffset.y <= 0 || !textView.bounds.contains(pan.location(in: textView))
    }

    @objc private func pulledDown(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .changed, pan.translation(in: self).y > 16, textView.isFirstResponder else { return }
        AppLog.trace("chatui", "keyboard put away by a pull down on the message box")
        textView.resignFirstResponder()
        pan.isEnabled = false   // ends this pull
        pan.isEnabled = true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        desktopBox.isUserInteractionEnabled = false      // [desktoplook2] the one-box composer's box
        desktopBox.isHidden = true
        macBacking.isUserInteractionEnabled = false      // [mac-message-box] the page, under and beside the box
        macBacking.isHidden = true
        macBacking.layer.addSublayer(macBackingFade)
        addSubview(macBacking)
        addSubview(desktopBox)
        addSubview(glassContainer)
        glassContainer.contentView.addSubview(field)
        commandsButton.isHidden = true                 // MENUS
        glassContainer.contentView.addSubview(commandsButton)

        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        textView.backgroundColor = .clear
        textView.font = composerFont(style)
        textView.textColor = ChatPalette.label
        textView.tintColor = ChatPalette.caret
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        // [m9/ipad] A hardware keyboard's Return does what the Send button would do right now (never Stop).
        (textView as? ComposerTextView)?.onHardwareReturn = { [weak self] command in
            guard let self, self.primary == .send else { return }
            self.send(queue: SendWhileBusy.queues(command: command, chosen: SendWhileBusy.chosen))
        }
        // [m9/composer] Return in the empty field: the chat sends a waiting queue row (docs/spec/3x-composer.md §1.2).
        // Never while dictation is being stopped or a memo holds the circle.
        (textView as? ComposerTextView)?.onHardwareReturnEmpty = { [weak self] in
            guard let self, self.primary != .stopDictation, self.memoPrimary == .normal, self.memoChip == nil else { return }
            self.onHardwareReturnEmpty?()
        }
        (textView as? ComposerTextView)?.hasMoreToSend = { [weak self] in (self?.attachmentCount ?? 0) > 0 || self?.memoChip != nil }
        textView.keyboardDismissMode = .none
        // [keyboard] Tester 2026-11-09: "dismissing the keyboard is not very responsive. I have to swipe down quickly above
        // the keyboard". The chat follows a finger dragged from the messages into the keys, which has the whole message
        // box to cross first. A short pull down that starts on the box itself now puts the keys away too.
        if !DeviceWord.isMac {
            let pull = UIPanGestureRecognizer(target: self, action: #selector(pulledDown(_:)))
            pull.cancelsTouchesInView = false
            pull.delegate = pullGate
            pullGate.begins = { [weak self] pan in self?.pullMayBegin(pan) ?? false }
            addGestureRecognizer(pull)
        }
        // [m9/composer] The keyboard behaves as in Messages (web `autocorrect-gates.ts`; docs/spec/3x-composer.md §2.2).
        // Set one by one so a later change cannot drop them without a test noticing (`ComposerKeyboard`).
        ComposerKeyboard.apply(to: textView)
        textView.accessibilityLabel = "Message"
        textView.accessibilityIdentifier = "composer.text"
        textView.showsVerticalScrollIndicator = false
        field.contentView.addSubview(textView)

        placeholderLabel.text = placeholder
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = ChatPalette.label3
        // One line, clipped (spec 06 §4.3); at the largest sizes it shrinks a little before it clips.
        placeholderLabel.adjustsFontSizeToFitWidth = true
        placeholderLabel.minimumScaleFactor = 0.7
        placeholderLabel.isUserInteractionEnabled = false
        field.contentView.addSubview(placeholderLabel)
        heardView.isHidden = true                      // [live words]
        heardView.baseFont = textView.font ?? heardView.baseFont
        heardView.onEdited = { [weak self] words in self?.onHeardEdited?(words) }
        heardView.onResize = { [weak self] in
            guard let self, self.heardShown else { return }
            self.recomputeHeight(notify: true)
            self.setNeedsLayout()
        }
        field.contentView.addSubview(heardView)

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.sendMenuProvider = { [weak self] in self?.sendOptionsMenu() }
        addSubview(primaryButton)
        // VOICE: the mic above the field's glass. A recording keeps the page behind the bar as it was: no solid dock
        // (owner 2026-11-01: a white band filled the whole bottom over the chat background while a memo recorded).
        dictateButton.isHidden = true      // [composer-expand]
        dictateButton.showsDisc = true
        addSubview(dictateButton)
        modelChip.isHidden = true
        addSubview(modelChip)
        mic.isHidden = true
        mic.onTrackingEnded = { [weak self] in DispatchQueue.main.async { self?.updateMic() } }
        addSubview(mic)
        updatePrimary(animated: false)
        lastExpanded = expanded   // [composer-expand] two rows from the start in the iOS look
        recomputeHeight(notify: false)

        // [composer-expand] A switch between the looks: two rows in the iOS look, one in the Desktop Look.
        registerForTraitChanges([ThemeGenerationTrait.self]) { (view: ComposerView, _) in
            view.refitForRows()
            // Mac polish #81: the look's text and the bar's height again once the switch has settled (the next turn
            // of the run loop). Measured inside it, the first switch kept the old look's height: 3 pt off on the Mac.
            DispatchQueue.main.async { [weak view] in view?.restyleText() }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ComposerView, _) in view.restyleText() }
        // At accessibility sizes the line cap follows the keyboard (`maxLines`): measure again once it has come or gone.
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardSettled), name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardSettled), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func keyboardSettled() { refitAtAccessibilitySizes() }

    /// The text in the chat's body size for the text size and the look in use, and the bar measured for it.
    private func restyleText() {
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        textView.font = composerFont(style)
        placeholderLabel.font = textView.font
        heardView.baseFont = textView.font ?? heardView.baseFont   // [live words]
        if heard != nil { heardChanged() }
        recomputeHeight(notify: true)
        setNeedsLayout()
    }

    /// Body, kept between 16 and 28 pt (spec 06 §10: the composer's text at accessibility sizes is capped at 28).
    private func composerFont(_ style: ChatStyle) -> UIFont {
        style.body.withSize(min(28, max(16, style.body.pointSize)))
    }

    var text: String {
        get { textView.text }
        set { textView.text = newValue; textChanged() }
    }

    // [attachments] + the tray; VOICE: + the draft chip
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fieldHeight + chipExtra + topAccessoryHeight + editExtra)   // MENUS: + Edit's banner
    }

    // MARK: Layout

    /// The row's side inset: 26 pt resting, 8 pt with the keyboard up, interpolated by how far the row sits above
    /// the screen bottom (so an interactive keyboard dismissal moves it continuously).
    private var sideInset: CGFloat {
        guard let window else { return ChatMetrics.composerSideDown + columnMargin }
        let bottom = convert(bounds, to: window).maxY
        let gap = window.bounds.height - bottom
        let progress = min(1, max(0, (gap - ChatMetrics.composerBottomDown) / 40))
        return ChatMetrics.composerSideDown - (ChatMetrics.composerSideDown - ChatMetrics.composerSideUp) * progress + columnMargin
    }

    /// [m9/ipad] In a pane wider than the readable column the row keeps to the column: this much more on each side.
    var columnMargin: CGFloat = 0 { didSet { if columnMargin != oldValue { setNeedsLayout() } } }

    /// The side inset the row was last laid out with.
    private var appliedSide: CGFloat = -1
    /// The row's current side inset (26 pt resting, 8 pt over the keys): the cards docked above it share its edges.
    var currentSideInset: CGFloat { appliedSide < 0 ? sideInset.rounded() : appliedSide }
    /// [desktoplook2] How far the look's one box reaches past the row on each side (`layoutDesktopBox`): the cards
    /// docked above it reach as far, so their edges line up with the box's.
    var boxOutset: CGFloat { Self.oneBox ? 4 : 0 }

    /// The row moved without changing size (the keyboard layout guide carries it, so `layoutSubviews` doesn't run):
    /// lay it out again when its side inset changed, inside whatever animation moved it. The screen calls this from
    /// its own layout pass, so a swipe-down dismissal narrows and widens the row with the keys (spec 06 §4.3;
    /// verification round 3 saw it wait for the field to resign and then jump).
    func followPosition() {
        guard window != nil, abs(sideInset.rounded() - appliedSide) > 0.25 else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    #if DEBUG
    private static let traceLayout = ProcessInfo.processInfo.arguments.contains("-HQDemoTraceComposer")
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        // [composer-bar] ☰ and the mic on their discs whenever the bar is (also after a switch of look).
        commandsButton.showsDisc = barMode
        syncMicPlacement()
        let side = sideInset.rounded()
        #if DEBUG
        if Self.traceLayout, side != appliedSide, let window {
            NSLog("[Composer] side %.0f -> %.0f bottomGap %.1f", appliedSide, side, window.bounds.height - convert(bounds, to: window).maxY)
        }
        #endif
        appliedSide = side
        let c = ChatMetrics.control
        let geometry = rowGeometry(width: bounds.width, side: side)
        let lead = geometry.lead, fieldW = geometry.fieldW
        // Verify round 2: the field's height is measured at the width its text gets now. The width changes with the
        // keyboard (the side inset 26 ↔ 8 pt) and when ☰ and + give way to the recorder, and a draft restored before the
        // first layout was measured at a guess: a draft's last line hid, or an empty line was left.
        if abs(measureWidth(fieldW: fieldW, fieldX: lead) - measuredWidth) > 0.5 { recomputeHeight(notify: true, fromLayout: true) }
        // [attachments] the tray above the row; ☰ and + at the row's leading end. VOICE: the draft chip between them.
        let chip = chipExtra
        let rowTop = max(0, bounds.height - fieldHeight - chip)
        topAccessory?.frame = CGRect(x: 0, y: editExtra, width: bounds.width, height: max(0, rowTop - editExtra))
        editBanner?.frame = CGRect(x: side, y: 0, width: max(0, bounds.width - 2 * side), height: editBannerHeight)   // MENUS
        // [composer-bar] The bar's trailing end: the circle is drawn 4 pt in from the bar's edge.
        let pad = toolbarPad
        primaryButton.frame = CGRect(x: bounds.width - side - c - primaryInset - pad, y: bounds.height - c - pad, width: c, height: c)
        // MENUS: ☰ then the accessories (+) at the leading edge, bottom-aligned with the primary button. Hidden for the
        // recorder, they keep their own places (verify round 2: both sat at the leading edge, on top of each other, and
        // + slid out from under ☰ when they came back).
        if !commandsInRow, !commandsButton.isHidden { commandsButton.isHidden = true }   // in the row the loop below shows it
        var slot = side + pad
        let hideLeading = recorderTakesRow || leadingHeld
        for accessory in leadingViews {
            accessory.frame = CGRect(x: slot, y: chip + fieldHeight - c - pad, width: c, height: c)
            if accessory.isHidden != hideLeading { accessory.isHidden = hideLeading }
            slot += leadingStep
        }
        fieldLeading = lead
        glassContainer.frame = CGRect(x: 0, y: rowTop, width: bounds.width, height: chip + fieldHeight)
        // VOICE: the draft chip sits above the field (leading-aligned, as wide as its content); the field below it.
        field.frame = CGRect(x: lead, y: chip, width: fieldW, height: fieldHeight)
        if let memoChip {
            // Integration: with ☰ and + before the field, the field is too narrow for "Voice Memo 0:12": the chip may
            // use the whole row, starting at the field's edge when it fits there and sliding left when it doesn't.
            let rowW = primaryButton.frame.maxX - side
            let w = min(rowW, memoChip.sizeThatFits(CGSize(width: rowW, height: Self.memoChipHeight)).width)
            let x = max(side, min(lead, primaryButton.frame.maxX - w))
            memoChip.frame = CGRect(x: x, y: 0, width: w, height: Self.memoChipHeight)
        }
        // VOICE: the text's trailing inset makes room for the mic while it shows.
        let text = textSpan(fieldW: fieldW)
        textView.frame = CGRect(x: text.lead, y: 0, width: text.width, height: fieldHeight - toolbarHeight)
        let inset = textInsets
        placeholderLabel.frame = CGRect(x: text.lead, y: inset.top, width: text.width, height: ceil(textView.font?.lineHeight ?? 20))
        let shown = Self.shownPlaceholder(placeholder, font: placeholderLabel.font, width: placeholderLabel.bounds.width)
        if placeholderLabel.text != shown { placeholderLabel.text = shown }
        if abs(textView.textContainerInset.top - inset.top) > 0.1 { textView.textContainerInset = inset }
        let micHalf = micSide / 2
        mic.frame = CGRect(x: micCenter.x - micHalf, y: micCenter.y - micHalf, width: micSide, height: micSide)
        // [composer-expand] Dictate stands where the mic stood, on a disc the mic's size.
        let dictate = dictateShown
        if dictateButton.isHidden == dictate { dictateButton.isHidden = !dictate }
        if dictate {
            let half = c / 2
            dictateButton.frame = CGRect(x: primaryButton.frame.minX - barScaled(22) - half, y: primaryButton.frame.midY - half, width: c, height: c)
        }
        // [composer-expand] The model chip sits centred in the room between ☰'s disc and the next disc (the mic,
        // Dictate, or Send when neither stands there), at least 8 pt from each, so the gaps either side are the same.
        let macChip = barMode ? 0 : macChipWidth(fieldW: fieldW)
        let chipShown = modelChipShown && !hideLeading && (barMode || macChip > 0)
        if modelChip.isHidden == chipShown { modelChip.isHidden = !chipShown }
        modelChip.plain = !barMode
        if chipShown, !barMode {
            // [mac] Before the mic's glyph (or the circle while Send shows), 8 pt clear, on the circle's line.
            let p = primaryButton.frame
            let end = (micShown ? micCenter.x - 12 : p.midX - 14) - 8
            let h = Self.macChipHeight
            modelChip.frame = CGRect(x: (end - macChip).rounded(), y: (p.midY - h / 2).rounded(), width: macChip, height: h)
        } else if chipShown, let last = leadingViews.last {
            let gap = barScaled(8)
            let start = last.frame.maxX - (last.frame.width * 4 / 44).rounded() + gap
            let p = primaryButton.frame
            let nextDisc = micShown || dictate ? p.minX - barScaled(22) - micDiscRadius : p.minX + (p.width * 4 / 44).rounded()
            let h = barScaled(36)
            let room = max(0, nextDisc - gap - start)
            let w = modelChip.fittedWidth(in: room, height: h)
            modelChip.frame = CGRect(x: (start + (room - w) / 2).rounded(), y: (p.midY - h / 2).rounded(), width: w, height: h)
        }
        // [composer-bar] The recorder keeps clear of the circle at the bar's end, as it did beside the old field.
        let recorderTrail = barMode ? c + barScaled(2) : 0
        // [live words] Under the words the recorder has the bar's bottom row, where it sat before the bar grew.
        let recorderHeight = heardShown ? c : field.bounds.height
        recorderContent?.frame = CGRect(x: 0, y: field.bounds.height - recorderHeight, width: max(0, field.bounds.width - recorderTrail), height: recorderHeight)
        if heardShown { heardView.frame = heardFrame(fieldW: fieldW, fieldX: lead) }
        applySurfaces(side: side, rowTop: rowTop + chip)
    }

    // MARK: [composer-bar] One surface. Look off: ☰, +, the field, the mic and the circle share one glass bar, round at
    // one line (radius = half its 44 pt height) and a rounded rectangle as it grows; ☰, + and the mic are plain glyphs
    // on it (no glass on glass) and the circle is solid. It replaced four glass shapes side by side, which squeezed the
    // field to ~212 pt on a 402 pt phone and left the circle smaller than the buttons beside it.
    // [desktoplook2] Look on, one box (phone-ui-desktop.css:253-266): the same parts in a single bordered box on the
    // editor surface, square-cornered; the field draws nothing of its own. Send keeps its round accent button, as the
    // desktop's.

    private let desktopBox = UIView()
    /// [mac-ui-issues] The one box's frame (in the composer), nil while the bar isn't the box.
    var macBoxFrame: CGRect? { desktopBox.isHidden || desktopBox.frame.isEmpty ? nil : desktopBox.frame }
    /// [mac-message-box] The Mac's message box in the iOS look: a plain surface, not glass. It has been three things.
    /// Owner 2026-11-08: the iPhone's glass bar "didn't even try to make it look right on a Mac app", so it became the
    /// one box. Owner 2026-11-09 asked for Liquid Glass on it. Owner 2026-11-11: "ours looks like it almost doesn't
    /// belong somehow... it's like the lines and shadows aren't done right", pointing at another Mac chat app's box.
    /// Measured on the glass box: a fill four times the page's brightness (48 against 13), a bright line along its top
    /// and bottom and none down its sides, 14 pt corners on a 61 pt box, the chat smeared through it, and the hint
    /// 3 pt above the line the ☰, +, model and mic stand on. The other app's box is its page one step lighter, one
    /// faint line all round, rounder corners and no shadow. This is that recipe in the look's own colours
    /// (`MacMessageBox`). The Desktop Look keeps its own box.
    static var macPlainBox: Bool { DeviceWord.isMac && !Theme.isDesktop }
    /// [mac-message-box] The page's own colour under the box: the chat scrolls behind the composer, and round a box
    /// that is no longer see-through its bubbles showed in the 12 pt beside it and the strip under it (a blue corner
    /// past the box's end). The transcript fades out over the 24 pt at the box's top edge and nothing shows below
    /// that. Not over a Chat Background: the picture is the page there, and it runs to the window's foot.
    private let macBacking = UIView()
    private let macBackingFade = CAGradientLayer()
    private static let backingRise: CGFloat = 14

    private func layoutMacBacking(box: CGRect) {
        let shown = Self.macPlainBox && !Backdrop.chats.shows
        if macBacking.isHidden == shown { macBacking.isHidden = !shown }
        guard shown else { return }
        // Past the composer's own foot to the window's (the composer stands a little above it).
        let frame = CGRect(x: 0, y: box.minY - Self.backingRise, width: bounds.width, height: bounds.height - box.minY + Self.backingRise + 400)
        let page = ChatPalette.page.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        macBacking.frame = frame
        macBackingFade.frame = macBacking.bounds
        macBackingFade.colors = [page.withAlphaComponent(0).cgColor, page.cgColor, page.cgColor]
        macBackingFade.locations = [0, NSNumber(value: Double(min(1, (Self.backingRise + 10) / frame.height))), 1]
        CATransaction.commit()
    }
    /// [mac] The iOS look's one box: rounded, not the Desktop Look's square corners.
    static let macBoxRadius: CGFloat = MacMessageBox.radius
    private var appliedFieldRadius: CGFloat = -1

    /// True in the iOS look on the iPhone and iPad: the field's glass is the whole row's bar. [desktop-composer] In the
    /// iPhone's Desktop Look too, unless Theme › Text Box › Desktop is picked.
    private var barMode: Bool { !Self.oneBox }
    /// [desktop-composer] The Desktop Look leaves the bar's glass alone (`ThemeChrome.solidify`).
    var holdsOwnGlass: Bool { barMode }

    /// The one bordered box (the Desktop Look's), not the glass bar: the Desktop Look with Text Box › Desktop
    /// (`Theme.boxComposer`), and [mac] the Mac in either look. Owner 2026-11-08: "The text input section in the chats
    /// looks like we just took what was Liquid Glass from iOS and didn't even try to make it look right on a Mac app."
    /// The box takes the look's own colours.
    static var oneBox: Bool { Theme.boxComposer || DeviceWord.isMac }

    /// `points` at the iPhone's 44 pt bar, scaled to this bar's height (the Mac's is 54).
    private func barScaled(_ points: CGFloat) -> CGFloat { (points * ChatMetrics.control / 44).rounded() }

    private func applySurfaces(side: CGFloat, rowTop: CGFloat) {
        let desktop = Self.oneBox
        desktopBox.isHidden = !desktop
        // ☰ and + never draw glass of their own: they sit on the bar or in the box. [desktoplook3] A leading button that
        // holds its glass inside (the + circle) is flattened too.
        let leadingGlass = leadingViews.flatMap { view -> [UIVisualEffectView] in
            if let glass = view as? UIVisualEffectView { return [glass] }
            return view.subviews.compactMap { $0 as? UIVisualEffectView }
        }
        // [composer-glass] In the iOS look they hold glass discs, which draw only inside a glass container.
        for part in leadingGlass { flatten(part, holdsGlass: !desktop) }
        flatten(dictateButton, holdsGlass: !desktop)   // [composer-expand] a glyph on the bar
        if desktop {
            flatten(field)
            let box = CGRect(x: side - boxOutset, y: rowTop - 3, width: bounds.width - 2 * side + 2 * boxOutset, height: fieldHeight + 6)
            desktopBox.frame = box
            let plainBox = Self.macPlainBox
            layoutMacBacking(box: box)
            desktopBox.backgroundColor = plainBox ? MacMessageBox.fill : ChatPalette.editor
            // [mac] The iOS look's box rounder, as a Mac text field in Messages is. [desktop-corners] The Desktop Look's
            // takes the look's Corners, as your messages' boxes (the desktop's 4 pt unless another was picked), up to a
            // capsule at one line.
            desktopBox.layer.cornerRadius = Theme.isDesktop ? min(ChatMetrics.bubbleRadius, box.height / 2) : Self.macBoxRadius
            desktopBox.layer.cornerCurve = .continuous
            desktopBox.layer.borderWidth = 1
            // The desktop's surface keeps its quiet line (styles.css:1997, stroke-secondary); typing steps it up to the
            // bar's own outline, never the accent (a blue ring read as a web form field, owner 2026-10-15).
            // [mac-message-box] The iOS look's box: one even line all round, a step stronger while typing.
            let focused = textView.isFirstResponder
            let line = plainBox ? (focused ? MacMessageBox.lineTyping : MacMessageBox.line)
                                : (focused ? ChatPalette.composerBorder : ChatPalette.strokeSecondary)
            desktopBox.layer.borderColor = line.resolvedColor(with: traitCollection).cgColor
        } else if field.effect == nil {
            macBacking.isHidden = true
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            field.effect = glass
            field.backgroundColor = nil
        }
        let radius = desktop ? (Theme.isDesktop ? ChatMetrics.fieldRadius : Self.macBoxRadius) : barRadius
        if radius != appliedFieldRadius {
            appliedFieldRadius = radius
            field.cornerConfiguration = .corners(radius: .fixed(radius))
        }
    }

    /// [composer-bar] The bar's corner: half the 44 pt control, plus the two-row inset so the discs stay concentric.
    /// [desktop-corners] In the Desktop Look it follows the look's Corners, so the bar and your messages' boxes round
    /// alike (owner 2026-11-08: "have the radius that the user picks for the chat bubble affect it"): 4 pt above them,
    /// as the discs sit 8 pt in, up to the iOS look's own corner at the slider's end.
    private var barRadius: CGFloat {
        let round = ChatMetrics.control / 2 + toolbarPad
        guard Theme.isDesktop else { return round }
        return min(round, ChatMetrics.bubbleRadius + toolbarPad)
    }

    /// `holdsGlass`: a container effect instead of none (it draws nothing itself, and lets a glass disc inside draw).
    private func flatten(_ part: UIVisualEffectView, holdsGlass: Bool = false) {
        DesktopLayout.keepOwnLook(part)
        if holdsGlass {
            if !(part.effect is UIGlassContainerEffect) { part.effect = UIGlassContainerEffect() }
        } else if part.effect != nil {
            part.effect = nil
        }
        part.backgroundColor = .clear
        part.layer.borderWidth = 0
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if Self.oneBox { setNeedsLayout() }   // [desktoplook2] focus ring
        refitAtAccessibilitySizes()
        if expanded { refreshModelChip() }   // the catalog may have named the model better since
        refitForRows()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if Self.oneBox { setNeedsLayout() }
        refitAtAccessibilitySizes()
        refitForRows()
    }

    /// [composer-expand] The rows changed: the recorder or a draft memo took the bar or gave it back, or the look
    /// changed. (Focus no longer does: the iOS look's bar is two rows from the start.) `animated` false when the caller
    /// animates the layout itself.
    private var lastExpanded = false
    private func refitForRows(animated: Bool = true) {
        guard expanded != lastExpanded else { return }
        lastExpanded = expanded
        if expanded { refreshModelChip() }
        syncMicPlacement()
        recomputeHeight(notify: true)
        setNeedsLayout()
        guard animated, window != nil, !HQMotion.reduced else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {   // motion-ok: Reduce Motion returned in the guard above
            self.layoutIfNeeded()
        }
    }

    /// At accessibility sizes the line cap follows the keyboard (`maxLines`): the field is measured again on focus and
    /// once the keyboard has settled (`keyboardSettled`), never at a fixed delay that a slower keyboard outruns.
    private func refitAtAccessibilitySizes() {
        guard traitCollection.preferredContentSizeCategory.isAccessibilityCategory else { return }
        recomputeHeight(notify: true)
    }

    /// [desktoplook] VOICE: the text view's trailing inset grows by 20 pt while the mic shows.
    private var micInset: CGFloat { micShown ? 20 : 0 }

    /// [desktoplook] The primary slot moves 4 pt in so its smaller circle sits as far from the box's edge as ☰ does.
    private var primaryInset: CGFloat { Self.oneBox ? 4 : 0 }

    /// Where the field starts and how wide it is in a row `width` wide at side inset `side`. [composer-bar] The bar
    /// spans the row. [desktoplook] ☰ and + before the field, unless the recorder has the whole row.
    private func rowGeometry(width: CGFloat, side: CGFloat) -> (lead: CGFloat, fieldW: CGFloat) {
        if barMode { return (side, width - 2 * side) }
        let c = ChatMetrics.control
        let lead = recorderTakesRow ? side : side + CGFloat(leadingViews.count) * leadingStep
        return (lead, width - side - c - ChatMetrics.composerGap - lead - primaryInset)
    }

    /// From one leading button (+, ☰) to the next. [desktoplook] 32 pt apart, close like the
    /// desktop's composer icons (24 px, 4 px apart; owner 2026-10-15), and the field starts one step after the last.
    /// Their slots overlap by 8 pt; the later view (+ over ☰, + over the field's padding) takes it.
    /// [composer-expand] On their discs (in one row or two) they stand 8 pt apart, a 44 pt step.
    private var leadingStep: CGFloat { Self.oneBox ? 32 : barScaled(44) }

    /// Where the text starts in a field `fieldW` wide and how wide it is. [composer-bar] It starts 10 pt past the last
    /// leading disc and ends 8 pt clear of the circle, or 10 pt clear of the mic's disc while the mic shows.
    private func textSpan(fieldW: CGFloat) -> (lead: CGFloat, width: CGFloat) {
        let padH = ChatMetrics.fieldPadH
        guard barMode else {
            let chip = macChipWidth(fieldW: fieldW)
            return (padH, max(0, fieldW - 2 * padH - micInset - (chip > 0 ? chip + 10 : 0)))
        }
        // [composer-expand] Two rows: the text has the whole top row, in line with the + disc's edge.
        if expanded { return (barScaled(16), max(0, fieldW - 2 * barScaled(16))) }
        let c = ChatMetrics.control
        let count = CGFloat(leadingViews.count)
        // [composer-plus] The text keeps 10 pt clear of the last disc's edge (+ or ☰), and of the mic's disc.
        let lead = count > 0 ? (count - 1) * leadingStep + c + 6 : padH + 2
        let micRoom = barScaled(22) + micDiscRadius + 10
        let trail = c + (micShown ? micRoom : barScaled(4))
        return (lead, max(0, fieldW - lead - trail))
    }

    /// The text view's width in a field `fieldW` wide.
    private func textWidth(fieldW: CGFloat) -> CGFloat { max(40, textSpan(fieldW: fieldW).width) }

    /// The width the field's height is measured at: the words row's while it shows ([live words]), else the text's.
    private func measureWidth(fieldW: CGFloat, fieldX: CGFloat) -> CGFloat {
        heardShown ? heardFrame(fieldW: fieldW, fieldX: fieldX).width : textWidth(fieldW: fieldW)
    }

    private var textInsets: UIEdgeInsets {
        let line = textView.font?.lineHeight ?? 20
        let v = max(8, ((ChatMetrics.control - line) / 2).rounded(.down))
        // [mac-message-box] The words' capitals stand above the middle of their line, so centred by the line they sat
        // 3 pt above the ☰, +, model name and mic (measured: capitals' middle 987.5, the glyphs' 990.5). One line only.
        let drop: CGFloat = Self.macPlainBox && !expanded ? min(MacMessageBox.textDrop, v - 8) : 0
        if drop > 0 { return UIEdgeInsets(top: v + drop, left: 0, bottom: v - drop, right: 0) }
        // [composer-expand] Two rows: the buttons' row below keeps its own room.
        // Owner 2026-10-31 ("it feels cluttered"): 16 pt above the text and 12 pt between it and the discs.
        return UIEdgeInsets(top: expanded ? barScaled(16) : v, left: 0, bottom: expanded ? barScaled(12) : v, right: 0)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    // MARK: Height

    private var maxLines: Int {
        guard traitCollection.preferredContentSizeCategory.isAccessibilityCategory else { return ChatMetrics.fieldMaxLines }
        // Accessibility sizes: 3 lines, and while typing up to 5 as long as they take at most 40 % of the room above the
        // keyboard (at the largest sizes that stays 3).
        guard textView.isFirstResponder, let window else { return 3 }
        // Only once the keyboard is on screen: on focus the guide still sits at the window's foot, the room is nearly the
        // whole window, and the field would grow to 5 lines and shrink back as the keys came up.
        guard window.keyboardLayoutGuide.layoutFrame.height > window.safeAreaInsets.bottom + 1 else { return 3 }
        let room = window.keyboardLayoutGuide.layoutFrame.minY - window.safeAreaInsets.top
        let line = textView.font?.lineHeight ?? 20
        let fits = Int(((room * 0.4 - textInsets.top - textInsets.bottom) / line).rounded(.down))
        return min(5, max(3, fits))
    }

    /// The text width the field's height was last measured at.
    private var measuredWidth: CGFloat = -1

    /// `fromLayout`: called inside `layoutSubviews` (the screen hears of a new height on the next turn of the run loop,
    /// never from inside its own layout pass).
    private func recomputeHeight(notify: Bool, fromLayout: Bool = false) {
        // [perf] Set only when it moved: each assignment invalidates the text container's layout (every keystroke).
        let inset = textInsets
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        // The row's own width once laid out; before that the screen's (the row spans it), never a fixed guess.
        let rowWidth = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? window?.bounds.width ?? 0)
        let side = window == nil ? ChatMetrics.composerSideDown : sideInset.rounded()
        let geometry = rowGeometry(width: rowWidth, side: side)
        if heardShown, rowWidth > 0 {
            // [live words] The words, then the recorder's one-row height under them.
            let words = heardFrame(fieldW: geometry.fieldW, fieldX: geometry.lead)
            measuredWidth = bounds.width > 0 ? words.width : -1
            setFieldHeight(words.maxY + heardGap + ChatMetrics.control, notify: notify, fromLayout: fromLayout)
            return
        }
        let width = rowWidth > 0 ? textWidth(fieldW: geometry.fieldW) : 280 - 2 * ChatMetrics.fieldPadH
        measuredWidth = bounds.width > 0 ? width : -1
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let line = textView.font?.lineHeight ?? 20
        let maxH = ceil(line * CGFloat(maxLines) + textInsets.top + textInsets.bottom)
        // [composer-expand] Two rows: the text's row is as tall as its lines (no 44 pt floor), so one short line doesn't
        // leave an empty band above the buttons.
        let h = max(expanded ? 0 : ChatMetrics.control, min(ceil(fitting), maxH)) + toolbarHeight
        let scrolls = fitting > maxH + 0.5
        if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
        setFieldHeight(h, notify: notify, fromLayout: fromLayout)
    }

    private func setFieldHeight(_ h: CGFloat, notify: Bool, fromLayout: Bool) {
        guard abs(h - fieldHeight) > 0.5 else { return }
        fieldHeight = h
        invalidateIntrinsicContentSize()
        guard notify else { return }
        if fromLayout {
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?() }
        } else {
            onHeightChange?()
        }
    }

    // MARK: Text

    func textViewDidChange(_ textView: UITextView) { textChanged() }
    func textViewDidChangeSelection(_ textView: UITextView) { onDrawerInput?() }   // [composer-drawers]

    private func textChanged() {
        // [m9/composer] A field holding nothing but leftover line breaks is blank again: the placeholder shows and Send
        // is off (web `return-line-break`; any number of stray Returns, docs/spec/3x-composer.md §2.2). Never while an
        // input method is composing.
        if textView.markedTextRange == nil, ComposerKeyboard.isLeftoverLineBreaks(textView.text ?? "") { textView.text = "" }
        placeholderLabel.isHidden = !textView.text.isEmpty
        recomputeHeight(notify: true)
        updatePrimary(animated: true)
        onTextChange?(textView.text)
        (editBanner as? ComposerFieldWatching)?.composerTextChanged(textView.text)   // [composer] Save off while blank
        onDrawerInput?()
        updateMic()   // VOICE: typing hides the mic; Send takes over
        refitForRows()   // [composer-expand] a draft set from outside (restored, cleared on send)
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        shouldBeginEditing?() ?? true
    }

    /// MENUS (spec 1x §7.4): a picked command that takes more goes ahead of the draft ("/cmd " + draft), the caret after
    /// it, and the keyboard comes up.
    func insertCommand(_ command: String) {
        let result = Self.commandInsert(command, into: text)
        text = result.text
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: result.caret, length: 0)
    }

    /// "/cmd " + draft, and where the caret goes (UTF-16). A draft that already starts with a command ("/goal x") has
    /// that command replaced, so picking /compress gives "/compress x", never "/compress /goal x" (spec 1x §8.1's
    /// `^/[^\s/]*(\s|$)`: "/home/me" is a path, not a command).
    nonisolated static func commandInsert(_ command: String, into draft: String) -> (text: String, caret: Int) {
        let prefix = command + " "
        var rest = Substring(draft)
        if rest.first == "/" {
            let name = rest.prefix(while: { !$0.isWhitespace })
            if !name.dropFirst().contains("/") {
                rest = rest.dropFirst(name.count).drop(while: { $0 == " " || $0 == "\t" })
            }
        }
        return (prefix + rest, (prefix as NSString).length)
    }

    /// ⋯ › Prompts: a picked prompt fills an empty field, else goes in at the cursor as dictated words do; the keyboard
    /// comes up with the caret after it.
    func insertPrompt(_ prompt: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = prompt
            textView.becomeFirstResponder()
            textView.selectedRange = NSRange(location: (prompt as NSString).length, length: 0)
        } else {
            insertDictation(prompt)
        }
    }

    /// [talk] Dictated words go in at the cursor, with a space before them when the text there does not end in white
    /// space, and the keyboard comes up (docs/spec/3x-talk.md §8).
    func insertDictation(_ words: String) {
        let result = Self.dictationInsert(into: textView.text ?? "", selection: textView.selectedRange, words: words)
        text = result.text
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: result.caret, length: 0)
    }

    /// The field's text with `words` at the selection, and where the caret goes (UTF-16 offsets).
    nonisolated static func dictationInsert(into text: String, selection: NSRange, words: String) -> (text: String, caret: Int) {
        let whole = text as NSString
        let start = max(0, min(selection.location == NSNotFound ? whole.length : selection.location, whole.length))
        let length = max(0, min(selection.length, whole.length - start))
        let before = whole.substring(to: start)
        let spaced = before.isEmpty || before.last?.isWhitespace == true || before.last?.isNewline == true
        let insert = (spaced ? "" : " ") + words
        return (whole.replacingCharacters(in: NSRange(location: start, length: length), with: insert), start + (insert as NSString).length)
    }

    // MARK: Primary

    private var hasText: Bool { !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func updatePrimary(animated: Bool) {
        let next: Primary
        // VOICE: the recorder hides the primary while held and shows Send when locked or in review; a draft chip sends.
        let busy = dictating && dictationBusy   // [talk]
        primaryButton.alpha = memoPrimary == .hidden ? 0 : busy ? 0.45 : 1
        primaryButton.isUserInteractionEnabled = memoPrimary != .hidden && !busy
        defer { if busy { primaryButton.accessibilityTraits.insert(.notEnabled) } else { primaryButton.accessibilityTraits.remove(.notEnabled) } }
        // [talk] The order of docs/spec/3x-talk.md §5.1, as one pure choice (`ComposerPrimaryTests`).
        let memoSend: Bool? = { if case .send(let enabled) = memoPrimary { return enabled } else { return nil } }()
        next = Self.choosePrimary(memoSend: memoSend, enabled: isEnabled, preparing: attachmentsPreparing, hasText: hasText,
                                  attachments: attachmentCount, memoChip: memoChip != nil, dictating: dictating, running: isRunning,
                                  talkAvailable: talkAvailable, editingQueued: editingQueued,
                                  allowsDeferredSend: allowsDeferredSend)
        // [composer] While a queued message is edited the circle is its Save (spec 3x-composer §15.5).
        defer {
            if memoSend == nil, next == .send || next == .disabled {
                primaryButton.accessibilityLabel = editingQueued ? "Save" : "Send"
            }
        }
        defer { if case .send = memoPrimary { primaryButton.accessibilityLabel = "Send Voice Memo" } }   // VOICE
        // A hold on Send while a reply runs picks Steer or Queue (owner 2026-10-31); typed text only, as only it steers.
        primaryButton.offersSendOptions = isEnabled && next == .send && isRunning && offersSteerQueue && hasText && attachmentCount == 0
            && memoPrimary == .normal && memoChip == nil && !editingQueued
        guard next != primary || primaryButton.kind != next else { return }
        primary = next
        primaryButton.set(next, animated: animated)
        syncMicPlacement()   // [composer-voice]
        onPrimaryChange?()   // [talk]
    }

    /// What the circle is, first match wins (docs/spec/3x-talk.md §5.1).
    nonisolated static func choosePrimary(memoSend: Bool?, enabled: Bool, preparing: Bool, hasText: Bool, attachments: Int, memoChip: Bool,
                                          dictating: Bool, running: Bool, talkAvailable: Bool, editingQueued: Bool = false,
                                          allowsDeferredSend: Bool = false) -> Primary {
        if let memoSend { return memoSend ? .send : .disabled }
        // A dictation's Stop comes before Send: its words aren't in the field yet, so a Send now would go without them
        // (owner 2026-11-01: with a picture in the tray the circle was Send, and only the picture went). It works even
        // while the chat is reconnecting (§8).
        if dictating { return .stopDictation }
        // [composer] Editing a queued message: the circle is Save (off while blank), Stop waits behind it, and the
        // queue is the phone's own, so it saves offline too (docs/spec/3x-composer.md §15.5).
        if editingQueued { return hasText ? .send : .disabled }
        if !enabled {
            return allowsDeferredSend && !preparing && !memoChip && (hasText || attachments > 0) ? .send : .disabled
        }
        if preparing && (hasText || attachments > 0) { return .disabled }      // [attachments]
        if hasText || attachments > 0 || memoChip { return .send }
        if running { return .stop }
        if talkAvailable { return .talk }
        return .disabled
    }

    /// Where the draft's own text was drawn when it was sent (window coordinates; its lines, not the field around them),
    /// readable from `onSend`: the sent bubble lifts out of it (spec 06 §5.2).
    private(set) var liftSource: CGRect?

    /// [m9/composer] A hardware Return with nothing in the field (see `EmptyReturn`).
    var onHardwareReturnEmpty: (() -> Void)?

    /// Sends the field's text (what the Send button does).
    func submit() {
        // [m9/composer] Public API only: tells the keyboard the selection is about to move, which lets it settle a
        // pending correction of the last word before the text is read (docs/spec/3x-composer.md §2.2; never private
        // keyboard API, never resigning the field).
        if textView.isFirstResponder, textView.markedTextRange == nil {
            textView.inputDelegate?.selectionWillChange(textView)
            textView.inputDelegate?.selectionDidChange(textView)
        }
        let text = ComposerKeyboard.sendText(textView.text ?? "")
        // [attachments] Never while a tile is still preparing (its import may yet fail and leave the send waiting).
        guard (!text.isEmpty || attachmentCount > 0) && !attachmentsPreparing else { return }
        let boxes = [draftTextBox(), attachmentCount > 0 ? accessoryLiftBox?() : nil].compactMap { $0 }
        liftSource = boxes.isEmpty ? nil : boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        defer { liftSource = nil }
        textView.text = ""
        // Clearing a field mid-autocorrect leaves the keyboard's suggestion state stale; reset it.
        textView.unmarkText()
        textChanged()
        onSend?(text)
    }

    /// The box around the draft's visible lines, in window coordinates (nil when nothing is drawn).
    private func draftTextBox() -> CGRect? {
        guard window != nil, let range = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return nil }
        var box = CGRect.null
        for rect in textView.selectionRects(for: range) where rect.rect.width > 0.5 && rect.rect.height > 0.5 {
            box = box.union(rect.rect)
        }
        box = box.intersection(textView.bounds)
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        return textView.convert(box, to: nil)
    }

    /// Held Send while a reply runs (owner 2026-10-31): Steer sends into the running reply, Queue waits for it to finish.
    /// A tap does the one Settings › Chat › Send While Replying chose (Steer unless changed), ⌘Return the other.
    private func sendOptionsMenu() -> UIMenu? {
        guard primaryButton.offersSendOptions else { return nil }
        let steer = UIAction(title: "Steer", subtitle: "Add to the running reply",
                             image: UIImage(systemName: "arrow.turn.down.right")) { [weak self] _ in self?.sendFromMenu(queue: false) }
        steer.accessibilityIdentifier = "composer.send.steer"
        let queue = UIAction(title: "Queue", subtitle: "Send when the reply finishes",
                             image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { [weak self] _ in self?.sendFromMenu(queue: true) }
        queue.accessibilityIdentifier = "composer.send.queue"
        return UIMenu(children: [steer, queue])
    }

    private func sendFromMenu(queue: Bool) {
        guard primary == .send else { return }
        send(queue: queue)
    }

    /// Sends as a tap on Send would, the message waiting in the queue (or not) while a reply runs.
    private func send(queue: Bool) {
        pickedQueue = queue
        defer { pickedQueue = nil }
        primaryTapped()
    }

    @objc private func primaryTapped() {
        switch primary {
        case .send:
            // VOICE: the recorder's Send, or a draft chip's (with the field's words).
            if memoPrimary != .normal || memoChip != nil { onMemoSend?(); return }
            submit()
        case .stop:
            Haptics.play(.rigid)
            onStop?()
        case .stopDictation:
            Haptics.play(.rigid)
            onStopDictation?()
        case .talk:
            // [talk] `W:src/ui-voice/voice-menu.ts:27`: a light tap, then the intro once, then the conversation.
            Haptics.play(.light)
            onTalk?()
        case .disabled:
            break
        }
    }
}

/// The primary circle, drawn 36 pt (owner, 2026-10-14: 40 looked too big; 2026-10-24: 32 "is too small") inside the
/// bar's trailing end: Send (tint, white arrow), Stop (label circle, page-colour square), disabled Send. In the iOS
/// look each is a Liquid Glass disc, tinted in that colour (owner 2026-10-31: the blue Talk circle "isn't in Liquid
/// Glass"; Send and Talk at 70 % so the glass shows); disabled Send is plain glass, as the bar's other discs.
/// [desktoplook] The Desktop Look draws it 28 pt and in the text colour for every state, as the desktop's composer
/// (control-classes.ts PRIMARY_ICON_BTN: foreground circle, background glyph; disabled at 30 %; owner 2026-10-15).
final class PrimaryButton: UIControl {
    /// The iOS look's glass (the circle's colour is its tint); the Desktop Look draws `circle` instead.
    private let disc = ComposerGlassDisc()
    private let circle = CAShapeLayer()
    private let glyph = CAShapeLayer()
    /// [talk] Talk's glyph: Apple's waveform symbol, masked so it takes `onTint` (owner, 2026-10-14: the five
    /// hand-drawn bars read as crude blobs).
    private let symbol = CALayer()
    private let symbolMask = CALayer()
    private(set) var kind: ComposerView.Primary = .disabled
    // [talk] Talk's name, its hold menu and VoiceOver's way to it (docs/spec/3x-talk.md §5.1).
    var talkName = "Hermes"
    var menuProvider: (() -> UIMenu?)? { didSet { applyTalkExtras() } }
    var onOptions: (() -> Void)? { didSet { applyTalkExtras() } }
    /// Send's hold menu (Steer / Queue), offered only while `offersSendOptions` (a reply runs, typed text in the field).
    var sendMenuProvider: (() -> UIMenu?)?
    var offersSendOptions = false { didSet { if offersSendOptions != oldValue { applyTalkExtras() } } }
    private var holdsMenu: Bool { (kind == .talk && menuProvider != nil) || (kind == .send && offersSendOptions && sendMenuProvider != nil) }
    private let largeContentViewer = UILargeContentViewerInteraction()

    /// The large-content title follows the label as it changes ("Send Voice Memo" is set after the extras run).
    override var accessibilityLabel: String? { didSet { largeContentTitle = accessibilityLabel } }

    /// Held, Talk opens the voice options menu; VoiceOver reaches it through a custom action.
    private func applyTalkExtras() {
        isContextMenuInteractionEnabled = holdsMenu
        // [a11y] A hold at the accessibility text sizes shows the circle's glyph large, named; not where a hold opens
        // Talk's voice options. The viewer's own hold is taken off there too: present, it wins the press over the menu.
        showsLargeContentViewer = !isContextMenuInteractionEnabled
        if showsLargeContentViewer, largeContentViewer.view == nil { addInteraction(largeContentViewer) }
        if !showsLargeContentViewer, largeContentViewer.view != nil { removeInteraction(largeContentViewer) }
        largeContentTitle = accessibilityLabel
        largeContentImage = UIImage(systemName: Self.largeSymbol(kind))
        if kind == .talk && onOptions != nil {
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Voice options") { [weak self] _ in self?.onOptions?(); return true }]
        } else if kind == .send && offersSendOptions, let menu = sendMenuProvider?() {
            // VoiceOver reaches Steer and Queue as actions on Send.
            accessibilityCustomActions = menu.children.compactMap { $0 as? UIAction }.map { action in
                UIAccessibilityCustomAction(name: action.title) { _ in action.performWithSender(nil, target: nil); return true }
            }
        } else {
            accessibilityCustomActions = nil
        }
    }

    /// An item that keeps the menu open changed what the menu shows (Read Replies Aloud's checkmark).
    func refreshVisibleMenu() {
        contextMenuInteraction?.updateVisibleMenu { [weak self] current in
            guard let self, let menu = self.menuProvider?() else { return current }
            return current.replacingChildren(menu.children)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(disc)
        layer.addSublayer(circle)
        layer.addSublayer(glyph)
        layer.addSublayer(symbol)
        symbol.mask = symbolMask
        glyph.lineCap = .round
        glyph.lineJoin = .round
        isAccessibilityElement = true
        accessibilityTraits = .button
        // The disabled Send it starts as (`set` returns early for an unchanged kind, so it never named this one).
        accessibilityLabel = "Send"
        accessibilityIdentifier = "composer.send"
        isEnabled = false
        scalesLargeContentImage = true
        applyTalkExtras()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: PrimaryButton, _) in view.setNeedsLayout(); view.applyColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A 48 pt hit box around the 44 pt slot.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// [talk] Accessibility is told the size that takes the touch (44 pt), not the drawn circle's 40 (stress round 1).
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds.insetBy(dx: -2, dy: -2), in: self) }
        set { super.accessibilityFrame = newValue }
    }

    override var isHighlighted: Bool {
        didSet {
            // [a11y] The press shrinks the circle; under Reduce Motion it dims instead.
            let down = isHighlighted
            if HQMotion.reduced {
                transform = .identity
                UIView.animate(withDuration: 0.12) { self.alpha = down ? 0.6 : 1 }
            } else {
                UIView.animate(withDuration: 0.12) { self.transform = down ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity }
            }
        }
    }

    func set(_ kind: ComposerView.Primary, animated: Bool) {
        let changedShape = Self.shape(kind) != Self.shape(self.kind)
        self.kind = kind
        isEnabled = kind != .disabled
        switch kind {
        case .stop: accessibilityLabel = "Stop"; accessibilityIdentifier = "composer.stop"
        case .stopDictation: accessibilityLabel = "Stop Dictation"; accessibilityIdentifier = "composer.stop-dictation"
        case .talk: accessibilityLabel = "Talk with \(talkName)"; accessibilityIdentifier = "composer.talk"
        case .send, .disabled: accessibilityLabel = "Send"; accessibilityIdentifier = "composer.send"
        }
        applyTalkExtras()   // [talk]
        // The circle's colour and its glyph change together (the circle used to turn at once while the old arrow faded
        // out on it: a dark circle with Send's arrow for a few frames). Animated properties, not a snapshot cross-fade:
        // the row may be moving at the same time (a multi-line field shrinking on send).
        let oldFill = circle.presentation()?.fillColor ?? circle.fillColor
        if animated && changedShape, !HQMotion.reduced, !ComposerView.oneBox {
            let tint = discTint()
            UIView.animate(withDuration: 0.15) { self.disc.tint = tint }   // motion-ok: guarded by HQMotion.reduced
        }
        setNeedsLayout()
        layoutIfNeeded()
        applyColors()
        if animated && changedShape, !HQMotion.reduced {
            let fill = CABasicAnimation(keyPath: "fillColor")
            fill.fromValue = oldFill
            fill.toValue = circle.fillColor
            fill.duration = 0.15
            circle.add(fill, forKey: "fill")
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.duration = 0.15
            glyph.add(show, forKey: "show")
            symbol.add(show, forKey: "show")
        }
    }

    /// The symbol the large content viewer shows for each kind (the circle itself is drawn in layers).
    private static func largeSymbol(_ kind: ComposerView.Primary) -> String {
        switch kind {
        case .stop: "stop.fill"
        case .stopDictation: "checkmark"
        case .talk: "waveform"
        case .send, .disabled: "arrow.up"
        }
    }

    private enum Shape { case arrow, square, bars, check }
    private static func shape(_ kind: ComposerView.Primary) -> Shape {
        switch kind {
        case .stop: .square
        // [talk] A dictation's Stop keeps the words, as Done does: a tick, so it never reads as discard (✕ cancels).
        case .stopDictation: .check
        case .talk: .bars
        case .send, .disabled: .arrow
        }
    }

    // [talk] The voice options menu, anchored to the circle with a circular preview so no rectangle flashes (DECISION T8).
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let menu = kind == .talk ? menuProvider?() : kind == .send && offersSendOptions ? sendMenuProvider?() : nil
        guard let menu else { return nil }
        if kind == .send { Haptics.play(.light) }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        circlePreview()
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        circlePreview()
    }

    /// The circle as drawn: 36 pt, 4 pt in from the bar's end in its 44 pt slot (the touch takes 48), so its curve
    /// runs parallel to the bar's (radius 18 inside 22). The Mac's 54 pt bar: 44 pt, 5 pt in.
    private var drawn: CGRect {
        if ComposerView.oneBox {
            // [mac-talk-glyph] The Mac's plain box: a 36 pt circle, the box's one filled button (28 in the Desktop Look).
            let side: CGFloat = ComposerView.macPlainBox ? MacMessageBox.circle : 28
            return bounds.insetBy(dx: (bounds.width - side) / 2, dy: (bounds.height - side) / 2)
        }
        let inset = (bounds.width * 4 / 44).rounded()
        return bounds.insetBy(dx: inset, dy: inset)
    }

    private func circlePreview() -> UITargetedPreview? {
        guard window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(ovalIn: drawn)
        return UITargetedPreview(view: self, parameters: parameters)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.frame = drawn
        disc.isHidden = ComposerView.oneBox
        circle.frame = bounds
        circle.path = UIBezierPath(ovalIn: drawn).cgPath
        glyph.frame = bounds
        let s = bounds.width
        // The 36 pt circle's glyphs (owner 2026-10-24: "too small"); the Desktop Look's 28 pt circle keeps the smaller ones.
        let desk = ComposerView.oneBox
        // [mac-talk-glyph] Owner 2026-11-11, circling the blue circle in the Mac's message box: "Make the blue voice
        // icon better. It sucks.", then, shown five drawn bars: "Make it like the iOS icon but sized properly for Mac."
        // It is the iPhone's waveform, as before, but the Mac's box drew it at 13 pt in a 28 pt circle, which the
        // Mac shows at 77 %: a 10 pt smudge. The plain box keeps the iPhone's proportions on the screen instead: a
        // 36 pt circle and the symbol at 19 pt, a weight heavier so its bars hold at that scale.
        let macTalk = ComposerView.macPlainBox
        symbol.isHidden = kind != .talk
        if kind == .talk {
            glyph.path = nil
            let config = macTalk ? UIImage.SymbolConfiguration(pointSize: MacMessageBox.talkSymbol, weight: .bold)
                                 : UIImage.SymbolConfiguration(pointSize: desk ? 13 : 17, weight: .semibold)
            if let image = UIImage(systemName: "waveform", withConfiguration: config) {
                let size = image.size
                symbol.frame = CGRect(x: ((s - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                                      width: size.width, height: size.height)
                symbolMask.frame = symbol.bounds
                symbolMask.contents = UIGraphicsImageRenderer(size: size).image { _ in image.draw(at: .zero) }.cgImage
                symbolMask.contentsScale = window?.screen.scale ?? traitCollection.displayScale
            }
        } else if kind == .stop {
            let side: CGFloat = desk ? 9 : 12
            glyph.path = UIBezierPath(roundedRect: CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side), cornerRadius: 2.5).cgPath
            glyph.lineWidth = 0
        } else if kind == .stopDictation {
            // A 20 pt tick (15 in the look), drawn like the arrow: a 24-unit path at stroke 2.6.
            let glyphSize: CGFloat = desk ? 15 : 20, scale = glyphSize / 24
            var t = CGAffineTransform(translationX: (s - glyphSize) / 2, y: (s - glyphSize) / 2).scaledBy(x: scale, y: scale)
            glyph.path = SVGPath.parse("M5 12.5 9.5 17 19 7").copy(using: &t)
            glyph.lineWidth = 2.6 * scale
        } else {
            // A 20 pt arrow (15 in the look): the 24-unit path at stroke 2.6, scaled to it.
            let glyphSize: CGFloat = desk ? 15 : 20, scale = glyphSize / 24
            var t = CGAffineTransform(translationX: (s - glyphSize) / 2, y: (s - glyphSize) / 2).scaledBy(x: scale, y: scale)
            glyph.path = SVGPath.parse("M12 20V5M5.5 11.5 12 5l6.5 6.5").copy(using: &t)
            glyph.lineWidth = 2.6 * scale
        }
        CATransaction.commit()
        applyColors()
    }

    private func applyColors() {
        let t = traitCollection
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if ComposerView.oneBox && !Theme.isDesktop {
            // [mac] The iOS look's box: the accent circle with a white glyph, as Messages on the Mac (no glass disc).
            let tint = ChatPalette.tint.resolvedColor(with: t), white = ChatPalette.onTint.resolvedColor(with: t).cgColor
            switch kind {
            case .disabled: circle.fillColor = tint.withAlphaComponent(0.35).cgColor
            case .stop, .stopDictation: circle.fillColor = ChatPalette.label.resolvedColor(with: t).cgColor
            default: circle.fillColor = tint.cgColor
            }
            let ground = kind == .stop || kind == .stopDictation ? ChatPalette.page.resolvedColor(with: t).cgColor : white
            glyph.fillColor = kind == .stop || kind == .talk ? ground : nil
            glyph.strokeColor = kind == .send || kind == .disabled || kind == .stopDictation ? ground : nil
            symbol.backgroundColor = ground
            CATransaction.commit()
            return
        }
        if Theme.boxComposer {
            let ink = ChatPalette.label.resolvedColor(with: t), ground = ChatPalette.page.resolvedColor(with: t).cgColor
            circle.fillColor = (kind == .disabled ? ink.withAlphaComponent(0.3) : ink).cgColor
            glyph.fillColor = kind == .stop || kind == .talk ? ground : nil
            glyph.strokeColor = kind == .send || kind == .disabled || kind == .stopDictation ? ground : nil
            symbol.backgroundColor = ground
            CATransaction.commit()
            return
        }
        circle.fillColor = nil
        disc.tint = discTint()
        switch kind {
        case .send:
            glyph.strokeColor = ChatPalette.onTint.cgColor
            glyph.fillColor = nil
        case .talk:
            glyph.fillColor = ChatPalette.onTint.cgColor
            glyph.strokeColor = nil
            symbol.backgroundColor = ChatPalette.onTint.cgColor
        case .stop:
            glyph.fillColor = ChatPalette.page.resolvedColor(with: t).cgColor
            glyph.strokeColor = nil
        case .stopDictation:
            glyph.strokeColor = ChatPalette.page.resolvedColor(with: t).cgColor
            glyph.fillColor = nil
        case .disabled:
            glyph.strokeColor = ChatPalette.label3.resolvedColor(with: t).cgColor
            glyph.fillColor = nil
        }
        CATransaction.commit()
    }

    /// The glass's tint in the iOS look: Send and Talk in the theme's colour, Stop in the text colour.
    private func discTint() -> UIColor? {
        switch kind {
        // At 70 % the glass shows through and the white glyph still reads (3.5:1 light, 4.5:1 dark; 50 % fell to 2.4).
        // Increase Contrast takes the full colour.
        case .send, .talk:
            ChatPalette.tint.resolvedColor(with: traitCollection)
                .withAlphaComponent(traitCollection.accessibilityContrast == .high ? 1 : 0.7)
        case .stop, .stopDictation: ChatPalette.label.resolvedColor(with: traitCollection)
        case .disabled: nil
        }
    }
}

/// [keyboard] Lets the message box's pull-down run beside the field's own scrolling and the buttons' touches, and
/// asks the box whether a drag is that pull (`ComposerView.pullMayBegin`).
final class ComposerPullGate: NSObject, UIGestureRecognizerDelegate {
    var begins: ((UIPanGestureRecognizer) -> Bool)?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer as? UIPanGestureRecognizer).flatMap { begins?($0) } ?? false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
