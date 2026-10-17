//
//  PanModalPresentationAnimator.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

#if os(iOS)
import UIKit

/**
 Handles the animation of the presentedViewController as it is presented or dismissed.

 This is a vertical animation that
 - Animates up from the bottom of the screen
 - Dismisses from the top to the bottom of the screen

 This can be used as a standalone object for transition animation,
 but is primarily used in the PanModalPresentationDelegate for handling pan modal transitions.

 - Note: The presentedViewController can conform to PanModalPresentable to adjust
 it's starting position through manipulating the shortFormHeight
 */

public class PanModalPresentationAnimator: NSObject {

    /**
     Enum representing the possible transition styles
     */
    public enum TransitionStyle {
        case presentation
        case dismissal
    }

    // MARK: - Properties

    /**
     The transition style
     */
    private let transitionStyle: TransitionStyle

    /**
     Haptic feedback generator (during presentation)
     */
    private var feedbackGenerator: UISelectionFeedbackGenerator?

    // MARK: - Initializers

    required public init(transitionStyle: TransitionStyle) {
        self.transitionStyle = transitionStyle
        super.init()

        /**
         Prepare haptic feedback, only during the presentation state
         */
        if case .presentation = transitionStyle {
            feedbackGenerator = UISelectionFeedbackGenerator()
            feedbackGenerator?.prepare()
        }
    }

    /**
     Animate presented view controller presentation
     */
    private func animatePresentation(transitionContext: UIViewControllerContextTransitioning) {

        guard let toVC = transitionContext.viewController(forKey: .to) else { return }

        let presentable = panModalLayoutType(from: transitionContext)

        // Presents the view in shortForm position, initially
        let yPos: CGFloat = presentable?.shortFormYPos ?? 0.0

        // Use panView as presentingView if it already exists within the containerView
        let panView: UIView = transitionContext.containerView.panContainerView ?? toVC.view

        // Move presented view offscreen (from the bottom)
        let startY = transitionContext.containerView.bounds.height
        panView.frame = transitionContext.finalFrame(for: toVC)
        panView.frame.origin.y = startY

        // Haptic feedback
        if presentable?.isHapticFeedbackEnabled == true {
            feedbackGenerator?.selectionChanged()
        }
     
        // To make it interactable quicker
        transitionContext.completeTransition(true)

        let completion: (Bool) -> Void = { [weak self] _ in
            self?.feedbackGenerator = nil
        }
        if let controller = toVC.presentationController as? PanModalPresentationController {
            controller.animatePresentation(from: startY, completion: completion)
        } else {
            PanModalAnimator.animate({ panView.frame.origin.y = yPos }, config: presentable, completion)
        }
    }

    /**
     Animate presented view controller dismissal
     */
    private func animateDismissal(transitionContext: UIViewControllerContextTransitioning) {

        guard
            let toVC = transitionContext.viewController(forKey: .to),
            let fromVC = transitionContext.viewController(forKey: .from)
            else { return }

        let presentable = panModalLayoutType(from: transitionContext)
        let panView: UIView = transitionContext.containerView.panContainerView ?? fromVC.view

        let completion: (Bool) -> Void = { didComplete in
            if didComplete {
                fromVC.view.removeFromSuperview()
            }
            if didComplete {
                transitionContext.finishInteractiveTransition()
            } else {
                transitionContext.cancelInteractiveTransition()
            }
            transitionContext.completeTransition(didComplete)
        }
        if let controller = fromVC.presentationController as? PanModalPresentationController {
            controller.animateDismissal(to: toVC, completion: completion)
        } else {
            PanModalAnimator.animate({
                panView.frame.origin.y = transitionContext.containerView.bounds.height
            }, config: presentable, completion)
        }
    }

    /**
     Extracts the PanModal from the transition context, if it exists
     */
    private func panModalLayoutType(from context: UIViewControllerContextTransitioning) -> PanModalPresentable.LayoutType? {
        switch transitionStyle {
        case .presentation:
            return context.viewController(forKey: .to) as? PanModalPresentable.LayoutType
        case .dismissal:
            return context.viewController(forKey: .from) as? PanModalPresentable.LayoutType
        }
    }

}

// MARK: - UIViewControllerInteractiveTransitioning

extension PanModalPresentationAnimator: UIViewControllerInteractiveTransitioning {

    public func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        // Keep UIKit input delivery and cancellation available while the native spring runs.
        animateTransition(using: transitionContext)
    }

}

// MARK: - UIViewControllerAnimatedTransitioning Delegate

extension PanModalPresentationAnimator: UIViewControllerAnimatedTransitioning {

    /**
     Returns the transition duration
     */
    public func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {

        guard
            let context = transitionContext,
            let presentable = panModalLayoutType(from: context)
            else { return PanModalAnimator.Constants.defaultTransitionDuration }

        return presentable.transitionDuration
    }

    /**
     Performs the appropriate animation based on the transition style
     */
    public func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        switch transitionStyle {
        case .presentation:
            animatePresentation(transitionContext: transitionContext)
        case .dismissal:
            animateDismissal(transitionContext: transitionContext)
        }
    }

}
#endif
