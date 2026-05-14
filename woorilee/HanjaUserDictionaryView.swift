//
//  HanjaUserDictionaryView.swift
//  woorilee
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class HanjaUserDictionaryViewModel {
    private(set) var entries: [UserHanjaEntry] = []
    var searchText: String = ""
    var selection: UUID?

    private let store: UserHanjaStore
    private var originalKeysByID: [UUID: HanjaCandidateKey] = [:]
    private var dirtyIDs: Set<UUID> = []

    init(store: UserHanjaStore) {
        self.store = store
        reloadFromStore()
    }

    func reloadFromStore() {
        entries = store.entries
        originalKeysByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.candidateKey) })
        dirtyIDs.removeAll()
    }

    var filteredEntries: [UserHanjaEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return entries
        }
        return entries.filter { entry in
            entry.reading.localizedCaseInsensitiveContains(trimmed)
                || entry.value.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func readingBinding(for entryID: UUID) -> Binding<String> {
        Binding(
            get: { [self] in
                entries.first(where: { $0.id == entryID })?.reading ?? ""
            },
            set: { [self] newValue in
                guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
                    return
                }
                guard entries[index].reading != newValue else {
                    return
                }
                entries[index].reading = newValue
                entries[index].updatedAt = Date()
                dirtyIDs.insert(entryID)
            }
        )
    }

    func valueBinding(for entryID: UUID) -> Binding<String> {
        Binding(
            get: { [self] in
                entries.first(where: { $0.id == entryID })?.value ?? ""
            },
            set: { [self] newValue in
                guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
                    return
                }
                guard entries[index].value != newValue else {
                    return
                }
                entries[index].value = newValue
                entries[index].updatedAt = Date()
                dirtyIDs.insert(entryID)
            }
        )
    }

    func commitEntry(id: UUID) {
        guard dirtyIDs.contains(id) else {
            return
        }
        guard let entry = entries.first(where: { $0.id == id }) else {
            dirtyIDs.remove(id)
            return
        }
        guard !entry.reading.isEmpty, !entry.value.isEmpty else {
            return
        }

        let oldKey = originalKeysByID[id]
        let newKey = entry.candidateKey
        if let oldKey, oldKey != newKey {
            try? store.delete(candidateKey: oldKey)
        }
        do {
            let saved = try store.save(entry)
            dirtyIDs.remove(id)
            originalKeysByID[id] = saved.candidateKey
            if saved.id != entry.id {
                reloadFromStore()
            }
        } catch {
            // Persist failures leave the entry dirty so a later commit can retry.
        }
    }

    func commitAllDirty() {
        for id in Array(dirtyIDs) {
            commitEntry(id: id)
        }
    }

    func addEntry() {
        commitAllDirty()
        let now = Date()
        let newEntry = UserHanjaEntry(
            id: UUID(),
            reading: "",
            value: "",
            comment: "",
            createdAt: now,
            updatedAt: now
        )
        entries.append(newEntry)
        originalKeysByID[newEntry.id] = nil
        selection = newEntry.id
    }

    func deleteSelected() {
        commitAllDirty()
        guard let id = selection else {
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let oldKey = originalKeysByID[id] {
            try? store.delete(candidateKey: oldKey)
        }
        entries.remove(at: index)
        originalKeysByID.removeValue(forKey: id)
        dirtyIDs.remove(id)
        selection = nil
    }
}

struct HanjaUserDictionaryView: View {
    @Bindable var viewModel: HanjaUserDictionaryViewModel
    @FocusState private var focusedField: FocusTarget?

    private enum FocusTarget: Hashable {
        case reading(UUID)
        case value(UUID)

        var entryID: UUID {
            switch self {
            case .reading(let id), .value(let id):
                return id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(viewModel.filteredEntries, selection: $viewModel.selection) {
                TableColumn("한글") { entry in
                    TextField("", text: viewModel.readingBinding(for: entry.id))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .reading(entry.id))
                        .onSubmit {
                            viewModel.commitEntry(id: entry.id)
                        }
                }
                TableColumn("한자") { entry in
                    TextField("", text: viewModel.valueBinding(for: entry.id))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .value(entry.id))
                        .onSubmit {
                            viewModel.commitEntry(id: entry.id)
                        }
                }
            }
            .onChange(of: focusedField) { oldValue, _ in
                if let oldValue {
                    viewModel.commitEntry(id: oldValue.entryID)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 8) {
                Button("추가") {
                    viewModel.addEntry()
                    DispatchQueue.main.async {
                        if let id = viewModel.selection {
                            focusedField = .reading(id)
                        }
                    }
                }
                Button("제거") {
                    viewModel.deleteSelected()
                }
                .disabled(viewModel.selection == nil)
                Spacer()
                searchField
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("검색", text: $viewModel.searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
        .frame(width: 180)
    }
}
