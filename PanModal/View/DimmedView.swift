//
//  DimmedView.swift
//  PanModal
//
//  Copyright © 2017 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 A dim view for use as an overlay over content you want dimmed.
 */
public class DimmedView: UIView, UIGestureRecognizerDelegate {

    // MARK: - Properties

    /// The surviving presentation receives background touches during an exit.
    weak var passthroughView: UIView?

    /**
     The closure to be executed when a tap occurs
     */
    var didTap: ((_ recognizer: UIGestureRecognizer) -> Void)?
    var shouldReceiveTap: ((UITouch) -> Bool)?

    /**
     Tap gesture recognizer
     */
    private lazy var tapGesture: UIGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(didTapView))
        recognizer.delegate = self
        return recognizer
    }()

    // MARK: - Initializers

    init(dimColor: UIColor = UIColor.black.withAlphaComponent(0.7)) {
        super.init(frame: .zero)
        layer.opacity = 0.0
        backgroundColor = dimColor
        addGestureRecognizer(tapGesture)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError()
    }

    // MARK: - Event Handlers

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = passthroughView else {
            guard !isHidden, isUserInteractionEnabled, self.point(inside: point, with: event) else { return nil }
            // Keep the active scrim tappable when it is transparent
            return super.hitTest(point, with: event) ?? self
        }
        guard bounds.contains(point), let window = window, target.window === window else { return nil }
        return target.hitTest(convert(point, to: target), with: event)
    }

    @objc private func didTapView() {
        didTap?(tapGesture)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return shouldReceiveTap?(touch) ?? true
    }

}
#endif
