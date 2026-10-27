//
//  ShareImportFailure+Message.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// The words for a failed share (fork), made in the app because the share extension has no translations
extension ShareImportFailure {
  /// The failure as the person reads it, naming what they shared
  var message: String {
    switch reason {
    case .copyFailed(let detail):
      return String(format: "share_import_failure_copy_failed".localized, source, detail)
    case .downloadFailed(let detail):
      return String(format: "share_import_failure_download_failed".localized, source, detail)
    case .httpStatus(let code):
      return String(format: "share_import_failure_http_status".localized, source, code)
    case .saveFailed(let detail):
      return String(format: "share_import_failure_move_failed".localized, source, detail)
    case .stoppedByForceQuit:
      return String(format: "share_import_failure_stopped_by_force_quit".localized, source)
    case .unsupportedExtension:
      return String(format: "share_import_failure_unsupported_extension".localized, source)
    case .unsupportedType(let mimeType):
      return String(format: "share_import_failure_unsupported_type".localized, source, mimeType)
    }
  }

  /// What VoiceOver says when failures turn up: the one failure, or the alert's title and then each
  static func announcement(for failures: [ShareImportFailure]) -> String {
    if failures.count == 1 {
      return failures[0].message
    }
    let title = "share_import_failure_alert_title".localized
    return "\(title). " + failures.map(\.message).joined(separator: " ")
  }
}
