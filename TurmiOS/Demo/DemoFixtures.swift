#if targetEnvironment(simulator)
import Foundation
import TurmCore

struct DemoShell {
    let summary: SessionSummary
    let history: [BlockSummary]
    var running: RunningBlock?
}

/// Recorded terminal output behind the simulator demo; escapes are kept as the shell wrote them.
enum DemoFixtures {
    static let columns = 100
    static let rows = 30
    static let macName = "Studio"
    static let macAddresses = ["studio.local"]
    static let home = "/Users/dev"
    static let remoteHome = "/home/deploy"

    static let prodWeb = SSHHost(key: "prod-web", hostname: "prod-web.internal", user: "deploy")
    static let pi = SSHHost(key: "pi", hostname: "raspberrypi.local", user: "pi")

    static let turm: DemoShell = {
        let git = CompanionGit(branch: "main", files: 3, added: 42, removed: 9)
        return DemoShell(
            summary: summary("turm", folder: "Projects/turm", activity: .failed, branch: "main", command: "claude"),
            history: [
                block("git log --oneline -6", folder: "Projects/turm", git: git, seconds: 0.041, output: gitLog),
                block("git status -sb", folder: "Projects/turm", git: git, seconds: 0.032, output: gitStatus),
                block("ls -l Packages/TurmCore/Sources/TurmCore", folder: "Projects/turm", git: git, seconds: 0.006, output: listing),
                block("swift test --filter ShellStreamParserTests", folder: "Projects/turm", git: git, seconds: 4.81, output: swiftTest),
                block("swift build -c release", folder: "Projects/turm", git: git, exit: 1, seconds: 6.42, output: swiftBuild),
            ]
        )
    }()

    static let api: DemoShell = {
        let git = CompanionGit(branch: "billing-v2", files: 1, added: 3, removed: 1)
        return DemoShell(
            summary: summary(
                "api", folder: "Projects/api", phase: .running, activity: .progress(percent: 64), branch: "billing-v2",
                command: "npm run build"
            ),
            history: [
                block("git pull --ff-only", folder: "Projects/api", git: git, seconds: 1.21, output: gitPull),
            ],
            running: RunningBlock(
                id: UUID(), command: "npm run build", location: "~/Projects/api", bytes: npmBuild,
                directory: home + "/Projects/api", git: git
            )
        )
    }()

    static let infra: DemoShell = {
        let git = CompanionGit(branch: "main", files: 0, added: 0, removed: 0)
        return DemoShell(
            summary: summary("infra", folder: "infra", activity: .succeeded, branch: "main", command: "git push"),
            history: [
                block("terraform fmt -check -recursive", folder: "infra", git: git, seconds: 0.18, output: []),
                block("terraform plan", folder: "infra", git: git, seconds: 8.73, output: terraformPlan),
            ]
        )
    }()

    static let shells = [turm, api, infra]

    static let remoteHistory: [BlockSummary] = [
        BlockSummary(
            id: UUID(), command: "", location: "", exitCode: nil, text: plain(motd), connectedTo: prodWeb.key, styled: styled(motd)
        ),
        remote("uptime", seconds: 0.004, output: uptime),
        remote("df -h /", seconds: 0.007, output: diskFree),
        remote("docker ps --format \"table {{.Names}}\\t{{.Image}}\\t{{.Status}}\"", seconds: 0.093, output: dockerPS),
        remote("systemctl status nginx --no-pager -n 0", seconds: 0.021, output: nginxStatus),
    ]

    private static func summary(
        _ title: String, folder: String, phase: CompanionPhase = .ready, activity: CompanionActivity, branch: String,
        command: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: UUID(), title: title, location: "~/" + folder, phase: phase, activity: activity,
            branch: branch, directory: home + "/" + folder, program: command.flatMap { RunningProgram.resolve(command: $0) }
        )
    }

    private static func block(
        _ command: String, folder: String, git: CompanionGit, exit: Int32 = 0, seconds: Double, output: [String]
    ) -> BlockSummary {
        BlockSummary(
            id: UUID(), command: command, location: "~/" + folder, exitCode: exit, text: plain(output),
            directory: home + "/" + folder, git: git, duration: seconds, styled: styled(output)
        )
    }

    private static func remote(_ command: String, seconds: Double, output: [String]) -> BlockSummary {
        BlockSummary(
            id: UUID(), command: command, location: "~", exitCode: 0, text: plain(output),
            directory: remoteHome, duration: seconds, styled: styled(output)
        )
    }

    private static func styled(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func plain(_ lines: [String]) -> String {
        lines.joined(separator: "\n").replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private static let gitLog = [
        "\u{1B}[33m04d02bc\u{1B}[m\u{1B}[33m (\u{1B}[m\u{1B}[1;36mHEAD\u{1B}[m\u{1B}[33m -> \u{1B}[m\u{1B}[1;32mmain\u{1B}[m\u{1B}[33m, \u{1B}[m\u{1B}[1;31morigin/main\u{1B}[m\u{1B}[33m, \u{1B}[m\u{1B}[1;31morigin/HEAD\u{1B}[m\u{1B}[33m)\u{1B}[m Merge pull request #1 from dev/turm-ios",
        "\u{1B}[33m618cdaa\u{1B}[m Read the keychain entitlement instead of probing the data-protection keychain, which stalls for unentitled builds",
        "\u{1B}[33m32fce49\u{1B}[m Run the keychain migration off the main thread so a slow keychain cannot stall launch",
        "\u{1B}[33m4d3f915\u{1B}[m Import SwiftTerm and Network where their members are used, which Xcode 26 requires",
        "\u{1B}[33m0f44a4a\u{1B}[m Keep the project readable by Xcode 26 and build the iOS app without the iOS 27.1 SDK",
        "\u{1B}[33mcf5f316\u{1B}[m Add the Turm iOS app with Remote Access to the Mac's shells, direct SSH with Turm blocks, and optional iCloud sync",
    ]

    private static let gitStatus = [
        "## \u{1B}[32mmain\u{1B}[m...\u{1B}[31morigin/main\u{1B}[m",
        "\u{1B}[32mM\u{1B}[m  Packages/TurmCore/Sources/TurmCore/Shell/ShellEvent.swift",
        " \u{1B}[31mM\u{1B}[m TurmiOS/Blocks/MacBlockList.swift",
        "\u{1B}[31m??\u{1B}[m Turm.xcodeproj/xcshareddata/",
    ]

    private static let listing = [
        "total 0",
        "drwxr-xr-x@ 12 dev  staff  384 Oct  1 17:44 \u{1B}[34mCompanion\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  4 dev  staff  128 Oct  1 17:44 \u{1B}[34mKeyboard\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  9 dev  staff  288 Oct  1 17:44 \u{1B}[34mSSH\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  5 dev  staff  160 Oct  1 17:44 \u{1B}[34mShell\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  3 dev  staff   96 Oct  1 17:44 \u{1B}[34mShortcuts\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  5 dev  staff  160 Oct  1 17:44 \u{1B}[34mSupport\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  7 dev  staff  224 Oct  1 17:44 \u{1B}[34mSync\u{1B}[39;49m\u{1B}[0m",
        "drwxr-xr-x@  3 dev  staff   96 Oct  1 17:44 \u{1B}[34mTheme\u{1B}[39;49m\u{1B}[0m",
    ]

    private static let swiftTest: [String] = [
        "Building for debugging...",
        "[1/1] Write swift-version-4A2EBE8C6F4E83F1.txt",
        "Build complete! (2.37s)",
    ] + [
        "recordedRemoteSessionInOneChunk",
        "recordedRemoteSessionSplitAtEveryByte",
        "recordedRemoteSessionOneByteAtATime",
        "eventsKeepTheirPlaceBetweenOutput",
        "altScreenSwitchIsFound",
        "oversizedEnvironmentEndedByStringTerminatorIsDiscarded",
        "malformedRemoteMarkersAreNotEvents",
        "foreignOscSplitAcrossChunksPassesThrough",
        "foreignOscPassesThroughUntouched",
        "environmentWithinLimitIsDecoded",
        "oversizedEnvironmentIsDiscardedAndParsingResumes",
    ].map { "\u{1B}[92m\u{2714}\u{1B}[0m Test \($0)() passed after 0.929 seconds." } + [
        "\u{1B}[92m\u{2714}\u{1B}[0m Suite ShellStreamParserTests passed after 0.930 seconds.",
        "\u{1B}[92m\u{2714}\u{1B}[0m Test run with 11 tests in 1 suite passed after 0.930 seconds.",
    ]

    private static let swiftBuild = [
        "Building for production...",
        "[1/4] Write sources",
        "[3/4] Compiling TurmCore ShellEvent.swift",
        "\u{1B}[1m/Users/dev/Projects/turm/Packages/TurmCore/Sources/TurmCore/Shell/ShellEvent.swift:212:41: \u{1B}[1;31merror: \u{1B}[0m\u{1B}[1mcannot find 'promptToken' in scope\u{1B}[0m",
        "\u{1B}[34m210 |\u{1B}[0m             let code = Int32(fields[1])",
        "\u{1B}[34m211 |\u{1B}[0m             let path = String(fields[2])",
        "\u{1B}[34m212 |\u{1B}[0m             return .remotePrompt(token: promptToken, exitCode: code, path: path)",
        "\u{1B}[34m    |\u{1B}[0m                                         `- \u{1B}[1;31merror: \u{1B}[0mcannot find 'promptToken' in scope",
        "\u{1B}[34m213 |\u{1B}[0m         default:",
        "\u{1B}[34m214 |\u{1B}[0m             return nil",
    ]

    private static let gitPull: [String] = [
        "Updating 3f2a91c..8be04d7",
        "Fast-forward",
        " src/routes/billing/invoices.ts | 48 \u{1B}[32m" + String(repeating: "+", count: 37) + "\u{1B}[m\u{1B}[31m"
            + String(repeating: "-", count: 11) + "\u{1B}[m",
        " src/lib/stripe.ts              | 12 \u{1B}[32m" + String(repeating: "+", count: 9) + "\u{1B}[m\u{1B}[31m"
            + String(repeating: "-", count: 3) + "\u{1B}[m",
        " 2 files changed, 46 insertions(+), 14 deletions(-)",
    ]

    private static let npmBuild = Data(([
        "",
        "> api@2.4.0 build",
        "> tsc -p tsconfig.build.json && vite build",
        "",
        "\u{1B}[36mvite v5.4.8 \u{1B}[32mbuilding for production...\u{1B}[39m",
        "transforming (412) \u{1B}[2msrc/routes/billing/invoices.ts\u{1B}[22m",
    ].joined(separator: "\r\n") + "\u{1B}]9;4;1;64\u{07}").utf8)

    private static let terraformPlan = [
        "\u{1B}[0m\u{1B}[1maws_s3_bucket.assets: Refreshing state... [id=acme-assets-prod]\u{1B}[0m",
        "\u{1B}[0m\u{1B}[1maws_cloudfront_distribution.cdn: Refreshing state... [id=E2QX7RZ1K8LMNO]\u{1B}[0m",
        "\u{1B}[0m\u{1B}[1maws_route53_record.www: Refreshing state... [id=Z048213ABCDEF_www.acme.dev_A]\u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[1m\u{1B}[32mNo changes.\u{1B}[0m\u{1B}[1m Your infrastructure matches the configuration.\u{1B}[0m",
        "",
        "\u{1B}[0mTerraform has compared your real infrastructure against your configuration",
        "and found no differences, so no changes are needed.\u{1B}[0m",
    ]

    private static let motd = [
        "Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)",
        "",
        " * Documentation:  https://help.ubuntu.com",
        " * Management:     https://landscape.canonical.com",
        " * Support:        https://ubuntu.com/pro",
        "",
        " System information as of Thu Oct  1 17:52:08 UTC 2026",
        "",
        "  System load:  0.18               Processes:             143",
        "  Usage of /:   41.6% of 77.39GB   Users logged in:       0",
        "  Memory usage: 37%                IPv4 address for eth0: 10.0.1.24",
        "  Swap usage:   0%",
        "",
        "0 updates can be applied immediately.",
        "",
        "Last login: Wed Sep 30 09:14:37 2026 from 10.0.1.5",
    ]

    private static let uptime = [
        " 17:52:31 up 23 days,  4:11,  1 user,  load average: 0.18, 0.21, 0.17",
    ]

    private static let diskFree = [
        "Filesystem      Size  Used Avail Use% Mounted on",
        "/dev/sda1        78G   33G   45G  42% /",
    ]

    private static let dockerPS = [
        "NAMES      IMAGE                   STATUS",
        "web        ghcr.io/acme/web:1.14   Up 3 days (healthy)",
        "worker     ghcr.io/acme/web:1.14   Up 3 days",
        "postgres   postgres:16-alpine      Up 23 days (healthy)",
        "redis      redis:7-alpine          Up 23 days",
    ]

    private static let nginxStatus = [
        "\u{1B}[0;1;32m\u{25CF}\u{1B}[0m nginx.service - A high performance web server and a reverse proxy server",
        "     Loaded: loaded (/usr/lib/systemd/system/nginx.service; \u{1B}[0;1;32menabled\u{1B}[0m; preset: \u{1B}[0;1;32menabled\u{1B}[0m)",
        "     Active: \u{1B}[0;1;32mactive (running)\u{1B}[0m since Mon 2026-09-07 13:41:22 UTC; 3 weeks 3 days ago",
        "       Docs: man:nginx(8)",
        "   Main PID: 1184 (nginx)",
        "      Tasks: 5 (limit: 9387)",
        "     Memory: 12.4M (peak: 18.9M)",
        "        CPU: 2min 41.337s",
        "     CGroup: /system.slice/nginx.service",
        "             \u{251C}\u{2500}1184 \"nginx: master process /usr/sbin/nginx -g daemon on; master_process on;\"",
        "             \u{2514}\u{2500}1185 \"nginx: worker process\"",
    ]
}
#endif
