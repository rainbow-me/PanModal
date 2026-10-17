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
public class DimmedView: UIView {

    // MARK: - Properties

    /// The surviving presentation receives background touches during an exit.
    weak var passthroughView: UIView?

    /**
     The closure to be executed when a tap occurs
     */
    var didTap: ((_ recognizer: UIGestureRecognizer) -> Void)?

    /**
     Tap gesture recognizer
     */
    private lazy var tapGesture: UIGestureRecognizer = {
        return UITapGestureRecognizer(target: self, action: #selector(didTapView))
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
        guard let target = passthroughView else { return super.hitTest(point, with: event) }
        guard bounds.contains(point), let window = window, target.window === window else { return nil }
        return target.hitTest(convert(point, to: target), with: event)
    }

    @objc private func didTapView() {
        didTap?(tapGesture)
    }

}
#endif
