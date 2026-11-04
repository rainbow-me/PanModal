//
//  PanModalPresentable+UIViewController.swift
//  PanModal
//
//  Copyright © 2018 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Extends PanModalPresentable with helper methods
 when the conforming object is a UIViewController
 */
public extension PanModalPresentable where Self: UIViewController {

    typealias AnimationBlockType = () -> Void
    typealias AnimationCompletionType = (Bool) -> Void

    /**
     For Presentation, the object must be a UIViewController & confrom to the PanModalPresentable protocol.
     */
    typealias LayoutType = UIViewController & PanModalPresentable

    /**
     A function wrapper over the `transition(to state: PanModalPresentationController.PresentationState)`
     function in the PanModalPresentationController.
     */
    func panModalTransition(to state: PanModalPresentationController.PresentationState) {
        presentedVC?.transition(to: state)
    }

    /// Dismisses the presented PanModal. Completion also runs if a grab cancels dismissal.
    /// Completes immediately when this controller is not presented as a PanModal.
    func panModalDismiss(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard presentingViewController != nil, let controller = presentedVC else {
            completion?()
            return
        }
        controller.dismiss(animated: animated, completion: completion)
    }

    /**
     Refreshes layout after PanModalPresentable values change, preserving an active drag.
     At rest, the current form follows changed heights.
     The optional form is chosen synchronously after layout.
     */
    func panModalSetNeedsLayoutUpdate(transitionTo state: () -> PanModalPresentationController.PresentationState? = { nil }) {
        presentedVC?.setNeedsLayoutUpdate(transitionTo: state)
    }

    /**
     Operations on the scroll view, such as content height changes, or when inserting/deleting rows can cause the pan modal to jump,
     caused by the pan modal responding to content offset changes.

     To avoid this, you can call this method to perform scroll view updates, with scroll observation temporarily disabled.
     */
    func panModalPerformUpdates(_ updates: () -> Void) {
        presentedVC?.performUpdates(updates)
    }

    /**
     A function wrapper over the animate function in PanModalAnimator.

     This can be used for animation consistency on views within the presented view controller.
     */
    func panModalAnimate(_ animationBlock: @escaping AnimationBlockType, _ completion: AnimationCompletionType? = nil) {
        PanModalAnimator.animate(animationBlock, config: self, completion)
    }

}
#endif
