//
//  KaraokeLyricsView.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import SnapKit

class KaraokeLyricsView: NSView {
    
    private let backgroundView: NSView
    private let stackView: NSStackView
    
    @objc dynamic var isVertical = false {
        didSet {
            stackView.orientation = isVertical ? .horizontal : .vertical
            arrangeDisplayLines()
            updateFontSize()
        }
    }
    
    @objc dynamic var drawFurigana = false
    
    @objc dynamic var font = NSFont.labelFont(ofSize: 24) { didSet { updateFontSize() } }
    @objc dynamic var textColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
    @objc dynamic var shadowColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var progressColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var backgroundColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6018835616) {
        didSet {
            backgroundView.layer?.backgroundColor = backgroundColor.cgColor
        }
    }
    
    @objc dynamic var shouldHideWithMouse = true {
        didSet {
            updateTrackingAreas()
        }
    }
    
    var displayLine1: KaraokeLabel?
    var displayLine2: KaraokeLabel?
    
    override init(frame frameRect: NSRect) {
        stackView = NSStackView(frame: frameRect)
        stackView.orientation = .vertical
        stackView.autoresizingMask = [.width, .height]
        backgroundView = NSView() //NSVisualEffectView(frame: frameRect)
//        backgroundView.material = .dark
//        backgroundView.state = .active
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        backgroundView.addSubview(stackView)
        backgroundView.layer?.cornerRadius = 12
        updateFontSize()
    }
    
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateFontSize() {
        var insetX = font.pointSize
        var insetY = insetX / 3
        if isVertical {
            (insetX, insetY) = (insetY, insetX)
        }
        stackView.snp.remakeConstraints {
            $0.edges.equalToSuperview().inset(NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX))
        }
        stackView.spacing = font.pointSize / 3
        backgroundView.layer?.cornerRadius = font.pointSize / 2
//        cornerRadius = font.pointSize / 2
    }
    
    private func makeLyricsLabel(_ content: String) -> KaraokeLabel {
        KaraokeLabel(labelWithString: content).then {
            $0.bind(\.font, to: self, withKeyPath: \.font)
            $0.bind(\.textColor, to: self, withKeyPath: \.textColor)
            $0.bind(\.progressColor, to: self, withKeyPath: \.progressColor)
            $0.bind(\._shadowColor, to: self, withKeyPath: \.shadowColor)
            $0.bind(\.isVertical, to: self, withKeyPath: \.isVertical)
            $0.bind(\.drawFurigana, to: self, withKeyPath: \.drawFurigana)
            $0.alphaValue = 0
        }
    }

    private func takeLabel(
        for content: String,
        from reusableLabels: inout [KaraokeLabel]
    ) -> KaraokeLabel {
        if let index = reusableLabels.firstIndex(where: { $0.stringValue == content }) {
            return reusableLabels.remove(at: index)
        }
        return makeLyricsLabel(content)
    }

    private func arrangeDisplayLines() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let state = TwoLineLyricsDisplayState(
            currentLine: displayLine1?.stringValue ?? "",
            nextLine: displayLine2?.stringValue ?? ""
        )
        for slot in state.arrangedSlots(isVertical: isVertical) {
            let label = slot == .current ? displayLine1 : displayLine2
            if let label {
                stackView.addArrangedSubview(label)
            }
        }
    }
    
    func displayLrc(_ firstLine: String, secondLine: String = "") {
        let state = TwoLineLyricsDisplayState(
            currentLine: firstLine,
            nextLine: secondLine
        )
        var reusableLabels = [displayLine1, displayLine2].compactMap { $0 }
        let currentLabel = state.currentLine.map {
            takeLabel(for: $0, from: &reusableLabels)
        }
        let nextLabel = state.nextLine.map {
            takeLabel(for: $0, from: &reusableLabels)
        }

        displayLine1 = currentLabel
        displayLine2 = nextLabel

        reusableLabels.forEach {
            $0.isHidden = true
            $0.alphaValue = 0
            $0.removeProgressAnimation()
        }
        [currentLabel, nextLabel].compactMap { $0 }.forEach {
            $0.removeProgressAnimation()
        }

        // Geometry must settle in one pass. Animating stack bounds can leave a
        // vertical Core Text frame temporarily showing only the line's suffix.
        arrangeDisplayLines()
        [currentLabel, nextLabel].compactMap { $0 }.forEach {
            $0.isHidden = false
            $0.alphaValue = 1
        }
        isHidden = state.currentLine == nil
        layoutSubtreeIfNeeded()
        mouseTest()
    }
    
    // MARK: - Event
    
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map(removeTrackingArea)
        if shouldHideWithMouse {
            let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .assumeInside, .enabledDuringMouseDrag]
            trackingArea = NSTrackingArea(rect: bounds, options: trackingOptions, owner: self)
            trackingArea.map(addTrackingArea)
        }
        mouseTest()
    }
    
    private func mouseTest() {
        if shouldHideWithMouse,
            let point = NSEvent.mouseLocation(in: self),
            bounds.contains(point) {
            animator().alphaValue = 0
        } else {
            animator().alphaValue = 1
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = 0
    }
    
    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 1
    }
    
}

extension NSEvent {
    
    class func mouseLocation(in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let windowLocation = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return view.convert(windowLocation, from: nil)
    }
}

extension NSTextField {
    
    // swiftlint:disable:next identifier_name
    @objc dynamic var _shadowColor: NSColor? {
        get {
            return shadow?.shadowColor
        }
        set {
            shadow = newValue.map { color in
                NSShadow().then {
                    $0.shadowBlurRadius = 3
                    $0.shadowColor = color
                    $0.shadowOffset = .zero
                }
            }
        }
    }
}
