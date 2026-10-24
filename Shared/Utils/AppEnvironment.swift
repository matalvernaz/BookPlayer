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
    // This fork has no App Store channel: every Release install is a TestFlight
    // build. TestFlight builds must be archived as Release for this to hold; the
    // Debug archives shipped from 05-19 to 07-25 made it false, which turned the
    // TestFlight-only features off (.github/scripts/testflight-checks.sh now
    // refuses a Debug archive).
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

