import Foundation
import UserNotifications

/// Luna's bedtime reminder: the one alarm that goes to Miranda's own phone.
///
/// Everything else in Sweet Miranda deliberately keeps her phone quiet — her glucose nags go to
/// her parents instead (build 19), because an alarm at soccer embarrassed her. This is the
/// exception Wilson asked for on 2026-10-08: *"Send her an alarm the night of the pump and dexcom
/// expiring, like Luna cute dog barking at 9pm."*
///
/// It exists because both of her first two Trio pods ran to their hard stop — 4 h 50 min and
/// 7 h 13 min with no insulin at all. She changes her pod and sensor at night, so the reminder has
/// to land on the evening she can actually do something about it, in her own voice: Luna barking,
/// not a medical device alarming.
///
/// It is a date reminder and nothing else. It never names a dose, a number or a correction.
///
/// ## What gets scheduled
/// For the pod and for the sensor separately: the **last 9 pm before that device runs out**. A pod
/// that expires Saturday 10:41 pm is reminded Saturday at 9 pm; one that expires Sunday 6:41 am is
/// reminded *Saturday* at 9 pm, because that is the evening she has to act. A quieter second woof
/// follows 45 minutes later, in case the first one landed while she was in the shower.
///
/// ## Why it reschedules instead of repeating
/// Each device gets fixed request identifiers, so re-scheduling replaces rather than stacks. She
/// changes her pod *inside Trio*, which moves `pumpExpiresAtDate`, which calls `refresh` — so the
/// moment she does the change, tonight's reminder is withdrawn and the next one is set. A `nil`
/// expiry means "Trio can't reach the device right now", never "no reminder needed", so a nil is
/// left alone rather than cancelling what is already waiting.
enum SweetMirandaReminders {
    /// Her time, every time: 9 pm local, as Wilson asked.
    static let hour = 21
    /// How long after the first bark the second one comes.
    static let followUpMinutes = 45
    /// Luna's own bark, built from the desktop pet's synthesized barks (`design/luna_bark.py`).
    static let soundFile = "luna_bark.caf"

    /// Turned on by default, with a switch in Settings ▸ Features ▸ User Interface ▸ Sweet Miranda.
    static let enabledKey = "sweetMiranda.luna.reminders"

    enum Device: String, CaseIterable {
        case pod
        case sensor

        var request: String { "SweetMiranda.change.\(rawValue)" }
        var followUpRequest: String { "SweetMiranda.change.\(rawValue).again" }
    }

    // MARK: - Scheduling

    /// Re-aim both reminders at the right evening. Safe to call as often as the screen refreshes.
    static func refresh(podExpires: Date?, sensorExpires: Date?) {
        guard UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey)
        else {
            cancelAll()
            return
        }
        schedule(.pod, expires: podExpires)
        schedule(.sensor, expires: sensorExpires)
    }

    static func cancelAll() {
        let ids = Device.allCases.flatMap { [$0.request, $0.followUpRequest] }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func schedule(_ device: Device, expires: Date?) {
        // nil = Trio cannot see the device at the moment. Leave a waiting reminder in place.
        guard let expires else { return }

        let center = UNUserNotificationCenter.current()
        let ids = [device.request, device.followUpRequest]
        center.removePendingNotificationRequests(withIdentifiers: ids)

        guard let night = changeNight(before: expires) else { return }

        authorized { ok in
            guard ok else { return }
            add(device, fireAt: night, expires: expires, followUp: false)
            add(
                device,
                fireAt: night.addingTimeInterval(Double(followUpMinutes) * 60),
                expires: expires,
                followUp: true
            )
        }
    }

    /// The last 9 pm that still falls before this device runs out, and is still ahead of us.
    static func changeNight(before expires: Date, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard var night = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: expires,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .backward
        ) else { return nil }

        // `bySettingHour` can land after the expiry (a pod that dies at 6 am) — step back a night.
        if night >= expires {
            guard let earlier = calendar.date(byAdding: .day, value: -1, to: night) else { return nil }
            night = earlier
        }
        // Tonight's 9 pm already gone, or the device is already past due: the rings and her
        // parents' alerts own that case, not a bedtime reminder.
        guard night > now.addingTimeInterval(60) else { return nil }
        return night
    }

    private static func add(_ device: Device, fireAt: Date, expires: Date, followUp: Bool) {
        let content = UNMutableNotificationContent()
        content.title = followUp ? title(device).again : title(device).first
        content.body = body(device, expires: expires, followUp: followUp)
        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFile))
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "SweetMiranda.change"

        var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        parts.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)

        let id = followUp ? device.followUpRequest : device.request
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - What Luna says

    private static func title(_ device: Device) -> (first: String, again: String) {
        switch device {
        case .pod:
            return ("🐶 Woof! Pod night", "🐶 Luna again — pod night")
        case .sensor:
            return ("🐶 Woof! Sensor night", "🐶 Luna again — sensor night")
        }
    }

    private static func body(_ device: Device, expires: Date, followUp: Bool) -> String {
        let when = DateFormatter.lunaClock.string(from: expires)
        switch (device, followUp) {
        case (.pod, false):
            return String(
                format: String(localized: "Your pod runs out at %@. Change it tonight and I'll give you a high five. 🐾"),
                when
            )
        case (.pod, true):
            return String(
                format: String(localized: "Still your pod to change — it runs out at %@. Then it's done. 🐾"),
                when
            )
        case (.sensor, false):
            return String(
                format: String(localized: "Your sensor runs out at %@. Put the new one on tonight — I'll wait up. 🐾"),
                when
            )
        case (.sensor, true):
            return String(
                format: String(localized: "Still your sensor to change — it runs out at %@. Then it's done. 🐾"),
                when
            )
        }
    }

    // MARK: - Permission

    /// Trio already asks for notifications at onboarding; this only asks if nobody ever did.
    private static func authorized(_ done: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized,
                 .provisional:
                done(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in done(granted) }
            default:
                done(false)
            }
        }
    }
}

private extension DateFormatter {
    /// "10:41 PM" — her clock, not a 24-hour medical timestamp.
    static let lunaClock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
