import Foundation
import NovaPorts

/// F-18 §32 item 1 (T-046u): the paid-call day counter in `UserDefaults`, so it survives app restarts.
final class DefaultsBudgetStore: BudgetStore, @unchecked Sendable {
    static let key = "paidCallBudgetDay"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> BudgetDay? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(BudgetDay.self, from: $0) }
    }

    func save(_ day: BudgetDay) {
        if let data = try? JSONEncoder().encode(day) { defaults.set(data, forKey: Self.key) }
    }
}
