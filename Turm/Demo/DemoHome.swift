#if DEBUG
import Foundation

nonisolated struct DemoError: Error, CustomStringConvertible {
    let description: String
}

nonisolated enum DemoHome {
    // under the account's real home, since a /var path resolves through /private and would never show as ~
    static let root = (getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()) + "/Library/Caches/turm-demo"
    static let turm = root + "/Projects/turm"
    static let api = root + "/Projects/api"
    static let infra = root + "/infra"

    private struct Commit {
        let message: String
        let date: String
        let files: [String: String]
    }

    static func build() throws {
        let manager = FileManager.default
        try? manager.removeItem(atPath: root)
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
        try write(gitConfig, to: root + "/.gitconfig")
        try write(zshrc, to: root + "/.zshrc")
        try makeTurm()
        try makeAPI()
        try write(mainTerraform, to: infra + "/main.tf")
        try write(variablesTerraform, to: infra + "/variables.tf")
    }

    private static func makeTurm() throws {
        try git(["init", "-q", "-b", "main"], in: turm)
        try commit(
            Commit(message: "Add the Turm window with a single terminal pane", date: "2026-09-21T09:12:00+0000", files: [
                ".gitignore": "DerivedData/\n.build/\nxcuserdata/\n",
                "README.md": "# Turm\n\nA terminal for macOS and iOS that shows each command as a block.\n",
                "Turm/TurmApp.swift": turmApp,
                "Turm/Workspace.swift": workspaceBase,
                "Turm.xcodeproj/project.pbxproj": pbxproj,
                "Turm.xcodeproj/xcshareddata/xcschemes/Turm.xcscheme": scheme("Turm", id: id(10), product: "Turm.app"),
                "Turm.xcodeproj/xcshareddata/xcschemes/TurmiOS.xcscheme": scheme("TurmiOS", id: id(20), product: "TurmiOS.app"),
            ]),
            in: turm
        )
        try commit(
            Commit(message: "Show each command and its output as a block", date: "2026-09-24T15:40:00+0000", files: [
                "Turm/TerminalSession.swift": sessionBase,
                "TurmTests/WorkspaceTests.swift": workspaceTests,
            ]),
            in: turm
        )
        try commit(
            Commit(message: "Give each pane its own command history, so up-arrow recalls that pane's commands", date: "2026-09-29T11:05:00+0000", files: [
                "Turm/TerminalSession.swift": sessionWithHistory,
            ]),
            in: turm
        )
        try write(workspaceEdited, to: turm + "/Turm/Workspace.swift")
    }

    private static func makeAPI() throws {
        try git(["init", "-q", "-b", "main"], in: api)
        try commit(
            Commit(message: "Add the invoices endpoint", date: "2026-09-22T10:30:00+0000", files: [
                ".gitignore": "node_modules/\ndist/\n",
                "package.json": packageJSON,
                "tsconfig.build.json": "{\n  \"extends\": \"./tsconfig.json\",\n  \"exclude\": [\"**/*.test.ts\"]\n}\n",
                "src/routes/billing/invoices.ts": invoices,
                "src/lib/stripe.ts": stripeBase,
            ]),
            in: api
        )
        try git(["switch", "-q", "-c", "billing-v2"], in: api)
        try commit(
            Commit(message: "Charge invoices through the new Stripe client", date: "2026-09-30T16:20:00+0000", files: [
                "src/lib/stripe.ts": stripeNext,
            ]),
            in: api
        )
        try write(invoicesEdited, to: api + "/src/routes/billing/invoices.ts")
    }

    private static func commit(_ commit: Commit, in directory: String) throws {
        for (path, text) in commit.files {
            try write(text, to: directory + "/" + path)
        }
        try git(["add", "-A"], in: directory)
        try git(["commit", "-q", "-m", commit.message], in: directory, date: commit.date)
    }

    private static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func git(_ arguments: [String], in directory: String, date: String? = nil) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = [
            "HOME": root, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Demo", "GIT_AUTHOR_EMAIL": "demo@example.com",
            "GIT_COMMITTER_NAME": "Demo", "GIT_COMMITTER_EMAIL": "demo@example.com",
        ]
        if let date {
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DemoError(description: "git \(arguments.joined(separator: " ")) failed in \(directory)")
        }
    }

    private static func id(_ number: Int) -> String {
        "D" + String(format: "%023ld", number)
    }

    private static let gitConfig = """
        [user]
        \tname = Demo
        \temail = demo@example.com
        [init]
        \tdefaultBranch = main
        [core]
        \tpager = cat

        """

    private static func scheme(_ name: String, id: String, product: String) -> String {
        let reference = """
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "\(id)" BuildableName = "\(product)" BlueprintName = "\(name)" ReferencedContainer = "container:Turm.xcodeproj">
            </BuildableReference>
        """
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme LastUpgradeVersion = "2700" version = "1.7">
               <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
                  <BuildActionEntries>
                     <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                        \(reference)
                     </BuildActionEntry>
                  </BuildActionEntries>
               </BuildAction>
               <LaunchAction buildConfiguration = "Debug" launchStyle = "0" useCustomWorkingDirectory = "NO">
                  <BuildableProductRunnable runnableDebuggingMode = "0">
                     \(reference)
                  </BuildableProductRunnable>
               </LaunchAction>
            </Scheme>

            """
    }

    private static func target(_ name: String, base: Int, sdk: String, platforms: String) -> String {
        let settings = "SDKROOT = \(sdk); SUPPORTED_PLATFORMS = \"\(platforms)\"; PRODUCT_NAME = \(name);"
        return """
                \(id(base)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(base + 1)); name = \(name); productName = \(name); productType = "com.apple.product-type.application"; };
                \(id(base + 1)) = {isa = XCConfigurationList; buildConfigurations = (\(id(base + 2)), \(id(base + 3))); defaultConfigurationName = Release; };
                \(id(base + 2)) = {isa = XCBuildConfiguration; buildSettings = {\(settings)}; name = Debug; };
                \(id(base + 3)) = {isa = XCBuildConfiguration; buildSettings = {\(settings)}; name = Release; };
        """
    }

    private static let pbxproj = """
        // !$*UTF8*!
        {
            archiveVersion = 1;
            classes = {};
            objectVersion = 77;
            objects = {
                \(id(1)) = {isa = PBXProject; buildConfigurationList = \(id(2)); compatibilityVersion = "Xcode 14.0"; targets = (\(id(10)), \(id(20))); };
                \(id(2)) = {isa = XCConfigurationList; buildConfigurations = (\(id(3)), \(id(4))); defaultConfigurationName = Release; };
                \(id(3)) = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
                \(id(4)) = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
        \(target("Turm", base: 10, sdk: "macosx", platforms: "macosx"))
        \(target("TurmiOS", base: 20, sdk: "iphoneos", platforms: "iphoneos iphonesimulator"))
            };
            rootObject = \(id(1));
        }

        """

    private static let turmApp = """
        import SwiftUI

        @main
        struct TurmApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        """

    private static let workspaceBase = """
        import Foundation

        final class Workspace {
            private(set) var sessions: [TerminalSession] = []

            func newShell(directory: String) {
                sessions.append(TerminalSession(directory: directory))
            }
        }

        """

    private static let workspaceEdited = """
        import Foundation

        final class Workspace {
            private(set) var sessions: [TerminalSession] = []
            private(set) var focused: TerminalSession?

            func newShell(directory: String) {
                let session = TerminalSession(directory: directory)
                sessions.append(session)
                focused = session
            }

            func close(_ session: TerminalSession) {
                sessions.removeAll { $0 === session }
                if focused === session { focused = sessions.last }
            }
        }

        """

    private static let sessionBase = """
        import Foundation

        final class TerminalSession {
            private(set) var blocks: [Block] = []
            let directory: String

            init(directory: String) {
                self.directory = directory
            }

            func submit(_ command: String) {
                blocks.append(Block(command: command, directory: directory))
            }
        }

        """

    private static let sessionWithHistory = """
        import Foundation

        final class TerminalSession {
            private(set) var blocks: [Block] = []
            let directory: String
            let history = CommandHistory()

            init(directory: String) {
                self.directory = directory
            }

            func submit(_ command: String) {
                blocks.append(Block(command: command, directory: directory))
                history.record(command)
            }
        }

        """

    private static let workspaceTests = """
        import Testing

        struct WorkspaceTests {
            @Test func newShellStartsInTheGivenDirectory() {
                let workspace = Workspace()
                workspace.newShell(directory: "/tmp")
                #expect(workspace.sessions.first?.directory == "/tmp")
            }
        }

        """

    private static let packageJSON = """
        {
          "name": "api",
          "version": "2.4.0",
          "private": true,
          "scripts": {
            "build": "tsc -p tsconfig.build.json && vite build",
            "test": "vitest run"
          }
        }

        """

    private static let invoices = """
        import { Router } from "express";
        import { listInvoices } from "../../lib/stripe";

        export const invoices = Router();

        invoices.get("/", async (request, response) => {
          response.json(await listInvoices(request.query.customer as string));
        });

        """

    private static let invoicesEdited = """
        import { Router } from "express";
        import { listInvoices } from "../../lib/stripe";

        export const invoices = Router();

        invoices.get("/", async (request, response) => {
          const customer = request.query.customer as string;
          if (!customer) {
            response.status(400).json({ error: "customer is required" });
            return;
          }
          response.json(await listInvoices(customer));
        });

        """

    private static let stripeBase = """
        import Stripe from "stripe";

        const client = new Stripe(process.env.STRIPE_KEY ?? "");

        export async function listInvoices(customer: string) {
          return (await client.invoices.list({ customer })).data;
        }

        """

    private static let stripeNext = """
        import Stripe from "stripe";

        const client = new Stripe(process.env.STRIPE_KEY ?? "", { apiVersion: "2024-06-20" });

        export async function listInvoices(customer: string) {
          const page = await client.invoices.list({ customer, limit: 50 });
          return page.data;
        }

        """

    private static let mainTerraform = """
        resource "aws_s3_bucket" "assets" {
          bucket = "acme-assets-prod"
        }

        resource "aws_cloudfront_distribution" "cdn" {
          enabled             = true
          default_root_object = "app.html"
        }

        """

    private static let variablesTerraform = """
        variable "region" {
          type    = string
          default = "eu-west-1"
        }

        """

    private static let zshrc = #"""
        export GIT_PAGER=cat

        swift() {
          [[ $1 == test ]] || { command swift "$@"; return; }
          local ok=$'\e[92m✔\e[0m' name
          print -r -- "Building for debugging..."
          sleep 1
          print -r -- "[1/1] Write swift-version-4A2EBE8C6F4E83F1.txt"
          print -r -- "Build complete! (1.04s)"
          sleep 1
          for name in recordedRemoteSessionInOneChunk recordedRemoteSessionSplitAtEveryByte eventsKeepTheirPlaceBetweenOutput altScreenSwitchIsFound malformedRemoteMarkersAreNotEvents environmentWithinLimitIsDecoded; do
            print -r -- "$ok Test $name() passed after 0.014 seconds."
          done
          sleep 1
          print -r -- "$ok Suite ShellStreamParserTests passed after 0.131 seconds."
          print -r -- "$ok Test run with 6 tests in 1 suite passed after 0.131 seconds."
        }

        npm() {
          [[ $1 == run && $2 == build ]] || { command npm "$@"; return; }
          print -r -- ""
          print -r -- "> api@2.4.0 build"
          print -r -- "> tsc -p tsconfig.build.json && vite build"
          print -r -- ""
          print -r -- $'\e[36mvite v5.4.8 \e[32mbuilding for production...\e[39m'
          sleep 1
          printf 'transforming (412) \e[2msrc/routes/billing/invoices.ts\e[22m\e]9;4;1;64\a'
          sleep 86400
        }

        terraform() {
          [[ $1 == plan ]] || { command terraform "$@"; return; }
          local bold=$'\e[1m' reset=$'\e[0m' yellow=$'\e[33m'
          print -r -- "${bold}aws_cloudfront_distribution.cdn: Refreshing state... [id=E2QX7RZ1K8LMNO]${reset}"
          sleep 2
          print -r -- ""
          print -r -- "Terraform will perform the following actions:"
          print -r -- ""
          print -r -- "  ${bold}# aws_cloudfront_distribution.cdn${reset} will be ${yellow}updated in-place${reset}"
          print -r -- "  ${yellow}~${reset} resource \"aws_cloudfront_distribution\" \"cdn\" {"
          print -r -- "        id                  = \"E2QX7RZ1K8LMNO\""
          print -r -- "      ${yellow}~${reset} default_root_object = \"index.html\" ${yellow}->${reset} \"app.html\""
          print -r -- "        # (12 unchanged attributes hidden)"
          print -r -- "    }"
          print -r -- ""
          print -r -- "${bold}Plan:${reset} 0 to add, 1 to change, 0 to destroy."
        }

        """#
}
#endif
