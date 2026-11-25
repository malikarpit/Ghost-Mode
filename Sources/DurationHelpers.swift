//
//  DurationHelpers.swift
//  Ghost Mode
//

import Foundation

private enum DurationRegex {
    static let hour = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:h|hr|hrs|hours?)"#)
    static let minute = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:m|min|mins|minutes?)"#)
    static let second = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:s|sec|secs|seconds?)"#)
}

private func safeScaledSeconds(_ value: Double, factor: Double) -> Int? {
    guard value.isFinite, value >= 0 else { return nil }
    let scaled = value * factor
    guard scaled.isFinite, scaled <= Double(Int.max / 2) else { return nil }
    return Int(scaled)
}

public func parseDurationString(_ input: String) -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.isEmpty || text.contains("-") { return nil }

    var totalSeconds = 0
    var matched = false
    let range = NSRange(text.startIndex..., in: text)

    if let match = DurationRegex.hour?.firstMatch(in: text, range: range),
       let r = Range(match.range(at: 1), in: text),
       let h = Double(text[r]) {
        guard let part = safeScaledSeconds(h, factor: 3600) else { return nil }
        let (sum, overflow) = totalSeconds.addingReportingOverflow(part)
        if overflow { return nil }
        totalSeconds = sum
        matched = true
    }

    if let match = DurationRegex.minute?.firstMatch(in: text, range: range),
       let r = Range(match.range(at: 1), in: text),
       let m = Double(text[r]) {
        guard let part = safeScaledSeconds(m, factor: 60) else { return nil }
        let (sum, overflow) = totalSeconds.addingReportingOverflow(part)
        if overflow { return nil }
        totalSeconds = sum
        matched = true
    }

    if let match = DurationRegex.second?.firstMatch(in: text, range: range),
       let r = Range(match.range(at: 1), in: text),
       let s = Double(text[r]) {
        guard let part = safeScaledSeconds(s, factor: 1) else { return nil }
        let (sum, overflow) = totalSeconds.addingReportingOverflow(part)
        if overflow { return nil }
        totalSeconds = sum
        matched = true
    }

    if !matched {
        if let num = Double(text) {
            return safeScaledSeconds(num, factor: 60)
        }
        return nil
    }

    return totalSeconds
}

public func formatDurationHuman(_ seconds: Int) -> String {
    if seconds <= 0 { return "Indefinite" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 && m > 0 {
        return "\(h)h \(m)m"
    } else if h > 0 {
        return "\(h)h"
    } else if m > 0 && s > 0 && seconds < 300 {
        return "\(m)m \(s)s"
    } else if m > 0 {
        return "\(m)m"
    } else {
        return "\(s)s"
    }
}

public func formatCountdown(_ seconds: Int) -> String {
    if seconds <= 0 { return "00:00" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 {
        return String(format: "%dh %02dm %02ds", h, m, s)
    } else {
        return String(format: "%02d:%02d", m, s)
    }
}

public func formatDurationCompact(_ seconds: Int) -> String {
    if seconds <= 0 { return "0s" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 && m > 0 {
        return "\(h)h \(m)m"
    } else if h > 0 {
        return "\(h)h"
    } else if m > 0 {
        return "\(m)m"
    } else {
        return "\(s)s"
    }
}
