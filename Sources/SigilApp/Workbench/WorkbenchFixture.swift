#if DEBUG
    import Foundation
    import SigilKit

    /// Debug-only fixtures for the workbench reference slice. Each builds real
    /// temporary Git repositories and fake CLIs that print a fixed transcript,
    /// so the workbench runs against real files and real processes without a
    /// model, a network call, or any of the user's own sessions.
    ///
    /// `SIGIL_WORKBENCH_FIXTURE=<name>` selects one at launch. Release builds do
    /// not contain this file.
    enum WorkbenchFixture: String, CaseIterable, Sendable {
        case empty
        case noTasks = "no-tasks"
        case one
        case busy
        case unavailable
        case error

        static var requested: WorkbenchFixture? {
            ProcessInfo.processInfo.environment["SIGIL_WORKBENCH_FIXTURE"].flatMap(WorkbenchFixture.init(rawValue:))
        }
    }

    /// Everything a fixture made on disk and the workbench state it starts in.
    struct WorkbenchFixtureWorld: Sendable {
        struct Launch: Sendable {
            let script: URL
        }

        let root: URL
        let projects: [WorkbenchProject]
        let tasks: [WorkbenchTask]
        /// The fake CLI each live task starts with.
        let launches: [String: Launch]
        let selectedTaskID: String?

        static let problemText = "Install Codex or check its executable path."
    }

    /// Builds a fixture world. Runs Git, so call it off the main actor.
    enum WorkbenchFixtureBuilder {
        struct Failure: Error, LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        /// `SIGIL_WORKBENCH_ROOT` puts the fixture inside an isolated home;
        /// otherwise it goes to the temporary folder.
        static func build(
            _ fixture: WorkbenchFixture, now: Date = Date(),
            parent: URL = ProcessInfo.processInfo.environment["SIGIL_WORKBENCH_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.temporaryDirectory
        ) throws -> WorkbenchFixtureWorld {
            let base =
                parent
                .appendingPathComponent("sigil-workbench-\(fixture.rawValue)-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let root = URL(fileURLWithPath: GrokPaths.canonicalPath(base.path), isDirectory: true)
            var builder = Builder(root: root, now: now)
            try builder.make(fixture)
            return WorkbenchFixtureWorld(
                root: root, projects: builder.projects, tasks: builder.tasks, launches: builder.launches,
                selectedTaskID: builder.selected)
        }

        /// The fake CLI for a task started from the workbench, with no transcript yet.
        static func blankLaunch(in root: URL, id: String, title: String) throws -> WorkbenchFixtureWorld.Launch {
            try writeScript(
                in: root, id: id,
                transcript: Transcript.header + Transcript.prompt(title) + "\n", exitCode: nil)
        }

        fileprivate static func writeScript(
            in root: URL, id: String, transcript: String, exitCode: Int32?
        ) throws -> WorkbenchFixtureWorld.Launch {
            let folder = root.appendingPathComponent("cli", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = folder.appendingPathComponent("\(id).transcript")
            try Data(transcript.utf8).write(to: text)
            let script = folder.appendingPathComponent("\(id).sh")
            var body = "#!/bin/bash\n# Sigil workbench fixture CLI: a fixed transcript. No model, no network.\n"
            body += "cat '\(text.path)'\n"
            if let exitCode {
                body += "exit \(exitCode)\n"
            } else {
                body += "printf '\\n\\033[2mfixture: input is echoed here and goes nowhere\\033[0m\\n'\n"
                body += "while IFS= read -r line; do printf '\\033[1m›\\033[0m %s\\n' \"$line\"; done\n"
            }
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return WorkbenchFixtureWorld.Launch(script: script)
        }

        private struct Builder {
            let root: URL
            let now: Date
            var projects: [WorkbenchProject] = []
            var tasks: [WorkbenchTask] = []
            var launches: [String: WorkbenchFixtureWorld.Launch] = [:]
            var selected: String?

            mutating func make(_ fixture: WorkbenchFixture) throws {
                switch fixture {
                case .empty:
                    break
                case .noTasks:
                    _ = try acmeAPI()
                    _ = try acmeWeb()
                case .one:
                    let api = try acmeAPI()
                    try rateLimiter(api)
                    selected = "rate-limiter"
                case .busy:
                    let api = try acmeAPI()
                    let web = try acmeWeb()
                    let infra = try infra()
                    try rateLimiter(api)
                    try flakyAuth(api)
                    try checkout(web, available: true)
                    try darkMode(web, waiting: true)
                    try splitState(infra)
                    try bumpNode(infra)
                    selected = "rate-limiter"
                case .unavailable:
                    let web = try acmeWeb()
                    try checkout(web, available: false)
                    try darkMode(web, waiting: false)
                    selected = "checkout"
                case .error:
                    let infra = try infra()
                    let api = try acmeAPI()
                    try splitState(infra)
                    try backfill(api)
                    selected = "split-state"
                }
            }

            // MARK: Projects

            private mutating func project(_ name: String, files: [String: String]) throws -> WorkbenchProject {
                let folder = root.appendingPathComponent("projects/\(name)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try write(files, in: folder)
                try git(["init", "-q", "-b", "main"], in: folder)
                try git(["add", "."], in: folder)
                try git(["commit", "-qm", "Initial import"], in: folder)
                let project = WorkbenchProject(path: folder.path)
                projects.append(project)
                return project
            }

            private mutating func acmeAPI() throws -> WorkbenchProject {
                try project(
                    "acme-api",
                    files: [
                        "package.json": #"{ "name": "acme-api", "scripts": { "test": "vitest" } }"# + "\n",
                        "src/routes/search.ts": """
                        import { Router } from "express";
                        import { search } from "../search";

                        export const router = Router();

                        router.get("/v2/search", async (req, res) => {
                          res.json(await search(String(req.query.q ?? "")));
                        });

                        """,
                        "src/middleware/index.ts": """
                        export { auth } from "./auth";
                        export { logging } from "./logging";

                        """,
                        "test/auth.test.ts": """
                        import { refresh } from "../src/auth";

                        test("refreshes an expiring token", () => {
                          const issued = Date.now();
                          const token = refresh({ issued, ttl: 1 });
                          expect(token.expires).toBeGreaterThan(Date.now());
                        });

                        """,
                        "README.md": "# acme-api\n\nSearch and auth service.\n",
                    ])
            }

            private mutating func acmeWeb() throws -> WorkbenchProject {
                try project(
                    "acme-web",
                    files: [
                        "package.json": #"{ "name": "acme-web", "private": true }"# + "\n",
                        "src/components/CheckoutButton.tsx": """
                        export function CheckoutButton({ onPay }: { onPay: () => void }) {
                          return <button onClick={onPay}>Pay now</button>;
                        }

                        """,
                        "src/styles/tokens.css": """
                        :root {
                          --canvas: #f1f2f3;
                          --ink: #1f2124;
                          --accent: #0285ff;
                        }

                        """,
                    ])
            }

            private mutating func infra() throws -> WorkbenchProject {
                try project(
                    "infra",
                    files: [
                        "main.tf": (1...16).map { "resource \"aws_instance\" \"app_\($0)\" { ami = \"ami-\($0)\" }" }
                            .joined(separator: "\n") + "\n",
                        "state/backend.tf": "terraform {\n  backend \"s3\" { bucket = \"acme-state\" }\n}\n",
                        "README.md": "# infra\n",
                    ])
            }

            // MARK: Tasks

            private mutating func rateLimiter(_ api: WorkbenchProject) throws {
                let workspace = try worktree(of: api, name: "7f3a2c1")
                try write(
                    [
                        "src/middleware/rateLimit.ts": """
                        const buckets = new Map<string, { tokens: number; at: number }>();

                        export function rateLimit(perSecond = 20) {
                          return (req, res, next) => {
                            const key = String(req.header("x-api-key") ?? req.ip);
                            const now = Date.now();
                            const bucket = buckets.get(key) ?? { tokens: perSecond, at: now };
                            bucket.tokens = Math.min(perSecond, bucket.tokens + ((now - bucket.at) / 1000) * perSecond);
                            bucket.at = now;
                            if (bucket.tokens < 1) return res.status(429).json({ error: "rate_limited" });
                            bucket.tokens -= 1;
                            buckets.set(key, bucket);
                            next();
                          };
                        }

                        """,
                        "src/routes/search.ts": """
                        import { Router } from "express";
                        import { search } from "../search";
                        import { rateLimit } from "../middleware/rateLimit";

                        export const router = Router();

                        router.get("/v2/search", rateLimit(20), async (req, res) => {
                          res.json(await search(String(req.query.q ?? "")));
                        });

                        """,
                        "src/middleware/index.ts": """
                        export { auth } from "./auth";
                        export { logging } from "./logging";
                        export { rateLimit } from "./rateLimit";

                        """,
                    ], in: URL(fileURLWithPath: workspace.path))
                try add(
                    id: "rate-limiter", title: "Rate limiter for /v2/search", provider: .claudeCode, project: api,
                    workspace: workspace, state: .working, conversation: .verified(sessionID: "0f9c2e71-5d4b"),
                    minute: 0, workingFor: 192, transcript: Transcript.rateLimiter)
            }

            private mutating func flakyAuth(_ api: WorkbenchProject) throws {
                try write(
                    [
                        "test/auth.test.ts": """
                        import { refresh } from "../src/auth";

                        test("refreshes an expiring token", () => {
                          vi.useFakeTimers({ now: 1_700_000_000_000 });
                          const token = refresh({ issued: Date.now(), ttl: 1 });
                          expect(token.expires).toBeGreaterThan(Date.now());
                          vi.useRealTimers();
                        });

                        """
                    ], in: URL(fileURLWithPath: api.path))
                try add(
                    id: "flaky-auth", title: "Fix flaky auth test", provider: .grokBuild, project: api,
                    workspace: WorkbenchWorkspace(path: api.path, kind: .projectFolder), state: .idle,
                    conversation: .verified(sessionID: "3b1f7a90-22c8"), minute: 1, unseen: true,
                    transcript: Transcript.flakyAuth)
            }

            private mutating func checkout(_ web: WorkbenchProject, available: Bool) throws {
                let workspace = try worktree(of: web, name: "b41e09d")
                try write(
                    [
                        "src/components/CheckoutButton.tsx": """
                        type State = "ready" | "loading" | "disabled" | "error";

                        export function CheckoutButton({ state, onPay }: { state: State; onPay: () => void }) {
                          const busy = state === "loading";
                          return (
                            <button onClick={onPay} disabled={busy || state === "disabled"} aria-busy={busy}>
                              {busy ? "Paying…" : state === "error" ? "Try again" : "Pay now"}
                            </button>
                          );
                        }

                        """,
                        "src/components/CheckoutButton.test.tsx": """
                        test("shows Paying… while loading", () => {});
                        test("offers Try again after an error", () => {});

                        """,
                    ], in: URL(fileURLWithPath: workspace.path))
                if available {
                    try add(
                        id: "checkout", title: "Checkout button states", provider: .codex, project: web,
                        workspace: workspace, state: .working, conversation: .pending, minute: 2, workingFor: 45,
                        transcript: Transcript.checkout)
                } else {
                    tasks.append(
                        WorkbenchTask(
                            id: "checkout", projectID: web.id, title: "Checkout button states", provider: .codex,
                            workspace: workspace,
                            process: .providerUnavailable(problem: WorkbenchFixtureWorld.problemText),
                            conversation: .verified(sessionID: "019a4c2e-7b11"),
                            createdAt: created(minute: 2)))
                }
            }

            private mutating func darkMode(_ web: WorkbenchProject, waiting: Bool) throws {
                let workspace = try worktree(of: web, name: "c2d5f10")
                try write(
                    [
                        "src/styles/tokens.css": """
                        :root {
                          --canvas: #f1f2f3;
                          --ink: #1f2124;
                          --accent: #0285ff;
                        }

                        @media (prefers-color-scheme: dark) {
                          :root {
                            --canvas: #1c1d1f;
                            --ink: #f2f3f4;
                            --accent: #3d9aff;
                          }
                        }

                        """
                    ], in: URL(fileURLWithPath: workspace.path))
                try add(
                    id: "dark-mode", title: "Dark mode tokens", provider: .grokBuild, project: web,
                    workspace: workspace, state: waiting ? .waitingForApproval : .idle,
                    conversation: .verified(sessionID: "8e2d4c61-0a9f"), minute: 3,
                    transcript: waiting ? Transcript.darkModeQuestion : Transcript.darkModeDone)
            }

            private mutating func splitState(_ infra: WorkbenchProject) throws {
                let folder = URL(fileURLWithPath: infra.path)
                try write(
                    [
                        "state/split.tf":
                            "module \"network\" { source = \"./network\" }\nmodule \"app\" { source = \"./app\" }\n",
                        "main.tf": (1...10).map { "resource \"aws_instance\" \"app_\($0)\" { ami = \"ami-\($0)\" }" }
                            .joined(separator: "\n") + "\nresource \"aws_subnet\" \"a\" { vpc_id = aws_vpc.core.id }\n",
                    ], in: folder)
                try git(["add", "state/split.tf"], in: folder)
                // The fake CLI exits 1, so the error arrives through the real exit path.
                try add(
                    id: "split-state", title: "Split Terraform state", provider: .grokBuild, project: infra,
                    workspace: WorkbenchWorkspace(path: infra.path, kind: .projectFolder), state: .unknown,
                    conversation: .verified(sessionID: "c47e1b02-9d3a"), minute: 4,
                    transcript: Transcript.splitState, exitCode: 1)
            }

            private mutating func bumpNode(_ infra: WorkbenchProject) throws {
                tasks.append(
                    WorkbenchTask(
                        id: "bump-node", projectID: infra.id, title: "Bump Node to 22", provider: .claudeCode,
                        workspace: WorkbenchWorkspace(path: infra.path, kind: .projectFolder), process: .notRunning,
                        conversation: .verified(sessionID: "5a0e9f13-6c27"), createdAt: created(minute: 5)))
                launches["bump-node"] = try WorkbenchFixtureBuilder.writeScript(
                    in: root, id: "bump-node", transcript: Transcript.bumpNode, exitCode: nil)
            }

            private mutating func backfill(_ api: WorkbenchProject) throws {
                let workspace = try worktree(of: api, name: "9d0b3e4")
                // The folder goes away after the task knew it: a real missing workspace.
                try FileManager.default.removeItem(atPath: workspace.path)
                tasks.append(
                    WorkbenchTask(
                        id: "backfill", projectID: api.id, title: "Search index backfill", provider: .claudeCode,
                        workspace: workspace, process: .workspaceMissing,
                        conversation: .verified(sessionID: "e81c3d57-40b2"), createdAt: created(minute: 6)))
            }

            // MARK: Helpers

            private mutating func add(
                id: String, title: String, provider: CLIProvider, project: WorkbenchProject,
                workspace: WorkbenchWorkspace, state: SessionLifecycleState, conversation: ConversationEvidence,
                minute: Int, workingFor: TimeInterval? = nil, unseen: Bool = false, transcript: String,
                exitCode: Int32? = nil
            ) throws {
                tasks.append(
                    WorkbenchTask(
                        id: id, projectID: project.id, title: title, provider: provider, workspace: workspace,
                        process: .live(state), conversation: conversation, createdAt: created(minute: minute),
                        hasUnseenFinish: unseen, workingSince: workingFor.map { now.addingTimeInterval(-$0) }))
                launches[id] = try WorkbenchFixtureBuilder.writeScript(
                    in: root, id: id, transcript: transcript, exitCode: exitCode)
            }

            private func created(minute: Int) -> Date {
                now.addingTimeInterval(TimeInterval(minute * 60 - 3600))
            }

            private func worktree(of project: WorkbenchProject, name: String) throws -> WorkbenchWorkspace {
                let folder = root.appendingPathComponent("worktrees/\(project.name)/\(name)")
                try FileManager.default.createDirectory(
                    at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                let branch = "sigil/\(name)"
                try git(
                    ["worktree", "add", "-q", "-b", branch, folder.path, "HEAD"],
                    in: URL(fileURLWithPath: project.path))
                return WorkbenchWorkspace(path: folder.path, kind: .worktree(branch: branch))
            }

            private func write(_ files: [String: String], in folder: URL) throws {
                for (path, text) in files {
                    let url = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url)
                }
            }

            /// Git with no user or system configuration and a fixed author, so
            /// the fixture never reads or writes the user's Git settings.
            private func git(_ arguments: [String], in folder: URL) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", folder.path] + arguments
                var env = ProcessInfo.processInfo.environment
                for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] { env.removeValue(forKey: key) }
                env["GIT_CONFIG_GLOBAL"] = "/dev/null"
                env["GIT_CONFIG_NOSYSTEM"] = "1"
                env["GIT_AUTHOR_NAME"] = "Sigil Fixture"
                env["GIT_AUTHOR_EMAIL"] = "fixture@sigil.invalid"
                env["GIT_COMMITTER_NAME"] = "Sigil Fixture"
                env["GIT_COMMITTER_EMAIL"] = "fixture@sigil.invalid"
                process.environment = env
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                let error = Pipe()
                process.standardError = error
                try process.run()
                let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw Failure(message: "git \(arguments.first ?? "") failed: \(message)")
                }
            }
        }
    }

    /// The fixed transcripts the fake CLIs print. They say they are fixtures.
    enum Transcript {
        private static let esc = "\u{1B}["
        static func dim(_ s: String) -> String { "\(esc)2m\(s)\(esc)0m" }
        static func bold(_ s: String) -> String { "\(esc)1m\(s)\(esc)0m" }
        static func color(_ code: Int, _ s: String) -> String { "\(esc)\(code)m\(s)\(esc)0m" }
        static func tool(_ s: String) -> String { color(36, "●") + " " + s }
        static func result(_ s: String) -> String { "  " + dim("⎿ " + s) }

        static let header = dim("fixture transcript · no model is running") + "\n\n"
        static func prompt(_ s: String) -> String { bold("> ") + s + "\n\n" }

        static let rateLimiter =
            header
            + prompt("Add a token-bucket rate limiter to /v2/search: 20 requests per second per API key.")
            + [
                tool("Read src/routes/search.ts"),
                tool("Read src/middleware/index.ts"),
                tool("Write src/middleware/rateLimit.ts"),
                result("16 lines"),
                tool("Edit src/routes/search.ts"),
                result("+2 −1"),
                tool("Run npm test -- rateLimit"),
                "  " + color(32, "⎿ PASS") + " test/rateLimit.test.ts " + dim("(4 tests)"),
                "",
                color(33, "✻") + " Running the full test suite…",
            ].joined(separator: "\n") + "\n"

        static let flakyAuth =
            header
            + prompt("The auth test fails about one run in ten. Find out why and fix it.")
            + [
                "• Ran the test 50 times: 6 failures, all in \"refreshes an expiring token\".",
                "• The test reads Date.now() twice; the token can expire between the reads.",
                "• Edited test/auth.test.ts to freeze the clock.",
                "• Ran it 200 times: 0 failures.",
                "",
                color(32, "✓") + " Turn complete.",
            ].joined(separator: "\n") + "\n"

        static let checkout =
            header
            + prompt("Give the checkout button loading, disabled and error states.")
            + [
                "• Updated src/components/CheckoutButton.tsx",
                "• Added src/components/CheckoutButton.test.tsx",
                color(33, "◦") + " Running vitest CheckoutButton…",
            ].joined(separator: "\n") + "\n"

        static let darkModeQuestion =
            header
            + prompt("Add dark mode values for every colour token.")
            + [
                "• Added dark values to src/styles/tokens.css.",
                "",
                color(33, "?") + " Apply the same values to the email templates too? They use inline styles.",
                "  1. Yes, update the templates",
                "  2. No, leave the templates",
            ].joined(separator: "\n") + "\n"

        static let darkModeDone =
            header
            + prompt("Add dark mode values for every colour token.")
            + [
                "• Added dark values to src/styles/tokens.css.",
                "",
                color(32, "✓") + " Turn complete.",
            ].joined(separator: "\n") + "\n"

        static let splitState =
            header
            + prompt("Split the Terraform state into network and app workspaces.")
            + [
                "• Wrote state/split.tf and moved resources out of main.tf.",
                "• Running terraform validate…",
                "",
                color(31, "Error:") + " Reference to undeclared resource",
                "  on main.tf line 11: aws_vpc.core is not declared in the root module.",
                "",
            ].joined(separator: "\n") + "\n"

        static let bumpNode =
            header
            + prompt("Bump Node to 22 in CI and the Dockerfile.")
            + dim("Resumed from saved history (fixture).") + "\n"
    }
#endif
