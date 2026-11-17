import AppKit
import SwiftUI

private struct CalendarEventEditor: View {
    @ObservedObject var store: CalendarStore
    let onClose: () -> Void

    @State private var title = ""
    @State private var start: Date
    @State private var end: Date
    @State private var isAllDay = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleIsFocused: Bool

    init(date: Date, store: CalendarStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        let calendar = Calendar.current
        let hour = calendar.isDateInToday(date) ? min(calendar.component(.hour, from: .now) + 1, 23) : 9
        let initialStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        _start = State(initialValue: initialStart)
        _end = State(initialValue: initialStart.addingTimeInterval(3_600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加日程")
                .font(.title3.weight(.semibold))

            TextField("日程标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleIsFocused)

            Toggle("全天", isOn: $isAllDay)

            if isAllDay {
                DatePicker("日期", selection: $start, displayedComponents: .date)
            } else {
                DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isAllDay && end <= start {
                Text("结束时间必须晚于开始时间。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("取消", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("添加日程") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!isAllDay && end <= start))
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { titleIsFocused = true }
        .onChange(of: start) { _, newStart in
            if end <= newStart { end = newStart.addingTimeInterval(3_600) }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.createEvent(title: title, start: start, end: end, isAllDay: isAllDay)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

@MainActor
final class CalendarEventWindowController {
    static let shared = CalendarEventWindowController()

    private var panel: NSPanel?

    func show(for date: Date, store: CalendarStore) {
        close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "添加日程"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: CalendarEventEditor(
            date: date,
            store: store,
            onClose: { [weak self] in self?.close() }
        ))
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}
