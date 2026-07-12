//
//  WindowHelper.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 2/3/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import UIKit

@MainActor
enum WindowHelper {
  /// Returns the key window of the currently active scene.
  static var activeWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }?
      .windows.first { $0.isKeyWindow }
  }

  /// True when the main SwiftUI content — the fullscreen host that
  /// `MainCoordinator.start()` presents over the root controller — is the
  /// frontmost presentation: nothing (sheet, player cover, import screen,
  /// onboarding) is presented on top of it and no modal transition is in
  /// flight. Alerts and confirmation dialogs presented from the main content
  /// can only appear in this state; triggering them at any other time makes
  /// UIKit silently drop the presentation while SwiftUI's `isPresented`
  /// binding stays true, wedging that view's presentation slot until relaunch.
  static var isMainContentFrontmost: Bool {
    guard
      let root = activeWindow?.rootViewController,
      let mainHost = root.presentedViewController
    else { return false }

    return mainHost.presentedViewController == nil
      && !mainHost.isBeingPresented
      && !mainHost.isBeingDismissed
  }
}
