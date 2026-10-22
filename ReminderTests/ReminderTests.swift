//
//  ReminderTests.swift
//  ReminderTests
//
//  Created by Zachary Allen on 1/2/25.
//

import Foundation
import Testing
import UserNotifications
@testable import Reminder

struct ReminderTests {

    @Test func noteRoundTripsThroughJSON() throws {
        let notes = [Note(content: "Groceries\nMilk"), Note(content: "Call shop")]
        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode([Note].self, from: data)
        #expect(decoded == notes)
    }

    @Test func noteWithAttachmentsRoundTripsThroughJSON() throws {
        let photo = Attachment(fileName: "Photo.jpg", storedName: "\(UUID().uuidString)/Photo.jpg")
        let pdf = Attachment(fileName: "Invoice.pdf", storedName: "\(UUID().uuidString)/Invoice.pdf")
        let notes = [Note(content: "Receipts", attachments: [photo, pdf])]
        let data = try JSONEncoder().encode(notes)
        let decoded = try JSONDecoder().decode([Note].self, from: data)
        #expect(decoded == notes)
        #expect(photo.isImage)
        #expect(!pdf.isImage)
    }

    @Test func notesSavedBeforeAttachmentsStillLoad() throws {
        let json = #"[{"id":"6F1C2D1E-6B1A-4C55-9E8B-2E3B1F0A9C11","content":"Old note"}]"#
        let decoded = try JSONDecoder().decode([Note].self, from: Data(json.utf8))
        #expect(decoded.first?.content == "Old note")
        #expect(decoded.first?.attachments.isEmpty == true)
        #expect(decoded.first?.folderID == nil)
        // real dates are unknown for old notes, so they stay empty rather than being made up
        #expect(decoded.first?.createdAt == nil)
        #expect(decoded.first?.modifiedAt == nil)
    }

    @Test func notesSortByLastEditedWithUndatedNotesLast() {
        let now = Date()
        var oldUndated = Note(content: "Oldest undated")
        oldUndated.modifiedAt = nil
        var newerUndated = Note(content: "Newer undated")
        newerUndated.modifiedAt = nil
        var editedYesterday = Note(content: "Yesterday")
        editedYesterday.modifiedAt = now.addingTimeInterval(-86_400)
        var editedNow = Note(content: "Now")
        editedNow.modifiedAt = now

        let sorted = [oldUndated, editedYesterday, newerUndated, editedNow].sortedByLastEdited()
        #expect(sorted.map(\.content) == ["Now", "Yesterday", "Newer undated", "Oldest undated"])
    }

    @Test func noteRowTitleAndPreview() {
        let pdf = Attachment(fileName: "Invoice.pdf", storedName: "\(UUID().uuidString)/Invoice.pdf")

        let twoLines = Note(content: "Brake pads\n\n  Front axle  ")
        #expect(twoLines.title == "Brake pads")
        #expect(twoLines.previewText == "Front axle") // skips blank lines and trims

        let oneLineWithFile = Note(content: "Receipts", attachments: [pdf])
        #expect(oneLineWithFile.previewText == "1 attachment")

        let fileOnly = Note(content: "", attachments: [pdf, pdf])
        #expect(fileOnly.title == "Invoice.pdf")
        #expect(fileOnly.previewText == "2 attachments")

        #expect(Note(content: "Just a title").previewText == "No additional text")
    }

    @Test func searchMatchesTextAndAttachmentNamesIgnoringCase() {
        let pdf = Attachment(fileName: "Invoice-2231.pdf", storedName: "\(UUID().uuidString)/Invoice-2231.pdf")
        let note = Note(content: "Brake pads\nFront axle", attachments: [pdf])
        #expect(note.matches("brake"))
        #expect(note.matches("AXLE"))
        #expect(note.matches("invoice"))
        #expect(!note.matches("rotor"))
    }

    @Test func noteInFolderRoundTripsThroughJSON() throws {
        let folder = Folder(name: "Work")
        let notes = [Note(content: "Quarterly numbers", folderID: folder.id), Note(content: "Unfiled")]
        let decodedNotes = try JSONDecoder().decode([Note].self, from: JSONEncoder().encode(notes))
        let decodedFolders = try JSONDecoder().decode([Folder].self, from: JSONEncoder().encode([folder]))
        #expect(decodedNotes == notes)
        #expect(decodedNotes.first?.folderID == decodedFolders.first?.id)
        #expect(decodedNotes.last?.folderID == nil)
    }

    @Test func reminderRoundTripsThroughJSON() throws {
        let reminders = [
            Reminder(content: "Oil change", date: Date(timeIntervalSince1970: 1_800_000_000)),
            Reminder(content: "Timesheet", date: Date(timeIntervalSince1970: 1_800_000_000), repeatRule: .weekly, isCompleted: true, completedAt: Date(timeIntervalSince1970: 1_800_000_500)),
        ]
        let data = try JSONEncoder().encode(reminders)
        let decoded = try JSONDecoder().decode([Reminder].self, from: data)
        #expect(decoded == reminders)
    }

    @Test func remindersSavedBeforeRepeatAndDoneStillLoad() throws {
        let json = #"[{"id":"6F1C2D1E-6B1A-4C55-9E8B-2E3B1F0A9C11","content":"Old reminder","date":800000000}]"#
        let decoded = try JSONDecoder().decode([Reminder].self, from: Data(json.utf8))
        #expect(decoded.first?.content == "Old reminder")
        #expect(decoded.first?.repeatRule == .never)
        #expect(decoded.first?.isCompleted == false)
    }

    @Test func markingOneOffReminderDoneCompletesIt() {
        let now = Date()
        var reminder = Reminder(content: "Call back", date: now.addingTimeInterval(-60))
        reminder.markDone(now: now)
        #expect(reminder.isCompleted)
        #expect(reminder.completedAt == now)

        reminder.markNotDone()
        #expect(!reminder.isCompleted)
        #expect(reminder.completedAt == nil)
    }

    @Test func markingRepeatingReminderDoneMovesToNextOccurrence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12))!

        var reminder = Reminder(content: "Daily standup", date: start, repeatRule: .daily)
        reminder.markDone(now: now, calendar: calendar)

        // the next 9:00 after noon on the 5th is the 6th, and it stays open
        #expect(reminder.date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 6, hour: 9)))
        #expect(!reminder.isCompleted)
    }

    @Test func monthlyRepeatOnThe31stDoesNotDrift() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31, hour: 8))!

        let afterJanuary = RepeatRule.monthly.nextOccurrence(after: start, from: start, calendar: calendar)
        let afterFebruary = RepeatRule.monthly.nextOccurrence(after: afterJanuary!, from: start, calendar: calendar)

        #expect(afterJanuary == calendar.date(from: DateComponents(year: 2027, month: 2, day: 28, hour: 8)))
        #expect(afterFebruary == calendar.date(from: DateComponents(year: 2027, month: 3, day: 31, hour: 8)))
    }

    @Test func notificationIdentifiersMapBackToReminders() {
        let id = UUID()
        #expect(ReminderStore.reminderID(fromNotificationIdentifier: id.uuidString) == id)
        #expect(ReminderStore.reminderID(fromNotificationIdentifier: "\(id.uuidString).snooze") == id)
        #expect(ReminderStore.reminderID(fromNotificationIdentifier: "not-a-reminder") == nil)
    }

    // the test host app registers these at launch
    @Test func reminderNotificationsOfferDoneAndSnooze() async {
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let category = categories.first { $0.identifier == ReminderStore.notificationCategory }
        #expect(category?.actions.map(\.identifier) == [ReminderStore.doneAction, ReminderStore.snoozeAction])
    }

    @Test func notificationTriggersMatchReminderState() {
        let calendar = Calendar.current
        let startOfMinute = calendar.dateInterval(of: .minute, for: Date())!.start

        // past one-off reminder: nothing to notify about
        #expect(Reminder(content: "Past", date: startOfMinute.addingTimeInterval(-3_600)).notificationTrigger() == nil)

        // future one-off reminder: a single notification
        let oneOff = Reminder(content: "Soon", date: startOfMinute.addingTimeInterval(3_600)).notificationTrigger()
        #expect(oneOff?.repeats == false)

        // daily reminder whose start is the next matching time: a repeating notification
        let daily = Reminder(content: "Daily", date: startOfMinute.addingTimeInterval(3_600), repeatRule: .daily).notificationTrigger()
        #expect(daily?.repeats == true)

        // daily reminder starting days from now: notify once on the start date instead of firing early
        let laterStart = Reminder(content: "Later", date: startOfMinute.addingTimeInterval(3 * 86_400 + 3_600), repeatRule: .daily).notificationTrigger()
        #expect(laterStart?.repeats == false)

        // completed reminder: nothing
        var done = Reminder(content: "Done", date: startOfMinute.addingTimeInterval(3_600))
        done.markDone()
        #expect(done.notificationTrigger() == nil)
    }

}
