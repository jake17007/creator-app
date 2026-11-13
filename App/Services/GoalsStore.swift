import Foundation
import Observation
import Supabase

/// The signed-in member's goals.
@MainActor
@Observable
final class GoalsStore {
    private(set) var goals: [Goal] = []
    private(set) var hasLoaded = false
    var errorMessage: String?

    var active: [Goal] { goals.filter { $0.status == .active } }
    var done: [Goal] { goals.filter { $0.status == .done } }

    private static let columns = "id, user_id, title, details, status, target_date, created_at"

    /// Loads this member's goals. The filter matters for the creator account,
    /// which is allowed to read every member's goals.
    func load(for userId: UUID) async {
        do {
            goals = try await supabase
                .from("goals")
                .select(Self.columns)
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func reset() {
        goals = []
        hasLoaded = false
        errorMessage = nil
    }

    @discardableResult
    func add(_ fields: GoalFields) async -> Bool {
        do {
            let created: Goal = try await supabase
                .from("goals")
                .insert(fields)
                .select(Self.columns)
                .single()
                .execute()
                .value
            goals.append(created)
            Analytics.event("goal_added")
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    @discardableResult
    func update(_ goal: Goal, with fields: GoalFields) async -> Bool {
        do {
            let updated: Goal = try await supabase
                .from("goals")
                .update(fields)
                .eq("id", value: goal.id.uuidString)
                .select(Self.columns)
                .single()
                .execute()
                .value
            if let index = goals.firstIndex(where: { $0.id == goal.id }) {
                goals[index] = updated
            }
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func setStatus(_ status: GoalStatus, for goal: Goal) async {
        await update(goal, with: GoalFields(
            title: goal.title, details: goal.details, status: status, targetDate: goal.targetDate))
    }

    func delete(_ goal: Goal) async {
        do {
            try await supabase.from("goals").delete().eq("id", value: goal.id.uuidString).execute()
            goals.removeAll { $0.id == goal.id }
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }
}
