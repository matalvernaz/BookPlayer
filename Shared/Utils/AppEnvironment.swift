//
//  AppEnvironment.swift
//  BookPlayer
//
//  Created by BookPlayer on 12/6/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation

public enum AppEnvironment {
  /// Checks if the app is running in a TestFlight environment
  public static var isTestFlight: Bool {
    #if DEBUG
    return false
    #else
    // This fork has no App Store channel — every Release install is TestFlight.
    // Don't reinstate the appStoreReceiptURL/sandboxReceipt check: iOS 26+
    // removed the legacy StoreKit receipt, so it reports false on newer OSes
    // (which re-locked pro features, disabled media-server progress sync, and
    // armed a fatalError in PlayerManager.play on real devices).
    return true
    #endif
  }
  
  /// Checks if in-app purchases should be enabled
  public static var isPurchaseEnabled: Bool {
    return !isTestFlight
  }
  
  /// Returns the current environment description for debugging
  public static var environmentDescription: String {
    if isTestFlight {
      return "TestFlight"
    }
    #if DEBUG
    return "Debug"
    #else
    return "Production"
    #endif
  }
}

