# NoteTakingApp

A simple note-taking and reminder app built with SwiftUI. This app allows users to create, edit, and delete notes, as well as set reminders with notifications.

## Features

- **Notes:**
  - Create, edit, and delete notes.
  - View notes in a list format.
  - Persistent storage of notes using JSON encoding/decoding.
  
- **Reminders:**
  - Add reminders with custom content and time.
  - Set up local notifications to remind the user at the specified time.
  - Persistent storage of reminders using JSON encoding/decoding.
  
- **Data Persistence:**
  - Notes and reminders are stored locally in the device's document directory.

## Technologies Used

- **SwiftUI**: For building the user interface.
- **UserNotifications**: For scheduling and managing reminders with local notifications.
- **JSON**: For saving notes and reminders in the document directory.
- **FileManager**: For file handling in the local document directory.

## Requirements

- iOS 18.1 or later
- Xcode 16 or later

## Setup and Installation

1. Clone this repository to your local machine.

   ```bash
   git clone https://github.com/yourusername/NoteTakingApp.git
   ```

2. Open the project in Xcode.

3. Build and run the app on a simulator or a physical device.

4. Grant notification permissions when prompted.

## Usage

### Notes
- To create a new note, tap the compose button (✎) at the top right and start typing. The first line becomes the note's title. A new note is only saved once it has text or an attachment.
- To edit a note, tap it in the list. Edits save automatically when you go back, switch tabs, or leave the app. Tap Done to hide the keyboard.
- In a note, the paperclip adds attachments and the … menu moves the note to a folder or deletes it.
- Notes are listed with the most recently edited first, with the edit time or date under each title. Notes created before dates were tracked show no date until they're next edited.
- Use the search bar to find notes by their text or by attachment file names. Search covers the folder you're viewing.
- To delete a note, swipe left on the note and tap "Delete."
- To attach a photo or file, tap Import while creating or editing a note and choose Photo Library or Files. Tap an attachment to preview it, or tap its ✕ to remove it. Notes with attachments show a paperclip in the list.
- Attachments are copied into the app's own storage, so they stay with the note even if the original is moved or deleted.

### Folders
- Tap the folder button at the top right of Notes to switch between All Notes and a folder, create a folder, or manage folders.
- A note can be in one folder. Pick it from the … menu in the note, or long-press a note in the list and choose Move to Folder.
- New notes start in whichever folder you're viewing.
- In Manage Folders, tap a folder to rename it, swipe to delete it, or tap Edit to reorder. Deleting a folder keeps its notes; they just move out of the folder.

### Reminders
- To create a reminder, tap + at the top right, enter a title, choose a date, time, and repeat option (Never, Daily, Weekly, Monthly, Yearly), and tap Add.
- Tap a reminder to edit it. Tap its circle to mark it done; tap again to undo. Marking a repeating reminder done moves it to its next date instead.
- Reminders are grouped into Today, Upcoming, Past (overdue from earlier days), and Completed.
- A notification appears at the scheduled time, including while the app is open. Long-press it for **Mark as Done** or **Snooze 10 Minutes**.
- Deleting a reminder also cancels its pending notifications.

### Handling Notifications
The app requests notification permissions on launch. If permissions are granted, reminders trigger notifications at the specified times.

## File Structure

```
Reminder/
├── ReminderApp.swift   --- App entry point and notification setup
├── ContentView.swift   --- Models, DataManager, and all views (Notes, Edit Note, Reminders)
└── Assets.xcassets     --- App icon and colors
ReminderTests/          --- Unit tests
ReminderUITests/        --- UI tests
```

## Future Improvements
- Support for syncing data with cloud storage.
- Enhanced UI/UX improvements such as themes or better navigation.
- Add the ability to mark reminders as completed.

## License
This project is open source and available under the MIT License.

## Acknowledgements
- SwiftUI documentation
- Apple Developer resources for UserNotifications
