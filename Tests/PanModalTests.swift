//
//  PanModalTests.swift
//  PanModalTests
//
//  Created by Tosin Afolabi on 2/26/19.
//  Copyright © 2019 PanModal. All rights reserved.
//

import XCTest
@testable import PanModal

/**
 ⚠️ Run tests on iPhone 8 iOS (12.1) Sim
 */

class PanModalTests: XCTestCase {

    class MockViewController: UIViewController, PanModalPresentable {
        var panScrollable: UIScrollView? { return nil }
    }

    class AdjustedMockViewController: UITableViewController, PanModalPresentable {
        var panScrollable: UIScrollView? { return tableView }
        var shortFormHeight: PanModalHeight { return .contentHeight(300) }
        var longFormHeight: PanModalHeight { return .maxHeightWithTopInset(50) }
        // for testing purposes - to mimic safe area insets
        var topLayoutOffset: CGFloat { return 20 }
        var bottomLayoutOffset: CGFloat { return 44 }
    }

    private var vc: AdjustedMockViewController!

    override func setUp() {
        super.setUp()
        vc = AdjustedMockViewController()
    }

    override func tearDown() {
        super.tearDown()
        vc = nil
    }

    func testPresentableDefaults() {

        let vc = MockViewController()

        XCTAssertEqual(vc.topOffset, 41.0)
        XCTAssertEqual(vc.shortFormHeight, PanModalHeight.maxHeight)
        XCTAssertEqual(vc.longFormHeight, PanModalHeight.maxHeight)
        XCTAssertEqual(vc.springDamping, 0.8)
        XCTAssertEqual(vc.panModalBackgroundColor, UIColor.black.withAlphaComponent(0.7))
        XCTAssertEqual(vc.scrollIndicatorInsets, .zero)
        XCTAssertEqual(vc.anchorModalToLongForm, true)
        XCTAssertEqual(vc.allowsExtendedPanScrolling, false)
        XCTAssertEqual(vc.allowsDragToDismiss, true)
        XCTAssertEqual(vc.allowsTapToDismiss, true)
        XCTAssertEqual(vc.isUserInteractionEnabled, true)
        XCTAssertEqual(vc.isHapticFeedbackEnabled, true)
        XCTAssertEqual(vc.shouldRoundTopCorners, false)
        XCTAssertEqual(vc.shouldRoundTopCorners, false)
        XCTAssertEqual(vc.cornerRadius, 8.0)
        XCTAssertEqual(vc.transitionDuration, PanModalAnimator.Constants.defaultTransitionDuration)
        XCTAssertEqual(vc.transitionAnimationOptions, [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState])
    }

    func testPresentableYValues() {

        XCTAssertEqual(vc.topLayoutOffset, 20)
        XCTAssertEqual(vc.bottomLayoutOffset, 44)

        XCTAssertEqual(vc.topMargin(from: .maxHeight), 0)
        XCTAssertEqual(vc.topMargin(from: .maxHeightWithTopInset(40)), 40)
        XCTAssertEqual(vc.topMargin(from: .contentHeight(200)), 447)
        XCTAssertEqual(vc.topMargin(from: .contentHeightIgnoringSafeArea(200)), 447)

        XCTAssertEqual(vc.shortFormYPos, 388)
        XCTAssertEqual(vc.longFormYPos, 91)
        XCTAssertEqual(vc.bottomYPos, vc.view.frame.height)

        XCTAssertEqual(vc.view.frame.height, UIScreen.main.bounds.size.height - 20)
    }

    func testShortSheetOpensFromBelowItsAnchor() {
        assertUpwardPresentation(height: .contentHeightIgnoringSafeArea(300))
    }

    func testFullHeightSheetOpensFromBelowItsAnchor() {
        assertUpwardPresentation(height: .maxHeight)
    }

    func testReopeningCancelsDismissalAndSettlesJoinedCallbacks() {
        let previousWindow = UIApplication.shared.keyWindow
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = AppearanceViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let sheet = OpeningViewController()
        sheet.height = .contentHeightIgnoringSafeArea(300)
        let opened = expectation(description: "Sheet is open")
        let sampler = FrameSampler {
            guard let view = sheet.presentationController?.presentedView,
                  let presentation = view.layer.presentation(),
                  abs(presentation.frame.minY - sheet.shortFormYPos) < 0.1,
                  view.layer.animationKeys()?.isEmpty ?? true else { return false }
            opened.fulfill()
            return true
        }
        defer {
            sampler.stop()
            root.dismiss(animated: false)
            window.isHidden = true
            previousWindow?.makeKey()
        }
        root.presentPanModal(sheet)
        sampler.start()
        wait(for: [opened], timeout: 3)
        root.appearances = 0

        let completed = expectation(description: "Original and joined dismissals settle")
        completed.expectedFulfillmentCount = 2
        var willDismissCount = 0
        let completion = {
            XCTAssertTrue(root.presentedViewController === sheet)
            XCTAssertFalse(sheet.isBeingDismissed)
            completed.fulfill()
        }
        sheet.onWillDismiss = {
            willDismissCount += 1
            sheet.panModalDismiss(completion: completion)
        }
        sheet.panModalDismiss(completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertTrue(sheet.isBeingDismissed)
            XCTAssertEqual(sheet.transitionCoordinator?.isInteractive, true)
            sheet.panModalTransition(to: .shortForm)
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(willDismissCount, 1)
        XCTAssertEqual(root.appearances, 0, "Cancellation must not report a new presenter appearance")
        sheet.onWillDismiss = nil
    }

    func testReopeningBeforeDismissalAnimationStarts() {
        let sheet = OpeningViewController()
        sheet.duration = 0.25
        sheet.height = .contentHeightIgnoringSafeArea(300)
        withPresentedSheets([sheet]) { root, _ in
            let completed = expectation(description: "The superseded dismissal settles")
            sheet.panModalDismiss {
                XCTAssertTrue(root.presentedViewController === sheet)
                XCTAssertFalse(sheet.isBeingDismissed)
                completed.fulfill()
            }
            sheet.panModalTransition(to: .shortForm)
            wait(for: [completed], timeout: 3)
            XCTAssertNotNil(sheet.view.window)
        }
    }

    func testParentDismissalMovesBeforeChildFinishesWithoutRestarting() {
        let parent = OpeningViewController()
        parent.duration = 0.2
        parent.height = .contentHeightIgnoringSafeArea(650)
        let child = OpeningViewController()
        child.duration = 0.2
        child.height = .contentHeightIgnoringSafeArea(450)
        withPresentedSheets([parent, child]) { root, _ in
            parent.duration = 0.8
            child.duration = 0.3
            let controller = parent.presentationController as! PanModalPresentationController
            let view = controller.presentedView
            let startY = view.frame.minY
            var childFinished = false
            var springStart: CFTimeInterval?
            var joinedContext = false
            let completed = expectation(description: "Both sheets finish dismissing")
            let sampler = FrameSampler {
                guard let presentation = view.layer.presentation(),
                      presentation.frame.minY > startY + 1,
                      let spring = view.layer.animationKeys()?.compactMap({
                          view.layer.animation(forKey: $0) as? CASpringAnimation
                      }).first else { return false }
                if let springStart = springStart {
                    if spring.beginTime != springStart {
                        XCTFail("Attaching UIKit's context must preserve the running spring")
                        return true
                    }
                } else {
                    XCTAssertFalse(childFinished, "The parent's motion must not wait for child teardown")
                    XCTAssertGreaterThan(spring.beginTime, 0)
                    springStart = spring.beginTime
                }
                if childFinished, parent.isBeingDismissed { joinedContext = true }
                return false
            }
            defer { sampler.stop() }
            child.panModalDismiss { childFinished = true }
            parent.panModalDismiss {
                XCTAssertNil(root.presentedViewController)
                completed.fulfill()
            }
            sampler.start()
            wait(for: [completed], timeout: 3)
            XCTAssertTrue(joinedContext)
        }
    }

    func testQueuedParentDismissalPreservesNewChildPresentationAndForm() {
        let parent = OpeningViewController()
        parent.duration = 0.25
        parent.height = .contentHeightIgnoringSafeArea(300)
        parent.longHeight = .contentHeightIgnoringSafeArea(600)
        let child = OpeningViewController()
        child.duration = 0.25
        child.height = .contentHeightIgnoringSafeArea(300)
        withPresentedSheets([parent, child]) { root, _ in
            let completed = expectation(description: "Pending parent and child requests settle")
            completed.expectedFulfillmentCount = 3
            let completion = { completed.fulfill() }
            child.panModalDismiss(completion: completion)
            parent.panModalDismiss(completion: completion)
            parent.panModalTransition(to: .longForm)
            parent.panModalDismiss(completion: completion)
            child.panModalTransition(to: .shortForm)
            wait(for: [completed], timeout: 3)
            waitForSheet(parent, at: parent.longFormYPos)
            XCTAssertTrue(root.presentedViewController === parent)
            XCTAssertTrue(parent.presentedViewController === child)
            XCTAssertNotNil(parent.view.window)
            XCTAssertNotNil(child.view.window)
            XCTAssertFalse(parent.isBeingDismissed)
            XCTAssertFalse(child.isBeingDismissed)
        }
    }

    func testChildReopeningAfterParentSpringEndsKeepsPresentationChain() {
        let parent = OpeningViewController()
        parent.duration = 0.25
        parent.height = .contentHeightIgnoringSafeArea(300)
        let child = OpeningViewController()
        child.duration = 0.25
        child.height = .contentHeightIgnoringSafeArea(300)
        withPresentedSheets([parent, child]) { root, window in
            parent.duration = 0.12
            child.duration = 0.8
            let controller = parent.presentationController as! PanModalPresentationController
            let completed = expectation(description: "Parent dismissal cancels")
            let reachedBoundary = expectation(description: "Parent spring ends while child still exits")
            let sampler = FrameSampler {
                guard controller.presentedView.frame.minY >= window.bounds.height - 0.5,
                      controller.presentedView.layer.animationKeys()?.isEmpty ?? true,
                      let childPresentation = child.presentationController?.presentedView?.layer.presentation(),
                      childPresentation.frame.minY < window.bounds.height - 20 else { return false }
                XCTAssertTrue(root.presentedViewController === parent)
                XCTAssertTrue(parent.presentedViewController === child)
                reachedBoundary.fulfill()
                child.panModalTransition(to: .shortForm)
                return true
            }
            defer { sampler.stop() }
            parent.panModalDismiss {
                XCTAssertTrue(root.presentedViewController === parent)
                XCTAssertFalse(parent.isBeingDismissed)
                completed.fulfill()
            }
            sampler.start()
            wait(for: [reachedBoundary, completed], timeout: 3)
            waitForSheet(parent, at: parent.shortFormYPos)
            waitForSheet(child, at: child.shortFormYPos)
            XCTAssertTrue(root.presentedViewController === parent)
            XCTAssertTrue(parent.presentedViewController === child)
            XCTAssertNotNil(parent.view.window)
            XCTAssertNotNil(child.view.window)
        }
    }

    private func withPresentedSheets(_ sheets: [OpeningViewController],
                                     perform body: (UIViewController, UIWindow) -> Void) {
        let previousWindow = UIApplication.shared.keyWindow
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            previousWindow?.makeKey()
        }
        var presenter = root
        for sheet in sheets {
            presenter.presentPanModal(sheet)
            waitForSheet(sheet, at: sheet.shortFormYPos)
            presenter = sheet
        }
        body(root, window)
    }

    private func waitForSheet(_ sheet: OpeningViewController, at target: CGFloat) {
        let settled = expectation(description: "Sheet settles at its requested form")
        let sampler = FrameSampler {
            guard let view = sheet.presentationController?.presentedView,
                  let presentation = view.layer.presentation(),
                  abs(presentation.frame.minY - target) < 0.5,
                  view.layer.animationKeys()?.isEmpty ?? true else { return false }
            settled.fulfill()
            return true
        }
        defer { sampler.stop() }
        sampler.start()
        wait(for: [settled], timeout: 3)
    }

    private func assertUpwardPresentation(height: PanModalHeight,
                                          file: StaticString = #file, line: UInt = #line) {
        let previousWindow = UIApplication.shared.keyWindow
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let sheet = OpeningViewController()
        sheet.height = height
        let settled = expectation(description: "Opening animation settles")
        var positions: [CGFloat] = []
        let sampler = FrameSampler {
            guard let controller = sheet.presentationController as? PanModalPresentationController,
                  controller.containerView != nil,
                  let presentation = controller.presentedView.layer.presentation() else { return false }
            positions.append(presentation.frame.minY)
            if controller.presentedView.layer.animationKeys()?.isEmpty ?? true {
                settled.fulfill()
                return true
            }
            return false
        }
        defer {
            sampler.stop()
            root.dismiss(animated: false)
            window.isHidden = true
            previousWindow?.makeKey()
        }

        root.presentPanModal(sheet)
        sampler.start()
        wait(for: [settled], timeout: 3)

        let target = sheet.shortFormYPos
        let travel = window.bounds.height - target
        XCTAssertTrue(positions.contains { $0 > target + travel * 0.25 },
                      "Presentation must travel upward from below its anchor", file: file, line: line)
        XCTAssertGreaterThan(positions.first ?? target, target + 20, file: file, line: line)
        XCTAssertEqual(positions.last ?? -1, target, accuracy: 1, file: file, line: line)
    }

    private class OpeningViewController: UIViewController, PanModalPresentable {
        var onWillDismiss: (() -> Void)?
        func panModalWillDismiss() { onWillDismiss?() }
        var height: PanModalHeight = .maxHeight
        var longHeight: PanModalHeight?
        var duration: Double = 1
        var panScrollable: UIScrollView? { nil }
        var topOffset: CGFloat { 0 }
        var shortFormHeight: PanModalHeight { height }
        var longFormHeight: PanModalHeight { longHeight ?? height }
        var transitionDuration: Double { duration }
        var springDamping: CGFloat { 1 }
        var isHapticFeedbackEnabled: Bool { false }
    }

    private class AppearanceViewController: UIViewController {
        var appearances = 0
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appearances += 1
        }
    }

    private class FrameSampler: NSObject {
        private let sample: () -> Bool
        private var displayLink: CADisplayLink?

        init(sample: @escaping () -> Bool) { self.sample = sample }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            if sample() { stop() }
        }
    }
}
