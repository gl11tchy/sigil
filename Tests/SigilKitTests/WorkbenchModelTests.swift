import Foundation
import Testing

@testable import SigilKit

struct WorkbenchModelTests {
    private let api = WorkbenchProject(path: "/p/acme-api")
    private let web = WorkbenchProject(path: "/p/acme-web")

    private func task(
        _ id: String, in project: WorkbenchProject, at seconds: Double, _ process: TaskProcess = .notRunning,
        unseen: Bool = false
    ) -> WorkbenchTask {
        WorkbenchTask(
            id: id, projectID: project.id, title: id, provider: .claudeCode,
            workspace: WorkbenchWorkspace(path: project.path, kind: .projectFolder), process: process,
            conversation: .none, createdAt: Date(timeIntervalSince1970: seconds), hasUnseenFinish: unseen)
    }

    @Test func attentionComesOnlyFromEvidence() {
        func attention(_ process: TaskProcess, unseen: Bool = false) -> TaskAttention {
            task("t", in: api, at: 0, process, unseen: unseen).attention
        }
        #expect(attention(.live(.idle), unseen: true) == .finished)
        #expect(attention(.live(.idle)) == .none)
        #expect(attention(.live(.waitingForApproval)) == .needsInput)
        #expect(attention(.live(.interrupted)) == .stopped)
        #expect(attention(.live(.failed)) == .failed)
        #expect(attention(.live(.exited(code: 1))) == .failed)
        #expect(attention(.live(.exited(code: 0))) == .none)
        #expect(attention(.live(.exited(code: nil))) == .none)
        #expect(attention(.providerUnavailable(problem: "x")) == .blocked)
        #expect(attention(.workspaceMissing) == .blocked)
        // Silence, a live process or a title change never become "finished".
        #expect(attention(.live(.unknown), unseen: true) == .none)
        #expect(attention(.live(.working), unseen: true) == .none)
        #expect(attention(.live(.disconnected)) == .none)
        #expect(attention(.notRunning, unseen: true) == .none)
    }

    @Test func workspaceLabelNamesTheBranchOrTheFolder() {
        #expect(WorkbenchWorkspace(path: "/p", kind: .projectFolder).label == "project folder")
        #expect(WorkbenchWorkspace(path: "/w", kind: .worktree(branch: "sigil/ab12")).label == "sigil/ab12")
    }

    @Test func railKeepsProjectOrderAndCreationOrderWhateverTheActivity() {
        let tasks = [
            task("late", in: api, at: 30, .live(.working)),
            task("early", in: api, at: 10, .live(.idle), unseen: true),
            task("web", in: web, at: 5, .live(.failed)),
        ]
        let rail = WorkbenchRail(projects: [web, api], tasks: tasks, filter: .all)
        #expect(rail.sections.map(\.project.id) == [web.id, api.id])
        #expect(rail.taskIDs == ["web", "early", "late"])

        var changed = tasks
        changed[0].process = .live(.idle)
        changed[0].hasUnseenFinish = true
        changed[1].process = .live(.working)
        #expect(WorkbenchRail(projects: [web, api], tasks: changed, filter: .all).taskIDs == rail.taskIDs)
    }

    @Test func equalCreationTimesFallBackToTheID() {
        let tasks = [task("b", in: api, at: 1), task("a", in: api, at: 1)]
        #expect(WorkbenchRail(projects: [api], tasks: tasks, filter: .all).taskIDs == ["a", "b"])
    }

    @Test func needsYouFilterHidesRowsAndEmptySectionsWithoutReordering() {
        let tasks = [
            task("a1", in: api, at: 1, .live(.working)),
            task("a2", in: api, at: 2, .live(.waitingForApproval)),
            task("a3", in: api, at: 3, .live(.idle), unseen: true),
            task("w1", in: web, at: 4, .live(.working)),
        ]
        let all = WorkbenchRail(projects: [api, web], tasks: tasks, filter: .all)
        let needing = WorkbenchRail(projects: [api, web], tasks: tasks, filter: .needsYou)
        #expect(all.attentionCount == 2)
        #expect(needing.attentionCount == 2)
        #expect(needing.taskIDs == ["a2", "a3"])
        #expect(needing.sections.map(\.project.id) == [api.id])
        #expect(needing.sections.first?.total == 3)
        #expect(needing.sections.first?.attentionCount == 2)
    }

    @Test func projectsWithoutTasksStayUnderAll() {
        let rail = WorkbenchRail(projects: [api, web], tasks: [task("a", in: api, at: 1)], filter: .all)
        #expect(rail.sections.map(\.project.id) == [api.id, web.id])
        #expect(rail.sections.last?.tasks.isEmpty == true)
        #expect(!rail.isEmpty)
        #expect(WorkbenchRail(projects: [api], tasks: [], filter: .all).isEmpty)
    }

    @Test func aTaskOutsideTheListedProjectsStillGetsASection() {
        let stray = task("stray", in: WorkbenchProject(path: "/p/stray"), at: 1)
        let rail = WorkbenchRail(projects: [api], tasks: [stray], filter: .all)
        #expect(rail.sections.map(\.project.id) == [api.id, "/p/stray"])
        #expect(rail.sections.last?.project.name == "stray")
    }

    @Test func movingClampsAtTheEndsAndStartsFromAnEdge() {
        let tasks = [task("a", in: api, at: 1), task("b", in: api, at: 2), task("c", in: web, at: 3)]
        let rail = WorkbenchRail(projects: [api, web], tasks: tasks, filter: .all)
        #expect(rail.move(from: "a", by: 1) == "b")
        #expect(rail.move(from: "b", by: 1) == "c")
        #expect(rail.move(from: "c", by: 1) == "c")
        #expect(rail.move(from: "a", by: -1) == "a")
        #expect(rail.move(from: nil, by: 1) == "a")
        #expect(rail.move(from: "gone", by: -1) == "c")
        #expect(WorkbenchRail(projects: [], tasks: [], filter: .all).move(from: nil, by: 1) == nil)
    }

    @Test func nextNeedingAttentionWrapsInRailOrder() {
        let tasks = [
            task("a", in: api, at: 1, .live(.failed)),
            task("b", in: api, at: 2, .live(.working)),
            task("c", in: web, at: 3, .live(.waitingForApproval)),
        ]
        let rail = WorkbenchRail(projects: [api, web], tasks: tasks, filter: .all)
        #expect(rail.nextNeedingAttention(after: nil) == "a")
        #expect(rail.nextNeedingAttention(after: "a") == "c")
        #expect(rail.nextNeedingAttention(after: "b") == "c")
        #expect(rail.nextNeedingAttention(after: "c") == "a")
        let calm = WorkbenchRail(projects: [api], tasks: [task("x", in: api, at: 1)], filter: .all)
        #expect(calm.nextNeedingAttention(after: "x") == nil)
    }
}

struct WorkbenchColumnsTests {
    @Test func wideWindowsShowEverythingAtPreferredWidths() {
        let columns = WorkbenchColumns(width: 1680, showsRail: true, showsReview: true)
        #expect(columns.rail == WorkbenchColumns.railDefault)
        #expect(columns.review == WorkbenchColumns.reviewDefault)
        #expect(columns.screen == 1680 - 248 - 340 - 20)
        #expect(!columns.railYieldedToReview)
    }

    @Test func columnsShrinkToTheirMinimumsBeforeAnythingHides() {
        // 200 + 300 + 480 + 20 = 1000 is the smallest width that fits all three.
        let columns = WorkbenchColumns(width: 1000, showsRail: true, showsReview: true)
        #expect(columns.rail == 200)
        #expect(columns.review == 300)
        #expect(columns.screen == WorkbenchColumns.terminalMinimum)
    }

    @Test func anOpenReviewTakesTheRailsRoomWhenAllThreeCannotFit() {
        let columns = WorkbenchColumns(width: 900, showsRail: true, showsReview: true)
        #expect(columns.rail == nil)
        #expect(columns.review != nil)
        #expect(columns.railYieldedToReview)
        #expect(columns.screen >= WorkbenchColumns.terminalMinimum)
    }

    @Test func aDefaultReviewGivesWayToTheRail() {
        let narrow = WorkbenchColumns(width: 900, showsRail: true, showsReview: true, reviewOverridesRail: false)
        #expect(narrow.rail == 248)
        #expect(narrow.review == nil)
        #expect(!narrow.railYieldedToReview)
        let wide = WorkbenchColumns(width: 1680, showsRail: true, showsReview: true, reviewOverridesRail: false)
        #expect(wide.review == WorkbenchColumns.reviewDefault)
        let noRail = WorkbenchColumns(width: 900, showsRail: false, showsReview: true, reviewOverridesRail: false)
        #expect(noRail.review != nil)
    }

    @Test func closedReviewLeavesTheRailAndTheTerminal() {
        let columns = WorkbenchColumns(width: 900, showsRail: true, showsReview: false)
        #expect(columns.rail == 248)
        #expect(columns.review == nil)
        #expect(columns.screen == 900 - 248 - 10)
    }

    @Test func theTerminalKeepsItsMinimumAtTheSmallestWindow() {
        for width in stride(from: 760.0, through: 1800, by: 20) {
            for rail in [true, false] {
                for (review, overrides) in [(true, true), (true, false), (false, true)] {
                    let columns = WorkbenchColumns(
                        width: width, showsRail: rail, showsReview: review, reviewOverridesRail: overrides)
                    #expect(columns.screen >= WorkbenchColumns.terminalMinimum, "width \(width)")
                    let used =
                        (columns.rail ?? 0) + (columns.review ?? 0) + columns.screen
                        + WorkbenchColumns.chrome(rail: columns.rail != nil, review: columns.review != nil)
                    #expect(abs(used - width) < 0.001, "width \(width)")
                }
            }
        }
    }

    @Test func outOfRangeAndNonFiniteWidthsAreClamped() {
        let columns = WorkbenchColumns(
            width: 2000, railWidth: .infinity, reviewWidth: 9000, showsRail: true, showsReview: true)
        #expect(columns.rail == WorkbenchColumns.railDefault)
        #expect(columns.review == WorkbenchColumns.reviewRange.upperBound)
        #expect(WorkbenchColumns(width: .nan, showsRail: true, showsReview: true).screen == 0)
    }
}
