import SwiftUI
import Foundation
import UserNotifications
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - Models
struct Attachment: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var fileName: String   // original name, shown to the user
    var storedName: String // "<id>/<fileName>" inside the Attachments folder

    var isImage: Bool {
        let ext = (storedName as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }
}

struct Folder: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
}

struct Note: Identifiable, Codable, Equatable, Hashable  {
    var id = UUID()
    var content: String
    var attachments: [Attachment] = []
    var folderID: UUID? = nil // nil means the note isn't in a folder
    // nil for notes saved before dates were tracked, since their real dates are unknown
    var createdAt: Date? = Date()
    var modifiedAt: Date? = Date()

    enum CodingKeys: String, CodingKey {
        case id, content, attachments, folderID, createdAt, modifiedAt
    }
}

extension Note {
    // notes saved by older versions are missing some of these keys
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
    }

    private var nonEmptyLines: [String] {
        content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // first line of text, or the first attachment's name for a note with no text
    var title: String {
        nonEmptyLines.first ?? attachments.first?.fileName ?? "New Note"
    }

    // the line shown under the title in the notes list
    var previewText: String {
        let lines = nonEmptyLines
        if lines.count > 1 {
            return lines[1]
        }
        if !attachments.isEmpty {
            return attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"
        }
        return "No additional text"
    }

    // search matches the note's text or any attachment's file name
    func matches(_ query: String) -> Bool {
        content.localizedCaseInsensitiveContains(query)
            || attachments.contains { $0.fileName.localizedCaseInsensitiveContains(query) }
    }
}

extension Array where Element == Note {
    // most recently edited first; undated notes (from before dates were tracked) go last, newest first
    func sortedByLastEdited() -> [Note] {
        enumerated().sorted { a, b in
            switch (a.element.modifiedAt, b.element.modifiedAt) {
            case let (aDate?, bDate?):
                return aDate != bDate ? aDate > bDate : a.offset > b.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.offset > b.offset
            }
        }
        .map(\.element)
    }
}

extension Date {
    // time for today, "Yesterday", weekday within the last week, otherwise the date (like Apple Notes)
    var shortListDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case never, daily, weekly, monthly, yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    // the date parts a notification has to match for this rule
    var matchingComponents: Set<Calendar.Component> {
        switch self {
        case .never: return [.year, .month, .day, .hour, .minute]
        case .daily: return [.hour, .minute]
        case .weekly: return [.weekday, .hour, .minute]
        case .monthly: return [.day, .hour, .minute]
        case .yearly: return [.month, .day, .hour, .minute]
        }
    }

    private var step: (component: Calendar.Component, value: Int)? {
        switch self {
        case .never: return nil
        case .daily: return (.day, 1)
        case .weekly: return (.day, 7)
        case .monthly: return (.month, 1)
        case .yearly: return (.year, 1)
        }
    }

    // first occurrence after `now`, counted from the original date so monthly
    // repeats on the 31st come back to the 31st instead of drifting to the 28th
    func nextOccurrence(after now: Date, from start: Date, calendar: Calendar = .current) -> Date? {
        guard let step = step else { return nil }
        for count in 1...100_000 {
            guard let next = calendar.date(byAdding: step.component, value: step.value * count, to: start) else { return nil }
            if next > now {
                return next
            }
        }
        return nil
    }
}

struct Reminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var content: String
    var date: Date // when it's due; for repeating reminders, the current occurrence
    var repeatRule: RepeatRule = .never
    var isCompleted: Bool = false
    var completedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, content, date, repeatRule, isCompleted, completedAt
    }

    var isOverdue: Bool {
        !isCompleted && date < Date()
    }

    // repeating reminders move on to their next occurrence instead of being completed
    mutating func markDone(now: Date = Date(), calendar: Calendar = .current) {
        if let next = repeatRule.nextOccurrence(after: now, from: date, calendar: calendar) {
            date = next
        } else {
            isCompleted = true
            completedAt = now
        }
    }

    mutating func markNotDone() {
        isCompleted = false
        completedAt = nil
    }

    // nil when there's nothing left to notify about
    func notificationTrigger(now: Date = Date(), calendar: Calendar = .current) -> UNCalendarNotificationTrigger? {
        guard !isCompleted else { return nil }

        if repeatRule != .never {
            let repeating = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents(repeatRule.matchingComponents, from: date),
                repeats: true
            )
            // a repeating trigger fires at its next match, which can be before a start date that's
            // further out; until the start date is the next match, notify once on the start date
            if let next = repeating.nextTriggerDate(), next >= date {
                return repeating
            }
        }

        guard date > now else { return nil }
        return UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents(RepeatRule.never.matchingComponents, from: date),
            repeats: false
        )
    }
}

extension Reminder {
    // reminders saved by older versions have no repeat or completion keys
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        date = try container.decode(Date.self, forKey: .date)
        repeatRule = try container.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .never
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

// MARK: - DataManager
class DataManager {
    static let shared = DataManager()

    private init() {}

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    // Save notes to file
    func saveNotes(notes: [Note]) {
        save(notes, to: "notes.json")
    }

    // Load notes from file
    func loadNotes() -> [Note] {
        load(from: "notes.json")
    }

    // Save folders to file
    func saveFolders(folders: [Folder]) {
        save(folders, to: "folders.json")
    }

    // Load folders from file
    func loadFolders() -> [Folder] {
        load(from: "folders.json")
    }

    // Save reminders to file
    func saveReminders(reminders: [Reminder]) {
        save(reminders, to: "reminders.json")
    }

    // Load reminders from file
    func loadReminders() -> [Reminder] {
        load(from: "reminders.json")
    }

    private func save<T: Encodable>(_ items: [T], to fileName: String) {
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        do {
            let encoded = try JSONEncoder().encode(items)
            // atomic write so a crash mid-save can't leave a half-written file
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            print("Error saving \(fileName): \(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(from fileName: String) -> [T] {
        let fileURL = getDocumentsDirectory().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return [] // Return an empty array if no data exists
        }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            print("Error decoding \(fileName): \(error)")
            return []
        }
    }

    // MARK: Attachments

    private var attachmentsDirectory: URL {
        let url = getDocumentsDirectory().appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func url(for attachment: Attachment) -> URL {
        attachmentsDirectory.appendingPathComponent(attachment.storedName)
    }

    // each file gets its own folder so it keeps its original name (shown when previewing or sharing)
    private func makeAttachment(fileName: String) throws -> Attachment {
        let id = UUID()
        let folder = attachmentsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Attachment(id: id, fileName: fileName, storedName: "\(id.uuidString)/\(fileName)")
    }

    // Copy a file picked from the Files app into the app's own storage
    func importFile(at sourceURL: URL) throws -> Attachment {
        // files picked from the Files app live outside the sandbox and need scoped access
        let isAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let attachment = try makeAttachment(fileName: sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: url(for: attachment))
        return attachment
    }

    // Save a photo picked from the photo library
    func importImage(data: Data, fileExtension: String) throws -> Attachment {
        let attachment = try makeAttachment(fileName: "Photo.\(fileExtension)")
        try data.write(to: url(for: attachment), options: .atomic)
        return attachment
    }

    func deleteFiles(for attachments: [Attachment]) {
        for attachment in attachments {
            // remove the attachment's whole folder, not just the file
            try? FileManager.default.removeItem(at: url(for: attachment).deletingLastPathComponent())
        }
    }

    // Delete files no saved note points to (imports that were discarded before saving)
    func removeOrphanedAttachments() {
        let notesURL = getDocumentsDirectory().appendingPathComponent("notes.json")
        var referenced = Set<String>()

        if FileManager.default.fileExists(atPath: notesURL.path) {
            // if the notes can't be read, don't risk deleting files they still use
            guard let data = try? Data(contentsOf: notesURL),
                  let notes = try? JSONDecoder().decode([Note].self, from: data) else { return }
            referenced = Set(notes.flatMap { $0.attachments.map(\.id.uuidString) })
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}



// MARK: - ContentView
struct ContentView: View {
    var body: some View {
        TabView {
            // Notes Section
            NavigationStack {
                NotesView()
            }
            .tabItem {
                Label("Notes", systemImage: "note.text")
            }

            // Reminders Section
            NavigationStack {
                RemindersView()
            }
            .tabItem {
                Label("Reminders", systemImage: "alarm")
            }
        }
    }
}


// MARK: - NotesView
struct NotesView: View {
    @State private var notes: [Note] = DataManager.shared.loadNotes()
    @State private var folders: [Folder] = DataManager.shared.loadFolders()
    @State private var selectedFolderID: UUID? = nil // nil shows every note
    @State private var composingNote: Note? // a new note being written; saved once it has content
    @State private var isAddingFolder: Bool = false
    @State private var isManagingFolders: Bool = false
    @State private var newFolderName: String = ""
    @State private var searchText: String = ""

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleNotes: [Note] {
        var result = notes
        if let selectedFolderID = selectedFolderID {
            result = result.filter { $0.folderID == selectedFolderID }
        }
        if !trimmedSearchText.isEmpty {
            result = result.filter { $0.matches(trimmedSearchText) }
        }
        return result.sortedByLastEdited()
    }

    var body: some View {
        List {
            ForEach(visibleNotes) { note in
                NavigationLink {
                    EditNoteView(note: note, folders: folders, onSave: saveNote, onDelete: removeNote)
                } label: {
                    // when showing every note, also say which folder each one is in
                    NoteRow(note: note, folderName: selectedFolderID == nil ? folderName(for: note.folderID) : nil)
                }
                .contextMenu {
                    if !folders.isEmpty {
                        Menu {
                            Picker("Folder", selection: folderBinding(for: note)) {
                                Text("No Folder").tag(UUID?.none)
                                ForEach(folders) { folder in
                                    Text(folder.name).tag(Optional(folder.id))
                                }
                            }
                        } label: {
                            Label("Move to Folder", systemImage: "folder")
                        }
                    }
                }
            }
            .onDelete(perform: deleteNotes)
        }
        .listStyle(.insetGrouped)
        .overlay {
            if visibleNotes.isEmpty {
                if !trimmedSearchText.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearchText)
                } else if selectedFolderID != nil {
                    ContentUnavailableView(
                        "No Notes in This Folder",
                        systemImage: "folder",
                        description: Text("Write one here, or long-press a note in All Notes to move it.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Notes Yet",
                        systemImage: "note.text",
                        description: Text("Tap \(Image(systemName: "square.and.pencil")) to write your first one.")
                    )
                }
            }
        }
        // always shown, instead of hiding until the list is pulled down
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
        .navigationTitle(folderName(for: selectedFolderID) ?? "Notes")
        .navigationDestination(item: $composingNote) { note in
            EditNoteView(note: note, folders: folders, isNew: true, onSave: saveNote, onDelete: removeNote)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $selectedFolderID) {
                        Label("All Notes", systemImage: "tray.full").tag(UUID?.none)
                        ForEach(folders) { folder in
                            Label(folder.name, systemImage: "folder").tag(Optional(folder.id))
                        }
                    }

                    Divider()

                    Button(action: {
                        newFolderName = ""
                        isAddingFolder = true
                    }) {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }

                    if !folders.isEmpty {
                        Button(action: { isManagingFolders = true }) {
                            Label("Manage Folders…", systemImage: "pencil")
                        }
                    }
                } label: {
                    Label("Folders", systemImage: "folder")
                }

                Button(action: {
                    // new notes start in the folder being viewed
                    composingNote = Note(content: "", folderID: selectedFolderID)
                }) {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("New Folder", isPresented: $isAddingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: addFolder)
        }
        .sheet(isPresented: $isManagingFolders) {
            ManageFoldersView(folders: $folders, notes: notes)
        }
        .onChange(of: folders) { _, newFolders in
            DataManager.shared.saveFolders(folders: newFolders)

            // notes in a deleted folder are kept, they just aren't in a folder anymore
            let folderIDs = Set(newFolders.map(\.id))
            var didChangeNotes = false
            for index in notes.indices {
                if let folderID = notes[index].folderID, !folderIDs.contains(folderID) {
                    notes[index].folderID = nil
                    didChangeNotes = true
                }
            }
            if didChangeNotes {
                saveNotes()
            }

            if let selectedFolderID = selectedFolderID, !folderIDs.contains(selectedFolderID) {
                self.selectedFolderID = nil
            }
        }
    }

    private func folderName(for folderID: UUID?) -> String? {
        guard let folderID = folderID else { return nil }
        return folders.first(where: { $0.id == folderID })?.name
    }

    private func folderBinding(for note: Note) -> Binding<UUID?> {
        Binding(
            get: { note.folderID },
            set: { newFolderID in
                if let index = notes.firstIndex(where: { $0.id == note.id }) {
                    notes[index].folderID = newFolderID
                    saveNotes()
                }
            }
        )
    }

    private func addFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // reuse a folder with the same name instead of making a duplicate
        if let existing = folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selectedFolderID = existing.id
            return
        }

        let folder = Folder(name: name)
        folders.append(folder)
        selectedFolderID = folder.id // open the new folder
    }

    private func saveNotes() {
        DataManager.shared.saveNotes(notes: notes)
    }

    // updates an existing note, or adds a new one the first time it's saved
    private func saveNote(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        saveNotes()
    }

    // the editor has already removed the note's attachment files
    private func removeNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        saveNotes()
    }

    private func deleteNotes(at offsets: IndexSet) {
        // offsets point into the (possibly filtered) list on screen
        let ids = Set(offsets.map { visibleNotes[$0].id })
        DataManager.shared.deleteFiles(for: notes.filter { ids.contains($0.id) }.flatMap(\.attachments))
        notes.removeAll { ids.contains($0.id) }
        saveNotes() // Save after delete
    }
}

// MARK: - Note Row
struct NoteRow: View {
    let note: Note
    let folderName: String? // shown when listing notes from every folder

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let modifiedAt = note.modifiedAt {
                        Text(modifiedAt.shortListDate)
                            .foregroundStyle(.primary)
                    }
                    Text(note.previewText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)

                if let folderName = folderName {
                    // inline image rather than a Label, which List would indent like a row icon
                    Text("\(Image(systemName: "folder")) \(folderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Folder: \(folderName)")
                }
            }

            Spacer(minLength: 0)

            // a photo makes a better thumbnail than a document page, so prefer one when there is one
            if let thumbnailAttachment = note.attachments.first(where: \.isImage) ?? note.attachments.first {
                AttachmentThumbnail(attachment: thumbnailAttachment, size: 48, showsName: false)
                    .accessibilityLabel("Has attachments")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit Note View
struct EditNoteView: View {
    let folders: [Folder]
    let isNew: Bool // a note that isn't in the list until it has content
    var onSave: (Note) -> Void // callback for saving the edited note
    var onDelete: (Note) -> Void
    @Environment(\.dismiss) private var dismiss // to dismiss the view after deleting
    @Environment(\.scenePhase) private var scenePhase

    // edits go into a draft that's saved automatically when leaving the note
    @State private var draft: String
    @State private var draftAttachments: [Attachment]
    @State private var draftFolderID: UUID?
    @State private var savedNote: Note // last saved version, to tell whether the draft has changes
    @State private var isDeleted: Bool = false
    @State private var isConfirmingDelete: Bool = false
    @State private var isPickingPhotos: Bool = false
    @State private var isImportingFiles: Bool = false
    @FocusState private var isEditorFocused: Bool

    init(note: Note, folders: [Folder], isNew: Bool = false, onSave: @escaping (Note) -> Void, onDelete: @escaping (Note) -> Void) {
        self.folders = folders
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: note.content)
        _draftAttachments = State(initialValue: note.attachments)
        _draftFolderID = State(initialValue: note.folderID)
        _savedNote = State(initialValue: note)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty || !draftAttachments.isEmpty
    }

    private var hasChanges: Bool {
        trimmedDraft != savedNote.content
            || draftAttachments != savedNote.attachments
            || draftFolderID != savedNote.folderID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let modifiedAt = savedNote.modifiedAt, !isNew {
                Text("Edited \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .focused($isEditorFocused)
                .accessibilityLabel("Note text")

            if !draftAttachments.isEmpty {
                AttachmentStrip(attachments: $draftAttachments)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar) // a distraction-free page while writing
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ImportMenu(isPickingPhotos: $isPickingPhotos, isImportingFiles: $isImportingFiles)

                Menu {
                    if !folders.isEmpty {
                        Picker(selection: $draftFolderID) {
                            Text("No Folder").tag(UUID?.none)
                            ForEach(folders) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                        .pickerStyle(.menu)
                    }

                    Button(role: .destructive, action: { isConfirmingDelete = true }) {
                        Label("Delete Note", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }

                if isEditorFocused {
                    Button("Done") { isEditorFocused = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .attachmentImporter(isPickingPhotos: $isPickingPhotos, isImportingFiles: $isImportingFiles, attachments: $draftAttachments)
        .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Note", role: .destructive, action: deleteNote)
        }
        .onAppear {
            if isNew && draft.isEmpty {
                isEditorFocused = true
            }
        }
        // autosave on Back, on switching tabs, and when the app is closed or backgrounded
        .onDisappear(perform: saveIfChanged)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                saveIfChanged()
            }
        }
    }

    private func saveIfChanged() {
        // an emptied-out note keeps its last saved version rather than being saved blank,
        // and a new note isn't saved at all until it has something in it
        guard !isDeleted, hasChanges, canSave else { return }

        // remove the files of attachments taken out of the note
        let keptIDs = Set(draftAttachments.map(\.id))
        DataManager.shared.deleteFiles(for: savedNote.attachments.filter { !keptIDs.contains($0.id) })

        var updatedNote = savedNote
        updatedNote.content = trimmedDraft
        updatedNote.attachments = draftAttachments
        updatedNote.folderID = draftFolderID
        updatedNote.modifiedAt = Date()
        savedNote = updatedNote
        onSave(updatedNote) // pass the updated note to the callback
    }

    private func deleteNote() {
        isDeleted = true // skip the autosave on the way out
        DataManager.shared.deleteFiles(for: savedNote.attachments + draftAttachments)
        onDelete(savedNote)
        dismiss()
    }
}

// MARK: - Manage Folders View
struct ManageFoldersView: View {
    @Binding var folders: [Folder]
    let notes: [Note]
    @Environment(\.dismiss) private var dismiss

    @State private var isRenaming: Bool = false
    @State private var renamingFolderID: UUID?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders) { folder in
                    Button(action: {
                        renamingFolderID = folder.id
                        renameText = folder.name
                        isRenaming = true
                    }) {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            Text("\(notes.filter { $0.folderID == folder.id }.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    .accessibilityHint("Renames the folder")
                }
                .onDelete { folders.remove(atOffsets: $0) }
                .onMove { folders.move(fromOffsets: $0, toOffset: $1) }
            }
            .overlay {
                if folders.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder", description: Text("Create one from the Folders menu."))
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Tap a folder to rename it. Deleting a folder keeps its notes.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding()
            }
            .alert("Rename Folder", isPresented: $isRenaming) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let index = folders.firstIndex(where: { $0.id == renamingFolderID }) {
                        folders[index].name = name
                    }
                }
            }
        }
    }
}

// MARK: - Import Menu
// the pickers this opens are attached with .attachmentImporter
struct ImportMenu: View {
    @Binding var isPickingPhotos: Bool
    @Binding var isImportingFiles: Bool

    var body: some View {
        Menu {
            Button(action: { isPickingPhotos = true }) {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button(action: { isImportingFiles = true }) {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Label("Import", systemImage: "paperclip")
        }
    }
}

// MARK: - Attachment Importer
struct AttachmentImporter: ViewModifier {
    @Binding var isPickingPhotos: Bool
    @Binding var isImportingFiles: Bool
    @Binding var attachments: [Attachment]

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, matching: .images)
            .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        do {
                            attachments.append(try DataManager.shared.importFile(at: url))
                        } catch {
                            importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                            let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            attachments.append(try DataManager.shared.importImage(data: data, fileExtension: fileExtension))
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                    photoItems = []
                }
            }
            .alert("Couldn't import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
    }
}

extension View {
    func attachmentImporter(isPickingPhotos: Binding<Bool>, isImportingFiles: Binding<Bool>, attachments: Binding<[Attachment]>) -> some View {
        modifier(AttachmentImporter(isPickingPhotos: isPickingPhotos, isImportingFiles: isImportingFiles, attachments: attachments))
    }
}

// MARK: - Attachment Strip
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]
    @State private var previewURL: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    Button(action: {
                        previewURL = DataManager.shared.url(for: attachment)
                    }) {
                        AttachmentThumbnail(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.fileName)
                    .accessibilityHint("Opens a preview")
                    .overlay(alignment: .topTrailing) {
                        Button(action: {
                            attachments.removeAll { $0.id == attachment.id }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .padding(6)
                                // full-size tap area while the icon stays small
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Remove \(attachment.fileName)")
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
    }
}

// MARK: - Attachment Thumbnail
struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 80
    var showsName: Bool = true // file names under non-image thumbnails
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: attachment.isImage ? .fill : .fit)
                } else {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                        .font(size > 60 ? .title : .body)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: size, height: size)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 12 : 8, style: .continuous))

            if showsName && !attachment.isImage {
                Text(attachment.fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
            }
        }
        .task(id: attachment.id) {
            // QuickLook draws photo thumbnails and document icons/previews alike
            let request = QLThumbnailGenerator.Request(
                fileAt: DataManager.shared.url(for: attachment),
                size: CGSize(width: size, height: size),
                scale: displayScale,
                representationTypes: .all
            )
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}

// MARK: - ReminderStore
// shared so notification actions (handled in AppDelegate) and RemindersView see the same reminders
@Observable
final class ReminderStore {
    static let shared = ReminderStore()

    static let notificationCategory = "REMINDER"
    static let doneAction = "MARK_DONE"
    static let snoozeAction = "SNOOZE"
    static let snoozeMinutes = 10

    private(set) var reminders: [Reminder] = DataManager.shared.loadReminders()

    private init() {}

    func add(_ reminder: Reminder) {
        reminders.append(reminder)
        save()
        scheduleNotification(for: reminder)
    }

    func update(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        save()
        scheduleNotification(for: reminder)
    }

    func delete(ids: Set<UUID>) {
        // cancel the pending notifications so deleted reminders don't still fire
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ids.flatMap { [$0.uuidString, snoozeIdentifier(for: $0)] }
        )
        reminders.removeAll { ids.contains($0.id) }
        save()
    }

    func toggleDone(id: UUID) {
        guard let reminder = reminders.first(where: { $0.id == id }) else { return }
        if reminder.isCompleted {
            markNotDone(id: id)
        } else {
            markDone(id: id)
        }
    }

    func markDone(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].markDone()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [snoozeIdentifier(for: id)])
        save()
        scheduleNotification(for: reminders[index])
    }

    func markNotDone(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].markNotDone()
        save()
        scheduleNotification(for: reminders[index])
    }

    // notify again in a few minutes without changing the due date
    func snooze(id: UUID) {
        guard let reminder = reminders.first(where: { $0.id == id }), !reminder.isCompleted else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Self.snoozeMinutes * 60), repeats: false)
        addNotification(identifier: snoozeIdentifier(for: id), reminder: reminder, trigger: trigger)
    }

    // brings every notification in line with the saved reminders, e.g. after an update to the app,
    // or once a repeating reminder's start date has passed and it can switch to a repeating notification
    func rescheduleAllNotifications() {
        for reminder in reminders {
            scheduleNotification(for: reminder)
        }
    }

    // reminder id for a notification, which is the reminder's id or its snooze id
    static func reminderID(fromNotificationIdentifier identifier: String) -> UUID? {
        UUID(uuidString: identifier.components(separatedBy: ".").first ?? "")
    }

    private func snoozeIdentifier(for id: UUID) -> String {
        "\(id.uuidString).snooze"
    }

    private func save() {
        DataManager.shared.saveReminders(reminders: reminders)
    }

    private func scheduleNotification(for reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
        guard let trigger = reminder.notificationTrigger() else { return }
        addNotification(identifier: reminder.id.uuidString, reminder: reminder, trigger: trigger)
    }

    private func addNotification(identifier: String, reminder: Reminder, trigger: UNNotificationTrigger) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = reminder.content
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory // adds the Done and Snooze buttons

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error setting the reminder: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - RemindersView
struct RemindersView: View {
    private let store = ReminderStore.shared
    @State private var isAddingReminder: Bool = false
    @State private var editingReminder: Reminder?

    private var sections: [(title: String, reminders: [Reminder])] {
        let calendar = Calendar.current
        let now = Date()
        let open = store.reminders.filter { !$0.isCompleted }

        let today = open
            .filter { calendar.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }
        let upcoming = open
            .filter { !calendar.isDateInToday($0.date) && $0.date > now }
            .sorted { $0.date < $1.date }
        let past = open
            .filter { !calendar.isDateInToday($0.date) && $0.date < now }
            .sorted { $0.date > $1.date }
        let completed = store.reminders
            .filter(\.isCompleted)
            .sorted { ($0.completedAt ?? $0.date) > ($1.completedAt ?? $1.date) }

        return [("Today", today), ("Upcoming", upcoming), ("Past", past), ("Completed", completed)]
            .filter { !$0.reminders.isEmpty }
    }

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.reminders) { reminder in
                        row(for: reminder)
                    }
                    .onDelete { offsets in
                        store.delete(ids: Set(offsets.map { section.reminders[$0].id }))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if store.reminders.isEmpty {
                ContentUnavailableView(
                    "No Reminders",
                    systemImage: "alarm",
                    description: Text("Tap + to add one.")
                )
            }
        }
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { isAddingReminder = true }) {
                    Label("Add reminder", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingReminder) {
            ReminderEditorView(reminder: nil, onSave: store.add)
        }
        .sheet(item: $editingReminder) { reminder in
            ReminderEditorView(reminder: reminder, onSave: store.update)
        }
    }

    private func row(for reminder: Reminder) -> some View {
        HStack {
            Button(action: { store.toggleDone(id: reminder.id) }) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(reminder.isCompleted ? .accentColor : .secondary)
                    .frame(width: 44, height: 44) // full-size tap area
                    .contentShape(Rectangle())
            }
            // plain style keeps this button and the row's edit button from firing together
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isCompleted ? "Mark \(reminder.content) as not done" : "Mark \(reminder.content) as done")

            Button(action: { editingReminder = reminder }) {
                VStack(alignment: .leading) {
                    Text(reminder.content)
                        .font(.body)
                        .strikethrough(reminder.isCompleted)
                        .foregroundColor(reminder.isCompleted ? .secondary : .primary)

                    HStack(spacing: 8) {
                        // say "Overdue" in words too, so it isn't conveyed by color alone
                        Text(dateText(for: reminder))
                            .foregroundColor(reminder.isOverdue ? .red : .secondary)

                        if reminder.repeatRule != .never {
                            Text("\(Image(systemName: "repeat")) \(reminder.repeatRule.title)")
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Repeats \(reminder.repeatRule.title.lowercased())")
                        }
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Edits the reminder")
        }
    }

    private func dateText(for reminder: Reminder) -> String {
        if reminder.isCompleted, let completedAt = reminder.completedAt {
            return "Done \(completedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        let calendar = Calendar.current
        let formatted = calendar.isDateInToday(reminder.date)
            ? reminder.date.formatted(date: .omitted, time: .shortened)
            : reminder.date.formatted(date: .abbreviated, time: .shortened)
        return reminder.isOverdue ? "Overdue: \(formatted)" : formatted
    }
}

// MARK: - Reminder Editor View
struct ReminderEditorView: View {
    let original: Reminder? // nil when creating a new reminder
    var onSave: (Reminder) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var date: Date
    @State private var repeatRule: RepeatRule
    @State private var showPastDateAlert: Bool = false
    @FocusState private var isTitleFocused: Bool

    init(reminder: Reminder?, onSave: @escaping (Reminder) -> Void) {
        self.original = reminder
        self.onSave = onSave
        _title = State(initialValue: reminder?.content ?? "")
        _date = State(initialValue: reminder?.date ?? Self.nextWholeMinute())
        _repeatRule = State(initialValue: reminder?.repeatRule ?? .never)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        guard let original = original else { return !trimmedTitle.isEmpty }
        return trimmedTitle != original.content || date != original.date || repeatRule != original.repeatRule
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .focused($isTitleFocused)
                    .submitLabel(.done)

                DatePicker("Date & Time", selection: $date, displayedComponents: [.date, .hourAndMinute])

                Picker("Repeat", selection: $repeatRule) {
                    ForEach(RepeatRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
            }
            .navigationTitle(original == nil ? "New Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Add" : "Save", action: save)
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .alert("Pick a time in the future", isPresented: $showPastDateAlert) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                if original == nil {
                    isTitleFocused = true
                }
            }
        }
        // swiping the sheet away would silently lose changes, so require Cancel or Save
        .interactiveDismissDisabled(hasChanges)
    }

    private func save() {
        // notifications fire on the minute, so drop any seconds the picker carried over
        let fireDate = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date

        // new or rescheduled reminders need a future time; an overdue one can keep its date
        if fireDate != original?.date && fireDate <= Date() {
            showPastDateAlert = true
            return
        }

        var reminder = original ?? Reminder(content: trimmedTitle, date: fireDate)
        reminder.content = trimmedTitle
        reminder.date = fireDate
        reminder.repeatRule = repeatRule
        onSave(reminder)
        dismiss()
    }

    // start from the next whole minute rather than a time that's already passed
    private static func nextWholeMinute() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let startOfMinute = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        return calendar.date(byAdding: .minute, value: 1, to: startOfMinute) ?? now
    }
}
