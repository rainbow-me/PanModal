//
//  PanModalPresentationController.swift
//  PanModal
//
//  Copyright © 2019 Tiny Speck, Inc. All rights reserved.
//

import UIKit


public class UIPanGestureRecognizerWithInitialPosition: UIPanGestureRecognizer {
  public var initialTouchLocation: CGPoint!
  
  public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    initialTouchLocation = touches.first!.location(in: view)
  }
}


/**
 The PanModalPresentationController is the middle layer between the presentingViewController
 and the presentedViewController.

 It controls the coordination between the individual transition classes as well as
 provides an abstraction over how the presented view is presented & displayed.

 A background overlay sits between the presenting and presented views.

 The presented view's layout configuration & presentation is defined using the PanModalPresentable.

 By conforming to the PanModalPresentable protocol & overriding values
 the presented view can define its layout configuration & presentation.
 */
open class PanModalPresentationController: UIPresentationController {

    /**
     Enum representing the possible presentation states
     */
    public enum PresentationState {
        case shortForm
        case longForm
        case hidden
    }

    /**
     Constants
     */
    struct Constants {
        static let snapMovementSensitivity = CGFloat(0.7)
    }

    // MARK: - Properties

    private struct Animation {
        let destination: PresentationState
        let animator: UIViewPropertyAnimator
        let completion: ((Bool) -> Void)?
    }

    private var animation: Animation?
    private var panMinimumY: CGFloat?
    private var endPanFrameRateRequest: (() -> Void)?
    private var isPresentedViewAnimating: Bool { animation != nil }

    // An accepted dismissal outlives its spring and may precede UIKit's transition.
    private final class Dismissal {
        enum Origin { case panModal, uiKit }
        let origin: Origin
        var returnState: PresentationState
        var requested = true
        var velocity: CGFloat
        var animated: Bool
        var completions: [() -> Void] = []
        // Keep teardown cancelable after the spring ends while a child still exits.
        var contextCompletion: ((Bool) -> Void)?

        init(returnState: PresentationState, velocity: CGFloat, animated: Bool = true, origin: Origin = .uiKit) {
            self.origin = origin
            self.returnState = returnState
            self.velocity = velocity
            self.animated = animated
        }
    }

    private var dismissal: Dismissal?
    // The form to preserve if UIKit dismissal is canceled, including retained hiding.
    private var presentationState: PresentationState = .shortForm

    private var hiddenYPosition: CGFloat {
        return containerView?.bounds.height ?? presentedView.frame.maxY
    }

    /**
     A flag to determine if scrolling should seamlessly transition
     from the pan modal container view to the scroll view
     once the scroll limit has been reached.
     */
    private var extendsPanScrolling: Bool {
        return scrollView != nil && (presentable?.allowsExtendedPanScrolling ?? false)
    }

    /**
     The scroll view bound to the current interaction. Its observer and saved
     offset are replaced together at touch admission or an explicit layout update.
     */
    private weak var scrollView: UIScrollView?

    /**
     A flag to determine if scrolling should be limited to the longFormHeight.
     Return false to cap scrolling at .max height.
     */
    private var anchorModalToLongForm = true

    /**
     The y content offset value of the embedded scroll view
     */
    private var scrollViewYOffset: CGFloat = 0.0

    /**
     An observer for the scroll view content offset
     */
    private var scrollObserver: NSKeyValueObservation?

    // store the y positions so we don't have to keep re-calculating

    /**
     The y value for the short form presentation state
     */
    private var shortFormYPosition: CGFloat = 0
  private var bottomYPos: CGFloat = 0

    /**
     The y value for the long form presentation state
     */
    private var longFormYPosition: CGFloat = 0

    /**
     Determine anchored Y postion based on the `anchorModalToLongForm` flag
     */
    private var anchoredYPosition: CGFloat {
        let defaultTopOffset = presentable?.topOffset ?? 0
        return anchorModalToLongForm ? longFormYPosition : defaultTopOffset
    }

    /**
     Configuration object for PanModalPresentationController
     */
    private var presentable: PanModalPresentable? {
        return presentedViewController as? PanModalPresentable
    }
  
    @objc dynamic public var yPosition: CGFloat = 0.0

    // MARK: - Views

    /**
     Background view used as an overlay over the presenting view
     */
    private lazy var backgroundView: DimmedView = {
        let view: DimmedView
        if let color = presentable?.panModalBackgroundColor {
            view = DimmedView(dimColor: color)
        } else {
            view = DimmedView()
        }
        view.didTap = { [weak self] _ in
            if self?.presentable?.allowsTapToDismiss == true {
                self?.dismiss()
            }
        }
        return view
    }()

    /**
     A wrapper around the presented view so that we can modify
     the presented view apperance without changing
     the presented view's properties
     */
    var panContainerViewMemoized: PanContainerView? = nil
    private var panContainerView: PanContainerView {
      get {
        if panContainerViewMemoized != nil {
          return panContainerViewMemoized!
        }
        let frame = containerView?.frame ?? .zero
        let container = PanContainerView(presentedView: presentedViewController.view, frame: frame)
        if frame.height != 0 {
          panContainerViewMemoized = container
        }
        return container
      }
    }
  
    /**
     Override presented view to return the pan container wrapper
     */
    public override var presentedView: UIView {
        return panContainerView
    }

    // MARK: - Gesture Recognizers

    /**
     Gesture recognizer to detect & track pan gestures
     */
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizerWithInitialPosition(target: self, action: #selector(didPanOnPresentedView(_ :)))
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        return gesture
    }()

    // MARK: - Deinitializers

    deinit {
        setPanFrameRateActive(false)
        scrollObserver?.invalidate()
    }

    // MARK: - Lifecycle

    override public func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        if let containerView = containerView, presentedView.bounds.size != containerView.bounds.size {
            setNeedsLayoutUpdate()
        } else {
            configureViewLayout()
        }
    }

    override public func presentationTransitionWillBegin() {

        guard let containerView = containerView
            else { return }

        layoutBackgroundView(in: containerView)
        layoutPresentedView(in: containerView)
        configureScrollViewInsets()

        guard let coordinator = presentedViewController.transitionCoordinator else {
            backgroundView.layer.opacity = 1
            return
        }

        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.presentedViewController.setNeedsStatusBarAppearanceUpdate()
        })
    }

    override public func dismissalTransitionWillBegin() {
        if dismissal == nil {
            let operation = Dismissal(returnState: presentationState, velocity: 0)
            dismissal = operation
            if operation.requested { presentable?.panModalWillDismiss() }
        }
        if dismissal?.requested == true { setPanFrameRateActive(false) }
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { [weak self] _ in
            self?.presentingViewController.setNeedsStatusBarAppearanceUpdate()
        })
    }

    override public func presentationTransitionDidEnd(_ completed: Bool) {
        if completed { return }

        backgroundView.removeFromSuperview()
    }
 
    override public func dismissalTransitionDidEnd(_ completed: Bool) {
        if let operation = dismissal, operation.origin == .uiKit {
            if let coordinator = presentedViewController.transitionCoordinator,
               !coordinator.isAnimated,
               coordinator.viewController(forKey: .from) === presentedViewController {
                coordinator.animate(alongsideTransition: nil) { [self] _ in completeDismissal(operation) }
            }
        }
        guard completed else {
            backgroundView.passthroughView = nil
            return
        }
        captureAnimation()?.completion?(false)
        scrollObserver?.invalidate()
        scrollObserver = nil
        scrollView = nil
        presentable?.panModalDidDismiss()
    }

    /**
     Update presented view size in response to size class changes
     */
    override public func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self = self else { return }
            self.setNeedsLayoutUpdate()
        })
    }

}

// MARK: - Public Methods

public extension PanModalPresentationController {

    /**
     Transition the PanModalPresentationController
     to the given presentation state
     */
    func transition(to state: PresentationState) {
        transition(to: state, velocity: 0)
    }

    /// Dismisses the sheet. Completion follows UIKit transition settlement,
    /// including cancellation when the user grabs the exiting sheet.
    func dismiss(animated: Bool = true, completion: (() -> Void)? = nil) {
        dismiss(animated: animated, velocity: 0, completion: completion)
    }

    /**
     Operations on the scroll view, such as content height changes,
     or when inserting/deleting rows can cause the pan modal to jump,
     caused by the pan modal responding to content offset changes.

     To avoid this, you can call this method to perform scroll view updates,
     with scroll observation temporarily disabled.
     */
    func performUpdates(_ updates: () -> Void) {

        // Pause scroll observer
        scrollObserver?.invalidate()
        scrollObserver = nil

        // Perform updates
        updates()

        // Updates may replace the selected view. Resume through the binding owner.
        scrollObserver?.invalidate()
        scrollObserver = nil
        updateScrollView()
    }

    /**
     Updates the PanModalPresentationController layout
     based on values in the PanModalPresentable

     - Note: This should be called whenever any
     pan modal presentable value changes after the initial presentation
     */
    func setNeedsLayoutUpdate() {
        let activeAnimation = captureAnimation()
        scrollObserver?.invalidate()
        scrollObserver = nil
        configureViewLayout()
        adjustPresentedViewFrame()
        configureCorners()
        updateScrollView()
        if let activeAnimation = activeAnimation {
            animate(to: activeAnimation.destination, completion: activeAnimation.completion)
        }
    }

}

// MARK: - Presented View Layout Configuration

private extension PanModalPresentationController {

    /**
     Boolean flag to determine if the presented view is anchored
     */
    var isPresentedViewAnchored: Bool {
        guard extendsPanScrolling else { return false }
        let y = isPresentedViewAnimating
            ? presentedView.layer.presentation()?.frame.minY ?? presentedView.frame.minY
            : presentedView.frame.minY
        return y.rounded() <= anchoredYPosition.rounded()
    }

    /**
     Adds the presented view to the given container view
     & configures the view elements such as rounded corners
     based on the pan modal presentable.
     */
    func layoutPresentedView(in containerView: UIView) {

        /**
         If the presented view controller does not conform to pan modal presentable
         don't configure
         */
        guard presentable != nil else { return }

        /**
         ⚠️ If this class is NOT used in conjunction with the PanModalPresentationAnimator
         & PanModalPresentable, the presented view should be added to the container view
         in the presentation animator instead of here
         */
        containerView.addSubview(presentedView)
        containerView.addGestureRecognizer(panGestureRecognizer)

        configureCorners()

        setNeedsLayoutUpdate()
        adjustPanContainerBackgroundColor()
    }

    /**
     Reduce height of presentedView so that it sits at the bottom of the screen
     */
    func adjustPresentedViewFrame() {

        guard let frame = containerView?.frame
            else { return }

        let adjustedSize = CGSize(width: frame.size.width, height: frame.size.height - anchoredYPosition)
        let panFrame = panContainerView.frame
        panContainerView.frame.size = frame.size
        
        if ![shortFormYPosition, longFormYPosition].contains(panFrame.origin.y) {
            // if the container is already in the correct position, no need to adjust positioning
            // (rotations & size changes cause positioning to be out of sync)
            let yPosition = panFrame.origin.y - panFrame.height + frame.height
            presentedView.frame.origin.y = max(yPosition, anchoredYPosition)
            self.yPosition = presentedView.frame.origin.y
        }
        panContainerView.frame.origin.x = frame.origin.x
        presentedViewController.view.frame = CGRect(origin: .zero, size: adjustedSize)
    }

    /**
     Adds a background color to the pan container view
     in order to avoid a gap at the bottom
     during initial view presentation in longForm (when view bounces)
     */
    func adjustPanContainerBackgroundColor() {
        panContainerView.backgroundColor = presentedViewController.view.backgroundColor
            ?? scrollView?.backgroundColor
    }

    /**
     Adds the background view to the view hierarchy
     & configures its layout constraints.
     */
    func layoutBackgroundView(in containerView: UIView) {
        containerView.addSubview(backgroundView)
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.topAnchor.constraint(equalTo: containerView.topAnchor).isActive = true
        backgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor).isActive = true
        backgroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor).isActive = true
        backgroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor).isActive = true
    }

    /**
     Calculates & stores the layout anchor points & options
     */
    func configureViewLayout() {

        guard let layoutPresentable = presentedViewController as? PanModalPresentable.LayoutType
            else { return }

        shortFormYPosition = layoutPresentable.shortFormYPos
        bottomYPos = layoutPresentable.bottomYPos
        longFormYPosition = layoutPresentable.longFormYPos
        anchorModalToLongForm = layoutPresentable.anchorModalToLongForm

        containerView?.isUserInteractionEnabled = layoutPresentable.isUserInteractionEnabled
    }

    /**
     Configures the scroll view insets
     */
    func configureScrollViewInsets() {

        guard let scrollView = scrollView
            else { return }

        /**
         Disable vertical scroll indicator until we start to scroll
         to avoid visual bugs
         */
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollIndicatorInsets = presentable?.scrollIndicatorInsets ?? .zero

        /**
         Set the appropriate contentInset as the configuration within this class
         offsets it
         */
      
      scrollView.contentInset.bottom = (presentable?.ignoreBottomOffset ?? false) ? 0 : presentingViewController.bottomLayoutGuide.length

        /**
         As we adjust the bounds during `handleScrollViewTopBounce`
         we should assume that contentInsetAdjustmentBehavior will not be correct
         */
        scrollView.contentInsetAdjustmentBehavior = .never
    }

}

// MARK: - Pan Gesture Event Handler

private extension PanModalPresentationController {

    /**
     The designated function for handling pan gesture events
     */
    @objc func didPanOnPresentedView(_ recognizer: UIPanGestureRecognizer) {
        defer {
            if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
                setPanFrameRateActive(false)
                panMinimumY = nil
            }
        }

        guard
            shouldRespond(to: recognizer),
            let containerView = containerView
            else {
                setPanFrameRateActive(false)
                recognizer.setTranslation(.zero, in: recognizer.view)
                return
        }

        switch recognizer.state {
        case .began, .changed:
            setPanFrameRateActive(true)
            let wasDismissing = dismissal?.requested ?? presentedViewController.isBeingDismissed
            if wasDismissing || recognizer.state == .began { cancelDismissal() }
            if let interrupted = captureAnimation() {
                interrupted.completion?(false)
                recognizer.setTranslation(.zero, in: containerView)
                panMinimumY = min(anchoredYPosition, presentedView.frame.minY)
            }
            if wasDismissing {
                recognizer.setTranslation(.zero, in: containerView)
                panMinimumY = min(anchoredYPosition, presentedView.frame.minY)
            }
            if panMinimumY == nil { panMinimumY = min(anchoredYPosition, presentedView.frame.minY) }
            backgroundView.passthroughView = nil

            /**
             Respond accordingly to pan gesture translation
             */
            presentable?.willRespond(to: recognizer)
            applyTranslation(of: recognizer)

            /**
             If presentedView is translated above the longForm threshold, treat as transition
             */
            if presentedView.frame.origin.y == anchoredYPosition && extendsPanScrolling {
                presentationState = .longForm
                presentable?.willTransition(to: .longForm)
            }

        case .ended:
            if let interrupted = captureAnimation() {
                interrupted.completion?(false)
                recognizer.setTranslation(.zero, in: containerView)
                panMinimumY = min(anchoredYPosition, presentedView.frame.minY)
            }
            applyTranslation(of: recognizer)

            /**
             Use velocity sensitivity value to restrict snapping
             */
            let velocity = releaseVelocity(for: recognizer)

            if isVelocityWithinSensitivityRange(velocity) {

                /**
                 If velocity is within the sensitivity range,
                 transition to a presentation state or dismiss entirely.

                 This allows the user to dismiss directly from long form
                 instead of going to the short form state first.
                 */
                if velocity < 0 {
                    transition(to: presentable?.longFormEnabled ?? true ? .longForm : .shortForm, velocity: velocity)

                } else if (nearest(to: presentedView.frame.minY, inValues: [longFormYPosition, containerView.bounds.height]) == longFormYPosition
                    && presentedView.frame.minY < shortFormYPosition) || presentable?.allowsDragToDismiss == false {
                    transition(to: .shortForm, velocity: velocity)

                } else {
                    dismiss(velocity: velocity)
                }

            } else {

                /**
                 The `containerView.bounds.height` is used to determine
                 how close the presented view is to the bottom of the screen
                 */
                let position = nearest(to: presentedView.frame.minY, inValues: [containerView.bounds.height, shortFormYPosition, longFormYPosition])

                if position == longFormYPosition {
                  transition(to: presentable?.longFormEnabled ?? true ? .longForm : .shortForm, velocity: velocity)

                } else if position == shortFormYPosition || presentable?.allowsDragToDismiss == false {
                    transition(to: .shortForm, velocity: velocity)

                } else {
                    dismiss(velocity: velocity)
                }
            }
        case .cancelled, .failed:
            captureAnimation()?.completion?(false)
            let target = nearest(to: presentedView.frame.minY, inValues: [shortFormYPosition, longFormYPosition])
            transition(to: target == longFormYPosition && presentable?.longFormEnabled != false ? .longForm : .shortForm, velocity: 0)
        default:
            break
        }
    }

    /**
     Determine if the pan modal should respond to the gesture recognizer.

     If the pan modal is already being dragged & the delegate returns false, ignore until
     the recognizer is back to it's original state (.began)

     ⚠️ This is the only time we should be cancelling the pan modal gesture recognizer
     */
    func shouldRespond(to panGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        let permitted = presentable?.shouldRespond(to: panGestureRecognizer) == true
        guard dismissal == nil || permitted else { return false }
        guard !presentedViewController.isBeingDismissed ||
                (presentedViewController.transitionCoordinator?.isInteractive == true && permitted) else { return false }
        guard
            permitted || !(panGestureRecognizer.state == .began || panGestureRecognizer.state == .cancelled)
            else {
                panGestureRecognizer.isEnabled = false
                panGestureRecognizer.isEnabled = true
                return false
        }
        return !shouldFail(panGestureRecognizer: panGestureRecognizer)
    }

    /**
     Communicate intentions to presentable and adjust subviews in containerView
     */
    func applyTranslation(of panGestureRecognizer: UIPanGestureRecognizer) {
        let y = presentedView.frame.minY
        let translation = panGestureRecognizer.translation(in: containerView).y
        // Invert resistance before applying input so crossing long form does not
        // depend on how UIKit partitions movement into callbacks.
        let unresistedY = y < longFormYPosition ? longFormYPosition + 2 * (y - longFormYPosition) : y
        let proposedY = unresistedY + translation
        let nextY = proposedY < longFormYPosition ? longFormYPosition + (proposedY - longFormYPosition) / 2 : proposedY
        adjust(toYPosition: max(nextY, panMinimumY ?? anchoredYPosition))

        panGestureRecognizer.setTranslation(.zero, in: presentedView)
    }

    /**
     Determines if we should fail the gesture recognizer based on certain conditions

     We fail the presented view's pan gesture recognizer if we are actively scrolling on the scroll view.
     This allows the user to drag whole view controller from outside scrollView touch area.

     Unfortunately, cancelling a gestureRecognizer means that we lose the effect of transition scrolling
     from one view to another in the same pan gesture so don't cancel
     */
    func shouldFail(panGestureRecognizer: UIPanGestureRecognizer) -> Bool {

        /**
         Allow api consumers to override the internal conditions &
         decide if the pan gesture recognizer should be prioritized.

         ⚠️ This is the only time we should be cancelling the panScrollable recognizer,
         for the purpose of ensuring we're no longer tracking the scrollView
         */
        guard !shouldPrioritize(panGestureRecognizer: panGestureRecognizer) else {
            if let scrollView = scrollView, scrollView.isScrollEnabled,
               scrollView.panGestureRecognizer.isEnabled {
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
            }
            return false
        }

        guard
            isPresentedViewAnchored,
            let scrollView = scrollView,
            scrollView.contentOffset.y > -scrollView.adjustedContentInset.top
            else {
                return false
        }

        let loc = panGestureRecognizer.location(in: scrollView)
        return ((scrollView.bounds.contains(loc) && !(presentable?.shouldPrioritize(panModalGestureRecognizer: panGestureRecognizer) ?? false)) || scrollView.isScrolling)
    }

    /**
     Determine if the presented view's panGestureRecognizer should be prioritized over
     embedded scrollView's panGestureRecognizer.
     */
    func shouldPrioritize(panGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        return panGestureRecognizer.state == .began &&
            presentable?.shouldPrioritize(panModalGestureRecognizer: panGestureRecognizer) == true
    }

    /**
     Check if the given velocity is within the sensitivity range
     */
    func isVelocityWithinSensitivityRange(_ velocity: CGFloat) -> Bool {
        return (abs(velocity) - (1000 * (1 - Constants.snapMovementSensitivity))) > 0
    }

    func transition(to state: PresentationState, velocity: CGFloat) {
        guard presentable?.shouldTransition(to: state) == true else { return }
        if presentedViewController.isBeingDismissed {
            guard state != .hidden, presentedViewController.transitionCoordinator?.isInteractive == true else { return }
        }
        if state != .hidden { cancelDismissal() }
        presentationState = state
        presentable?.willTransition(to: state)
        if state == .hidden { backgroundView.passthroughView = interactionView(for: presentingViewController) }
        animate(to: state, velocity: velocity)
    }

    func position(for state: PresentationState) -> CGFloat {
        switch state {
        case .shortForm: return shortFormYPosition
        case .longForm: return longFormYPosition
        case .hidden: return hiddenYPosition
        }
    }

    func releaseVelocity(for recognizer: UIPanGestureRecognizer) -> CGFloat {
        let velocity = recognizer.velocity(in: containerView).y
        let y = presentedView.frame.minY
        if y <= anchoredYPosition && velocity < 0 { return 0 }
        return y < longFormYPosition || (y == longFormYPosition && velocity < 0) ? velocity / 2 : velocity
    }

    func dismiss(animated: Bool = true, velocity: CGFloat, completion: (() -> Void)? = nil) {
        guard let presenter = presentedViewController.presentingViewController else {
            if let operation = dismissal { completeDismissal(operation) }
            completion?()
            return
        }
        if let operation = dismissal {
            if let completion = completion { operation.completions.append(completion) }
            if !operation.requested {
                operation.requested = true
                operation.velocity = velocity
                operation.animated = animated
                operation.returnState = presentationState
                startDismissalAnimation(operation, to: presenter)
                presentable?.panModalWillDismiss()
            }
            return
        }
        let operation = Dismissal(returnState: presentationState, velocity: velocity, animated: animated, origin: .panModal)
        if let completion = completion { operation.completions.append(completion) }
        dismissal = operation
        startDismissalAnimation(operation, to: presenter)
        presentable?.panModalWillDismiss()
        submitDismissal(operation)
    }

    private func submitDismissal(_ operation: Dismissal) {
        guard dismissal === operation else { return }
        guard operation.requested,
              let presenter = presentedViewController.presentingViewController else {
            completeDismissal(operation)
            return
        }
        var descendant = presentedViewController.presentedViewController
        while let controller = descendant {
            descendant = controller.presentedViewController
            guard let owner = controller.presentationController as? PanModalPresentationController else { continue }
            if owner.dismissal == nil, controller.isBeingDismissed {
                owner.dismissal = Dismissal(returnState: owner.presentationState, velocity: 0)
                owner.presentable?.panModalWillDismiss()
            }
            guard let childOperation = owner.dismissal else { continue }
            childOperation.completions.append { [self] in submitDismissal(operation) }
            return
        }
        presenter.dismiss(animated: operation.animated) { [self] in completeDismissal(operation) }
    }

    private func completeDismissal(_ operation: Dismissal) {
        guard dismissal === operation else { return }
        dismissal = nil
        let completions = operation.completions
        operation.completions.removeAll()
        completions.forEach { $0() }
    }

    private func cancelDismissal() {
        if dismissal == nil, presentedViewController.isBeingDismissed,
           presentedViewController.transitionCoordinator?.isInteractive == true {
            let operation = Dismissal(returnState: presentationState, velocity: 0)
            dismissal = operation
        }
        let interrupted: Animation?
        if let operation = dismissal, operation.requested {
            operation.requested = false
            interrupted = captureAnimation()
        } else {
            interrupted = nil
        }
        var ancestor: UIViewController? = presentedViewController.presentingViewController
        while let controller = ancestor {
            ancestor = controller.presentingViewController
            guard let owner = controller.presentationController as? PanModalPresentationController else { continue }
            guard owner.dismissal?.requested ?? controller.isBeingDismissed else { continue }
            let returnState = owner.dismissal?.returnState ?? owner.presentationState
            owner.cancelDismissal()
            owner.animate(to: returnState)
        }
        interrupted?.completion?(false)
        if let operation = dismissal { completeDismissalContext(operation, completed: false) }
    }

    /**
     Sets the y position of the presentedView & adjusts the backgroundView.
     */
    func adjust(toYPosition yPos: CGFloat) {
      if presentedView.frame.origin.y == anchoredYPosition && yPos > anchoredYPosition {
        presentable?.onTouchTop(true)
      }
      if yPos == anchoredYPosition && presentedView.frame.origin.y >= anchoredYPosition {
        presentable?.onTouchTop(false)
      }
        presentedView.frame.origin.y = yPos
        yPosition = yPos
        let distance = hiddenYPosition - shortFormYPosition
        // Keep position and opacity affine through the native spring.
        // Core Animation clamps the rendered opacity, including overshoot.
        backgroundView.layer.opacity = distance > 0 ? Float((hiddenYPosition - yPos) / distance) : 0
    }

    /**
     Finds the nearest value to a given number out of a given array of float values

     - Parameters:
        - number: reference float we are trying to find the closest value to
        - values: array of floats we would like to compare against
     */
    func nearest(to number: CGFloat, inValues values: [CGFloat]) -> CGFloat {
        guard let nearestVal = values.min(by: { abs(number - $0) < abs(number - $1) })
            else { return number }
        return nearestVal
    }


}

// MARK: - UIScrollView Observer

private extension PanModalPresentationController {

    /**
     Reconcile selection before arbitration. Configure the new view before
     observing it so inset changes cannot enter a half-initialized binding.
     */
    func updateScrollView() {
        let selected = (presentable?.panScrollable).flatMap {
            $0.isScrollEnabled && $0.panGestureRecognizer.isEnabled &&
                $0.isDescendant(of: presentedViewController.view) ? $0 : nil
        }
        let selectionChanged = selected !== scrollView
        if selectionChanged || scrollObserver == nil {
            scrollObserver?.invalidate()
            scrollObserver = nil
            scrollView = selected
            if selectionChanged || scrollView?.isScrolling != true {
                configureScrollViewInsets()
            }
            if let scrollView = scrollView {
                trackScrolling(scrollView)
                observe(scrollView: scrollView)
            }
        }
    }

    /**
     Creates & stores an observer on the given scroll view's content offset.
     This allows us to track scrolling without overriding the scrollView delegate
     */
    func observe(scrollView: UIScrollView) {
        scrollObserver?.invalidate()
        scrollObserver = scrollView.observe(\.contentOffset, options: .old) { [weak self] scrollView, change in

            /**
             Incase we have a situation where we have two containerViews in the same presentation
             */
            guard let self = self, self.containerView != nil,
                  scrollView === self.scrollView else { return }
            guard scrollView.isDescendant(of: self.presentedViewController.view) else {
                self.scrollObserver?.invalidate()
                self.scrollObserver = nil
                self.scrollView = nil
                return
            }
            self.didPanOnScrollView(scrollView, change: change)
        }
    }

    /**
     Scroll view content offset change event handler

     Also when scrollView is scrolled to the top, we disable the scroll indicator
     otherwise glitchy behaviour occurs

     This is also shown in Apple Maps (reverse engineering)
     which allows us to seamlessly transition scrolling from the panContainerView to the scrollView
     */
    func didPanOnScrollView(_ scrollView: UIScrollView, change: NSKeyValueObservedChange<CGPoint>) {

        guard
            !presentedViewController.isBeingDismissed,
            !presentedViewController.isBeingPresented
            else { return }

        if !isPresentedViewAnchored && scrollView.contentOffset.y > -scrollView.adjustedContentInset.top {

            /**
             Hold the scrollView in place if we're actively scrolling and not handling top bounce
             */
            haltScrolling(scrollView)

        } else if scrollView.isScrolling || isPresentedViewAnimating {

            if isPresentedViewAnchored {
                /**
                 While we're scrolling upwards on the scrollView,
                 store the last content offset position
                 */
                trackScrolling(scrollView)
            } else {
                /**
                 Keep scroll view in place while we're panning on main view
                 */
                haltScrolling(scrollView)
            }

        } else if presentedViewController.view.isKind(of: UIScrollView.self)
            && !isPresentedViewAnimating && scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top {

            /**
             In the case where we drag down quickly on the scroll view and let go,
             `handleScrollViewTopBounce` adds a nice elegant touch.
             */
            handleScrollViewTopBounce(scrollView: scrollView, change: change)
        } else {
            trackScrolling(scrollView)
        }
    }

    /**
     Halts the scroll of a given scroll view & anchors it at the `scrollViewYOffset`
     */
    func haltScrolling(_ scrollView: UIScrollView) {
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: scrollViewYOffset), animated: false)
        scrollView.showsVerticalScrollIndicator = false
    }

    /**
     As the user scrolls, track & save the scroll view y offset.
     This helps halt scrolling when we want to hold the scroll view in place.
     */
    func trackScrolling(_ scrollView: UIScrollView) {
        scrollViewYOffset = max(scrollView.contentOffset.y, -scrollView.adjustedContentInset.top)
        if (scrollView.contentOffset.y > -scrollView.adjustedContentInset.top) {
            scrollView.showsVerticalScrollIndicator = true
        }
    }

    /**
     To ensure that the scroll transition between the scrollView & the modal
     is completely seamless, we need to handle the case where content offset is negative.

     In this case, we follow the curve of the decelerating scroll view.
     This gives the effect that the modal view and the scroll view are one view entirely.

     - Note: This works best where the view behind view controller is a UIScrollView.
     So, for example, a UITableViewController.
     */
    func handleScrollViewTopBounce(scrollView: UIScrollView, change: NSKeyValueObservedChange<CGPoint>) {

        guard let oldYValue = change.oldValue?.y, scrollView.isDecelerating
            else { return }

        let yOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let presentedSize = containerView?.frame.size ?? .zero

        /**
         Decrease the view bounds by the y offset so the scroll view stays in place
         and we can still get updates on its content offset
         */
        presentedView.bounds.size = CGSize(width: presentedSize.width, height: presentedSize.height + yOffset)

        if oldYValue > scrollView.contentOffset.y {
            /**
             Move the view in the opposite direction to the decreasing bounds
             until half way through the deceleration so that it appears
             as if we're transferring the scrollView drag momentum to the entire view
             */
            presentedView.frame.origin.y = longFormYPosition - yOffset
            self.yPosition = presentedView.frame.origin.y
        } else {
            scrollViewYOffset = -scrollView.adjustedContentInset.top
            animate(to: .longForm)
        }

        scrollView.showsVerticalScrollIndicator = false
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PanModalPresentationController: UIGestureRecognizerDelegate {

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else { return true }
        let velocity = panGestureRecognizer.velocity(in: containerView)
        return abs(velocity.y) > abs(velocity.x)
    }


    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           gestureRecognizer.state == .possible, gestureRecognizer.numberOfTouches == 0 {
            presentable?.willReceivePanTouch(touch)
            updateScrollView()
        }
        return true
    }


    /**
     Do not require any other gesture recognizers to fail
     */
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    /**
     Allow simultaneous gesture recognizers only when the other gesture recognizer's view
     is the pan scrollable view
     */
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer.view == scrollView
    }
}

// MARK: - Motion and Rendering

extension PanModalPresentationController {

    private func setPanFrameRateActive(_ active: Bool) {
        guard active else {
            let endRequest = endPanFrameRateRequest
            endPanFrameRateRequest = nil
            endRequest?()
            return
        }
        guard endPanFrameRateRequest == nil else { return }

        if #available(iOS 18.0, *), let screen = presentedView.window?.screen {
            let maximum = Float(screen.maximumFramesPerSecond)
            guard maximum > 60 else { return }

            // Express tracking intent without scheduling frames or adding a renderer.
            let updateLink = UIUpdateLink(view: presentedView)
            updateLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: min(80, maximum), maximum: maximum, preferred: maximum
            )
            endPanFrameRateRequest = { updateLink.isEnabled = false }
            updateLink.isEnabled = true
        }
    }

    func animatePresentation(from y: CGFloat, completion: @escaping (Bool) -> Void) {
        captureAnimation()?.completion?(false)
        UIView.performWithoutAnimation {
            presentedView.frame.origin.y = y
            yPosition = y
            backgroundView.layer.opacity = 0
        }
        animate(to: .shortForm, completion: completion)
    }

    private func interactionView(for controller: UIViewController) -> UIView? {
        return (controller.presentationController as? PanModalPresentationController)?.containerView
            ?? controller.viewIfLoaded
    }

    func animateDismissal(to presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        guard let operation = dismissal else { completion(false); return }
        operation.contextCompletion = completion
        guard operation.requested else {
            completeDismissalContext(operation, completed: false)
            return
        }
        if operation.origin == .uiKit {
            startDismissalAnimation(operation, to: presenter)
        } else {
            backgroundView.passthroughView = interactionView(for: presenter)
            if animation == nil { completeDismissalContext(operation, completed: true) }
        }
    }

    private func startDismissalAnimation(_ operation: Dismissal, to presenter: UIViewController) {
        guard operation.animated else { return }
        backgroundView.passthroughView = interactionView(for: presenter)
        animate(to: .hidden, velocity: operation.velocity) { [weak self] completed in
            if !completed, self?.dismissal?.requested == true { self?.cancelDismissal() }
            self?.completeDismissalContext(operation, completed: completed)
        }
    }

    private func completeDismissalContext(_ operation: Dismissal, completed: Bool) {
        guard dismissal === operation, let completion = operation.contextCompletion else { return }
        if completed && operation.requested {
            var descendant = presentedViewController.presentedViewController
            while let controller = descendant {
                descendant = controller.presentedViewController
                guard let owner = controller.presentationController as? PanModalPresentationController,
                      let childOperation = owner.dismissal else { continue }
                childOperation.completions.append { [self] in completeDismissalContext(operation, completed: true) }
                return
            }
        }
        operation.contextCompletion = nil
        completion(completed && operation.requested)
        if operation.origin == .uiKit { completeDismissal(operation) }
    }

    private func animate(to destination: PresentationState, velocity: CGFloat = 0, completion: ((Bool) -> Void)? = nil) {
        setPanFrameRateActive(false)
        captureAnimation()?.completion?(false)
        if destination != .hidden { backgroundView.passthroughView = nil }
        let target = position(for: destination)
        let duration = presentable?.transitionDuration ?? PanModalAnimator.Constants.defaultTransitionDuration
        let distance = target - presentedView.frame.minY
        // At the exact destination, retain UIKit's resting-endpoint behavior.
        guard distance != 0, duration > 0, UIView.areAnimationsEnabled else {
            UIView.performWithoutAnimation { adjust(toYPosition: target) }
            completion?(true)
            return
        }
        let normalizedVelocity = velocity / distance
        let timing = UISpringTimingParameters(
            dampingRatio: presentable?.springDamping ?? 1,
            initialVelocity: CGVector(dx: normalizedVelocity, dy: normalizedVelocity)
        )
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: timing
        )
        animator.isUserInteractionEnabled = true
        animator.addAnimations { [weak self] in self?.adjust(toYPosition: target) }
        animator.addCompletion { [weak self, weak animator] position in
            guard let self = self, self.animation?.animator === animator else { return }
            self.animation = nil
            completion?(position == .end)
        }
        animation = Animation(destination: destination, animator: animator, completion: completion)
        animator.startAnimation()
    }

    private func captureAnimation() -> Animation? {
        guard let animation = animation else { return nil }
        let y = presentedView.layer.presentation()?.frame.minY ?? presentedView.frame.minY
        let opacity = backgroundView.layer.presentation()?.opacity ?? backgroundView.layer.opacity
        self.animation = nil
        animation.animator.stopAnimation(true)
        UIView.performWithoutAnimation {
            presentedView.frame.origin.y = y
            yPosition = y
            backgroundView.layer.opacity = opacity
        }
        return animation
    }

    private func configureCorners() {
        let layer = presentedView.layer
        layer.cornerRadius = presentable?.shouldRoundTopCorners == true ? presentable?.cornerRadius ?? 0 : 0
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = presentable?.shouldRoundTopCorners == true
    }
}

// MARK: - Helper Extensions

private extension UIScrollView {

    /**
     A flag to determine if a scroll view is scrolling
     */
    var isScrolling: Bool {
        return isDragging && !isDecelerating || isTracking
    }
}
