//
//  BP+ErrorAlerts.swift
//  BookPlayerWatch
//
//  Created by Gianni Carlo on 11/11/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import Foundation
import SwiftUI

extension Error {
  /// True when this error only signals that the surrounding work was cancelled.
  /// `URLSession`'s async methods surface task cancellation as `URLError(.cancelled)`,
  /// not Swift's `CancellationError`, so both must be treated as cancellation —
  /// a lifecycle event, never a user-facing failure.
  var isCancellation: Bool {
    if self is CancellationError { return true }
    if let urlError = self as? URLError, urlError.code == .cancelled { return true }
    return false
  }
}

extension View {
  func errorAlert(
    error: Binding<Error?>,
    buttonTitle: String = "OK"
  )
    -> some View
  {
    let localizedAlertError = LocalizedAlertError(error: error.wrappedValue)
    return alert(
      isPresented: Binding(
        get: { LocalizedAlertError(error: error.wrappedValue) != nil },
        set: { if !$0 { error.wrappedValue = nil } }
      ),
      error: localizedAlertError
    ) { _ in
      Button(buttonTitle) {
        error.wrappedValue = nil
      }
    } message: { error in
      Text(error.recoverySuggestion ?? "")
    }
  }
}

struct LocalizedAlertError: LocalizedError {
  var errorDescription: String?
  var recoverySuggestion: String?

  init?(error: Error?) {
    guard let error else { return nil }
    // A cancelled request must never present as an error dialog, no matter
    // which call site forgot to filter it before assigning to its binding.
    guard !error.isCancellation else { return nil }

    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription {
      self.errorDescription = description
      self.recoverySuggestion = localizedError.recoverySuggestion
    } else {
      // Fallback to localizedDescription for non-LocalizedError types
      // or when errorDescription is nil
      self.errorDescription = error.localizedDescription
      self.recoverySuggestion = nil
    }
  }
}
