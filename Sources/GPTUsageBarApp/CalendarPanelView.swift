import EventKit
import SwiftUI

private let calendarInk = Color(red: 0.20, green: 0.22, blue: 0.24)
private let calendarBlue = Color(red: 0.10, green: 0.42, blue: 0.92)

struct CalendarPanelView: View {
    @EnvironmentObject private var store: CalendarStore
    @EnvironmentObject private var configStore: ConfigStore
    let onShowSettings: () -> Void

    private var options: CalendarDisplayOptions { configStore.config.calendarDisplay ?? CalendarDisplayOptions() }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    var body: some View {
        VStack(spacing: 7) {
            header
            weekdayHeader
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(CalendarDateInfo.monthDays(containing: store.displayedMonth), id: \.self) { date in
                    dayCell(date)
                }
            }
            selectedDayDetails
            if options.systemEvents { eventList }
        }
        .padding(.horizontal, 3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { store.changeMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            Button { store.showToday() } label: {
                Image(systemName: "circle")
            }
            Button { store.changeMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            Text(verbatim: "\(Calendar.current.component(.month, from: store.displayedMonth))月 \(Calendar.current.component(.year, from: store.displayedMonth))")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(calendarInk)
            Spacer(minLength: 0)
            if options.holidayCountdownAndWorkdays, let next = store.nextHoliday(from: store.today) {
                Text(next.days == 0 ? "今天\(next.name)" : "\(next.name) · \(next.days)天后")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .help("打开设置")
            .accessibilityLabel("打开设置")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(calendarInk)
        .padding(.vertical, 2)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(calendarInk)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let sameMonth = Calendar.current.isDate(date, equalTo: store.displayedMonth, toGranularity: .month)
        let selected = Calendar.current.isDate(date, inSameDayAs: store.selectedDate)
        let today = Calendar.current.isDate(date, inSameDayAs: store.today)
        let holiday = options.holidayCountdownAndWorkdays ? store.holiday(for: date) : nil
        let festival = options.festivalsAndTerms ? CalendarDateInfo.festival(for: date) : nil
        let term = options.festivalsAndTerms ? CalendarDateInfo.solarTerm(for: date) : nil
        let subtitle = holiday?.name ?? festival ?? term ?? (options.lunar ? CalendarDateInfo.lunarText(for: date) : "")

        return Button {
            store.selectedDate = date
            if !sameMonth { store.displayedMonth = date; store.changeMonth(by: 0) }
        } label: {
            VStack(spacing: 0) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 17, weight: today || selected ? .semibold : .regular))
                Text(subtitle)
                    .font(.system(size: 9, weight: holiday != nil ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if holiday?.isOffDay == false {
                    Text("班").font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(!sameMonth ? Color.gray : today ? calendarBlue : calendarInk)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(selected ? Color(red: 0.81, green: 0.85, blue: 0.92) : sameMonth ? Color(red: 0.88, green: 0.88, blue: 0.87) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(CalendarDateInfo.dayKey(date)) \(subtitle)")
    }

    private var selectedDayDetails: some View {
        let date = store.selectedDate
        let holiday = options.holidayCountdownAndWorkdays ? store.holiday(for: date) : nil
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        return HStack(spacing: 9) {
            VStack(alignment: .center, spacing: 1) {
                Text(date.formatted(.dateTime.locale(.init(identifier: "zh_CN")).weekday(.wide)))
                    .font(.system(size: 11))
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }
            .frame(width: 56)
            Rectangle().fill(Color.gray).frame(width: 1, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                if options.lunar {
                    Text(CalendarDateInfo.lunarFullText(for: date))
                        .font(.system(size: 12, weight: .medium))
                }
                let annotations = [
                    "第\(iso.component(.weekOfYear, from: date))周",
                    holiday.map { "\($0.name) · \($0.isOffDay ? "休" : "班")" },
                    options.festivalsAndTerms ? CalendarDateInfo.solarTerm(for: date) : nil,
                    options.festivalsAndTerms ? CalendarDateInfo.festival(for: date) : nil,
                ].compactMap { $0 }
                Text(annotations.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(calendarInk)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(red: 0.87, green: 0.87, blue: 0.86), in: RoundedRectangle(cornerRadius: 10))
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if store.calendarAccess == .fullAccess {
                Text("系统日程")
                    .font(.system(size: 11, weight: .semibold))
                if store.events.isEmpty {
                    Text("当天没有日程")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.events) { event in
                            HStack(spacing: 7) {
                                Circle().fill(calendarBlue).frame(width: 5, height: 5)
                                Text(event.allDay ? "全天" : event.start.formatted(.dateTime.hour().minute()))
                                    .foregroundStyle(.secondary)
                                Text(event.title).lineLimit(1)
                            }
                            .font(.system(size: 11))
                        }
                    }
                }
            } else {
                Text("系统日历未授权，可在系统设置中允许 AmazeyinBar 访问日历。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
    }
}

struct CalendarSettingsControls: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var calendarStore: CalendarStore
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("日历显示")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            option("系统日程", keyPath: \.systemEvents)
            option("农历", keyPath: \.lunar)
            option("节日和节气", keyPath: \.festivalsAndTerms)
            option("节假日倒计时与调休", keyPath: \.holidayCountdownAndWorkdays)
            if let saveError {
                Text(saveError).font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func option(_ title: String, keyPath: WritableKeyPath<CalendarDisplayOptions, Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(
                get: { (configStore.config.calendarDisplay ?? CalendarDisplayOptions())[keyPath: keyPath] },
                set: { enabled in
                    var options = configStore.config.calendarDisplay ?? CalendarDisplayOptions()
                    options[keyPath: keyPath] = enabled
                    do {
                        try configStore.setCalendarDisplay(options)
                        saveError = nil
                        if title == "系统日程" {
                            Task { await calendarStore.openCalendar(showEvents: enabled) }
                        }
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}
