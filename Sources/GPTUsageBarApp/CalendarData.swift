import AppKit
import EventKit
import Foundation

struct ChineseHolidayYear: Codable {
    let year: Int
    let papers: [String]
    let days: [ChineseHoliday]
}

struct ChineseHoliday: Codable {
    let name: String
    let date: String
    let isOffDay: Bool
}

enum CalendarEventCreationError: LocalizedError {
    case accessDenied
    case noDefaultCalendar
    case emptyTitle
    case invalidTimeRange

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "请在系统设置中允许 AmazeyinBar 访问日历。"
        case .noDefaultCalendar:
            return "没有可写入的默认日历，请先在系统日历中设置默认日历。"
        case .emptyTitle:
            return "请输入日程标题。"
        case .invalidTimeRange:
            return "结束时间必须晚于开始时间。"
        }
    }
}

enum CalendarDateInfo {
    static let locale = Locale(identifier: "zh_CN")
    static let chineseTimezone = TimeZone(identifier: "Asia/Shanghai")!
    static let termNames = [
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
        "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    ]
    private static let termMinutes = [
        0, 21208, 42467, 63836, 85337, 107014, 128867, 150921, 173149, 195551, 218072, 240693,
        263343, 285989, 308563, 331033, 353350, 375494, 397447, 419210, 440795, 462224, 483532, 504758,
    ]
    private static let lunarDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    private static let lunarMonths = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
    private static let solarFestivals = [
        "01-01": "元旦", "02-14": "情人节", "05-01": "劳动节", "06-01": "儿童节",
        "03-08": "妇女节", "09-10": "教师节", "10-01": "国庆节", "10-31": "万圣节", "12-25": "圣诞节",
    ]
    private static let lunarFestivals = [
        "1-1": "春节", "1-15": "元宵节", "5-5": "端午节", "7-7": "七夕", "8-15": "中秋节", "9-9": "重阳节", "12-8": "腊八节",
    ]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func statusDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        guard let month = parts.month, let day = parts.day, let weekday = parts.weekday,
              (1...7).contains(weekday) else { return "日历" }
        return "\(month)月\(day)日 周\(weekdays[weekday - 1])"
    }

    private static func chineseDate(for date: Date) -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chineseTimezone
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? date
    }

    static func lunarText(for date: Date) -> String {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = chineseTimezone
        let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: chineseDate(for: date))
        guard let month = parts.month, let day = parts.day, (1...12).contains(month), (1...30).contains(day) else { return "" }
        if day == 1 {
            return (parts.isLeapMonth == true ? "闰" : "") + lunarMonths[month - 1]
        }
        return lunarDays[day - 1]
    }

    static func lunarFullText(for date: Date) -> String {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = chineseTimezone
        let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: chineseDate(for: date))
        guard let month = parts.month, let day = parts.day, (1...12).contains(month), (1...30).contains(day) else { return "" }
        let gregorian = Calendar.current.dateComponents([.year, .month], from: date)
        let year = (gregorian.year ?? 0) - ((gregorian.month ?? 0) <= 2 && month >= 11 ? 1 : 0)
        let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
        let cycle = year - 4
        return "\(stems[(cycle % 10 + 10) % 10])\(branches[(cycle % 12 + 12) % 12])年 \(parts.isLeapMonth == true ? "闰" : "")\(lunarMonths[month - 1])\(lunarDays[day - 1])"
    }

    static func festival(for date: Date) -> String? {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        if let fixed = solarFestivals[String(format: "%02d-%02d", month, day)] { return fixed }
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = chineseTimezone
        let lunarParts = lunar.dateComponents([.month, .day, .isLeapMonth], from: chineseDate(for: date))
        guard lunarParts.isLeapMonth != true, let lunarMonth = lunarParts.month, let lunarDay = lunarParts.day else { return nil }
        return lunarFestivals["\(lunarMonth)-\(lunarDay)"]
    }

    static func solarTerm(for date: Date) -> String? {
        let year = Calendar.current.component(.year, from: date)
        guard (1900...2100).contains(year) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = utc.date(from: DateComponents(year: 1900, month: 1, day: 5, hour: 18, minute: 5))!
        var chineseGregorian = Calendar(identifier: .gregorian)
        chineseGregorian.timeZone = chineseTimezone
        for (index, minutes) in termMinutes.enumerated() {
            var instant = base.addingTimeInterval(Double(year - 1900) * 31_556_925.9747 + Double(minutes) * 60)
            let targetLongitude = Double((285 + index * 15) % 360)
            for _ in 0..<5 {
                let error = (solarLongitude(at: instant) - targetLongitude + 540).truncatingRemainder(dividingBy: 360) - 180
                instant = instant.addingTimeInterval(-error * (365.2422 * 86_400 / 360))
            }
            if dayKey(instant, calendar: chineseGregorian) == dayKey(date) { return termNames[index] }
        }
        return nil
    }

    private static func solarLongitude(at date: Date) -> Double {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let centuries = (julianDay - 2_451_545) / 36_525
        let meanLongitude = 280.46646 + centuries * (36_000.76983 + centuries * 0.0003032)
        let meanAnomaly = (357.52911 + centuries * (35_999.05029 - centuries * 0.0001537)) * .pi / 180
        let equation = (1.914602 - centuries * (0.004817 + 0.000014 * centuries)) * sin(meanAnomaly)
            + (0.019993 - 0.000101 * centuries) * sin(2 * meanAnomaly)
            + 0.000289 * sin(3 * meanAnomaly)
        let omega = (125.04 - 1934.136 * centuries) * .pi / 180
        return (meanLongitude + equation - 0.00569 - 0.00478 * sin(omega))
            .truncatingRemainder(dividingBy: 360)
    }

    static func monthDays(containing date: Date) -> [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let weekday = calendar.component(.weekday, from: month.start)
        let leading = (weekday + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: month.start) else { return [] }
        let count = ((leading + calendar.range(of: .day, in: .month, for: date)!.count + 6) / 7) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var today = Calendar.current.startOfDay(for: .now)
    @Published var selectedDate = Calendar.current.startOfDay(for: .now) {
        didSet { loadEvents() }
    }
    @Published var displayedMonth = Calendar.current.startOfDay(for: .now) {
        didSet {
            if !Calendar.current.isDate(displayedMonth, equalTo: oldValue, toGranularity: .month) {
                loadVisibleEventDays()
            }
        }
    }
    @Published private(set) var holidays: [String: ChineseHoliday] = [:]
    @Published private(set) var events: [CalendarEventSummary] = []
    @Published private(set) var visibleEventDayKeys: Set<String> = []
    @Published private(set) var calendarAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let eventStore = EKEventStore()
    private let cacheDirectory: URL
    private var loadedYears: Set<Int> = []
    private var attemptedYears: [Int: Date] = [:]
    private var holidayRecords: [Int: ChineseHolidayYear] = [:]
    private var eventsEnabled = false
    private var nowTask: Task<Void, Never>?

    init(appSupportDirectory: URL) {
        cacheDirectory = appSupportDirectory.appendingPathComponent("holidays", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        nowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                self?.updateToday()
            }
        }
        for name in [Notification.Name("NSSystemTimeZoneDidChangeNotification"), Notification.Name("NSCalendarDayChangedNotification")] {
            NotificationCenter.default.addObserver(self, selector: #selector(timeDidChange), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(timeDidChange), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(eventsDidChange), name: .EKEventStoreChanged, object: eventStore)
        Task { await loadHolidays(around: displayedMonth) }
    }

    deinit {
        nowTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func timeDidChange(_ notification: Notification) { updateToday() }

    @objc private func eventsDidChange(_ notification: Notification) {
        loadEvents()
        loadVisibleEventDays()
    }

    func updateToday() {
        let current = Calendar.current.startOfDay(for: .now)
        guard current != today else { return }
        let wasShowingToday = Calendar.current.isDate(selectedDate, inSameDayAs: today)
        today = current
        if wasShowingToday {
            selectedDate = current
            displayedMonth = current
        }
        Task { await loadHolidays(around: current) }
    }

    func showToday() {
        updateToday()
        selectedDate = today
        displayedMonth = today
        Task { await loadHolidays(around: today) }
    }

    func changeMonth(by offset: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
        displayedMonth = next
        Task { await loadHolidays(around: next) }
    }

    func openCalendar(showEvents: Bool) async {
        updateToday()
        Task { await loadHolidays(around: displayedMonth) }
        eventsEnabled = showEvents
        guard showEvents else {
            events = []
            visibleEventDayKeys = []
            return
        }
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        if calendarAccess == .notDetermined {
            _ = try? await eventStore.requestFullAccessToEvents()
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
        }
        loadEvents()
        loadVisibleEventDays()
    }

    func refreshEvents(showEvents: Bool) {
        eventsEnabled = showEvents
        loadEvents()
        loadVisibleEventDays()
    }

    func createEvent(title: String, start: Date, end: Date, isAllDay: Bool) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw CalendarEventCreationError.emptyTitle }

        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        if calendarAccess == .notDetermined {
            _ = try await eventStore.requestFullAccessToEvents()
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
        }
        guard calendarAccess == .fullAccess || calendarAccess == .writeOnly else {
            throw CalendarEventCreationError.accessDenied
        }
        guard let defaultCalendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarEventCreationError.noDefaultCalendar
        }

        let eventStart = isAllDay ? Calendar.current.startOfDay(for: start) : start
        let eventEnd = isAllDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: eventStart) ?? eventStart
            : end
        guard eventEnd > eventStart else { throw CalendarEventCreationError.invalidTimeRange }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = defaultCalendar
        event.title = trimmedTitle
        event.startDate = eventStart
        event.endDate = eventEnd
        event.isAllDay = isAllDay
        try eventStore.save(event, span: .thisEvent)

        displayedMonth = eventStart
        selectedDate = Calendar.current.startOfDay(for: eventStart)
        loadVisibleEventDays()
    }

    func holiday(for date: Date) -> ChineseHoliday? { holidays[CalendarDateInfo.dayKey(date)] }

    func hasVisibleEvent(on date: Date) -> Bool {
        visibleEventDayKeys.contains(CalendarDateInfo.dayKey(date))
    }

    func nextHoliday(from date: Date) -> (name: String, days: Int)? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        for offset in 0..<370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if let entry = holiday(for: day), entry.isOffDay { return (entry.name, offset) }
        }
        return nil
    }

    private func loadEvents() {
        guard eventsEnabled, calendarAccess == .fullAccess else { events = []; return }
        let start = Calendar.current.startOfDay(for: selectedDate)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = eventStore.events(matching: predicate)
            .filter { $0.endDate > start && $0.startDate < end }
            .map { CalendarEventSummary(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "未命名日程", start: $0.startDate, allDay: $0.isAllDay) }
    }

    private func loadVisibleEventDays() {
        guard eventsEnabled, calendarAccess == .fullAccess else {
            visibleEventDayKeys = []
            return
        }
        let visibleDays = CalendarDateInfo.monthDays(containing: displayedMonth)
        guard let start = visibleDays.first,
              let last = visibleDays.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            visibleEventDayKeys = []
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        var dayKeys: Set<String> = []
        for event in eventStore.events(matching: predicate) where event.endDate > start && event.startDate < end {
            var day = Calendar.current.startOfDay(for: max(event.startDate, start))
            while day < event.endDate && day < end {
                dayKeys.insert(CalendarDateInfo.dayKey(day))
                guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
        }
        visibleEventDayKeys = dayKeys
    }

    private func loadHolidays(around date: Date) async {
        let year = Calendar.current.component(.year, from: date)
        for requestedYear in [year - 1, year, year + 1] where (2000...2100).contains(requestedYear) {
            if loadedYears.insert(requestedYear).inserted {
                loadCachedYear(requestedYear)
            }
            let file = cacheDirectory.appendingPathComponent("\(requestedYear).json")
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            guard age.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { continue }
            guard attemptedYears[requestedYear].map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { continue }
            attemptedYears[requestedYear] = .now
            guard let url = URL(string: "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/\(requestedYear).json") else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let record = try JSONDecoder().decode(ChineseHolidayYear.self, from: data)
                guard record.year == requestedYear else { continue }
                try data.write(to: file, options: .atomic)
                apply(record)
            } catch {
                // Keep the last verified cache when the network or a future year is unavailable.
            }
        }
    }

    private func loadCachedYear(_ year: Int) {
        let file = cacheDirectory.appendingPathComponent("\(year).json")
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(ChineseHolidayYear.self, from: data),
              record.year == year else { return }
        apply(record)
    }

    private func apply(_ record: ChineseHolidayYear) {
        holidayRecords[record.year] = record
        holidays = holidayRecords.values.reduce(into: [:]) { result, year in
            for day in year.days { result[day.date] = day }
        }
    }
}

struct CalendarEventSummary: Identifiable {
    let id: String
    let title: String
    let start: Date
    let allDay: Bool
}
