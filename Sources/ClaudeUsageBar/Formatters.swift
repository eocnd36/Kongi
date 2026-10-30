import ClaudeUsageCore
import Foundation
import SwiftUI

enum Formatters {
    /// 앱이 실제로 표시 중인 언어 (시스템 지역 설정과 다를 수 있음)
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// `2h 5m` / `2시간 5분`
    static func countdown(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = appLocale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval >= 86400 ? [.day, .hour] : [.hour, .minute]
        return formatter.string(from: max(interval, 60)) ?? ""
    }

    static func resetDescription(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 {
            return String(localized: "Resetting now")
        }
        if remaining < 86400 {
            return String(localized: "Resets in \(countdown(remaining))")
        }
        let day = date.formatted(.dateTime.locale(appLocale).weekday(.abbreviated).hour().minute())
        return String(localized: "Resets \(day) (in \(countdown(remaining)))")
    }

    /// "이 속도면 오후 3:20에 한도 도달" (하루 이상 뒤면 요일 포함)
    static func projectionDescription(_ date: Date, now: Date) -> String {
        let style: Date.FormatStyle = date.timeIntervalSince(now) < 86400 && Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.locale(appLocale).hour().minute()
            : .dateTime.locale(appLocale).weekday(.abbreviated).hour().minute()
        return String(localized: "At this pace, you'll hit the limit at \(date.formatted(style))")
    }

    /// 예약 실행 시각: "오후 3:01 (2시간 5분 후)", 하루 넘게 남으면 날짜 포함
    static func scheduleTime(_ date: Date, now: Date) -> String {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
        let style: Date.FormatStyle = sameDay
            ? .dateTime.locale(appLocale).hour().minute()
            : .dateTime.locale(appLocale).month().day().weekday(.abbreviated).hour().minute()
        let time = date.formatted(style)
        let remaining = date.timeIntervalSince(now)
        return remaining > 60 ? String(localized: "\(time) (in \(countdown(remaining)))") : time
    }

    /// "30초", "2분" (설정 선택지용)
    static func countdownSeconds(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = appLocale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    /// "3m", "2h" 처럼 짧은 경과 시간
    static func shortElapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return String(localized: "now") }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = appLocale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? ""
    }

    /// 프로젝트 폴더 기준 상대 경로 (밖에 있으면 ~로 줄인 절대 경로)
    static func relativePath(_ path: String, in root: String) -> String {
        if !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static func updatedDescription(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 {
            return String(localized: "Updated just now")
        }
        return String(localized: "Updated \(countdown(elapsed)) ago")
    }
}

extension LimitKind {
    var title: String {
        switch self {
        case .session: return String(localized: "Current session")
        case .weekly: return String(localized: "Weekly · All models")
        case .weeklyOpus: return String(localized: "Weekly · Opus")
        case .weeklySonnet: return String(localized: "Weekly · Sonnet")
        case .weeklyCowork: return String(localized: "Weekly · Cowork")
        }
    }

    var windowLabel: String {
        switch self {
        case .session: return String(localized: "5-hour window")
        default: return String(localized: "7-day window")
        }
    }
}

extension MenuBarStyle {
    var title: String {
        switch self {
        case .sessionAndWeekly: return String(localized: "Session + weekly")
        case .sessionOnly: return String(localized: "Session only")
        case .sessionAndReset: return String(localized: "Session + reset time")
        case .iconOnly: return String(localized: "Icon only")
        case .hidden: return String(localized: "Hidden")
        }
    }
}

extension UsageSeverity {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
