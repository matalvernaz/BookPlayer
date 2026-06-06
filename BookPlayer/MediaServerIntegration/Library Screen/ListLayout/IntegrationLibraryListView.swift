//
//  IntegrationLibraryListView.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 4/5/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import SwiftUI

struct IntegrationLibraryListView<
  Model: IntegrationLibraryViewModelProtocol,
  RowContent: View
>: View {
  @ObservedObject var viewModel: Model
  @ViewBuilder let rowContent: (Model.Item) -> RowContent

  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    if viewModel.isAlphabeticallySectioned {
      sectionedList
    } else {
      flatList
    }
  }

  private var flatList: some View {
    List(viewModel.items, selection: $viewModel.selectedItems) { item in
      row(item: item)
        .selectionDisabled(!item.isDownloadable)
        .listRowBackground(theme.tertiarySystemBackgroundColor)
    }
  }

  /// Items grouped under alphabetical letter headings (Contacts-style). Letter
  /// headings are exposed to VoiceOver as headings, so navigation is via the
  /// Headings rotor. Only used for fully-loaded, name-sorted lists — see
  /// `IntegrationLibraryViewModelProtocol.isAlphabeticallySectioned`.
  private var sectionedList: some View {
    List(selection: $viewModel.selectedItems) {
      ForEach(letterSections, id: \.key) { section in
        Section(header: Text(section.key)) {
          ForEach(section.items) { item in
            row(item: item)
              .selectionDisabled(!item.isDownloadable)
              .listRowBackground(theme.tertiarySystemBackgroundColor)
          }
        }
      }
    }
  }

  /// Items grouped by heading letter ("#" for non-letter names, sorted last),
  /// preserving the incoming name-sort within each group.
  private var letterSections: [(key: String, items: [Model.Item])] {
    Dictionary(grouping: viewModel.items) { Self.sectionKey(for: $0.displayName) }
      .map { (key: $0.key, items: $0.value) }
      .sorted { lhs, rhs in
        if lhs.key == "#" { return false }
        if rhs.key == "#" { return true }
        return lhs.key < rhs.key
      }
  }

  /// First character of the name, diacritic-folded and uppercased (so "Élodie"
  /// files under "E"). Names not starting with a letter file under "#".
  private static func sectionKey(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let first = trimmed.first,
      let folded = String(first).folding(options: .diacriticInsensitive, locale: .current).uppercased().first,
      folded.isLetter
    else {
      return "#"
    }
    return String(folded)
  }

  func row(item: Model.Item) -> some View {
    rowContent(item)
      .accessibilityAddTraits(.isButton)
      .contentShape(Rectangle())
      .onTapGesture {
        if viewModel.editMode.isEditing {
          guard item.isDownloadable else { return }
          viewModel.onSelectTapped(for: item)
        } else if let destination = viewModel.destination(for: item) {
          viewModel.navigation.path.append(destination)
        }
      }
      .onAppear {
        viewModel.fetchMoreItemsIfNeeded(currentItem: item)
      }
  }
}
