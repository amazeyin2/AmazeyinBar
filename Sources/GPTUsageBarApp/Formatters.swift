import Foundation

enum AppFormatters {
    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func costString(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func numberString(_ value: Int) -> String {
        decimal.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func abbreviatedNumberString(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1_000_000_000...:
            return String(format: "%.1fB", number / 1_000_000_000).replacingOccurrences(of: ".0", with: "")
        case 1_000_000...:
            return String(format: "%.1fM", number / 1_000_000).replacingOccurrences(of: ".0", with: "")
        case 1_000...:
            return String(format: "%.1fK", number / 1_000).replacingOccurrences(of: ".0", with: "")
        default:
            return numberString(value)
        }
    }

    static func countdownString(seconds: Int) -> String {
        let totalMinutes = max(seconds, 0) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h\(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }
}
