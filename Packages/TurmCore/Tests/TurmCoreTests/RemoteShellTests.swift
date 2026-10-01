import CryptoKit
import Foundation
import Testing
@testable import TurmCore

struct RemoteProbeParsingTests {
    @Test func parsesShellAndVersion() {
        #expect(RemoteProbe(output: "zsh\n1a2b\n") == RemoteProbe(shell: "zsh", version: "1a2b"))
        #expect(RemoteProbe(output: "  fish  \r\n  9f00  \r\n") == RemoteProbe(shell: "fish", version: "9f00"))
    }

    @Test func missingVersionIsNil() {
        #expect(RemoteProbe(output: "bash\n") == RemoteProbe(shell: "bash", version: nil))
        #expect(RemoteProbe(output: "bash") == RemoteProbe(shell: "bash", version: nil))
    }

    @Test func emptyOutputIsRejected() {
        #expect(RemoteProbe(output: "") == nil)
        #expect(RemoteProbe(output: "\n\n") == nil)
    }

    @Test func supportedShellsAndKinds() {
        #expect(RemoteShellKind.supports("zsh"))
        #expect(RemoteShellKind.supports("bash"))
        #expect(RemoteShellKind.supports("fish"))
        #expect(!RemoteShellKind.supports("tcsh"))
        #expect(RemoteShellKind(rawValue: "bash-legacy") == .legacyBash)
    }
}

struct ShellSubmissionTests {
    @Test func bracketedPasteWrapsTheCommandAndPressesReturn() {
        let payload = ShellSubmission.bracketedPaste.payload(for: "echo hi\necho there")
        #expect(payload == Array("\u{1B}[200~echo hi\necho there\u{1B}[201~\r".utf8))
    }

    @Test func typedTurnsNewlinesIntoReturns() {
        #expect(ShellSubmission.typed.payload(for: "a\nb") == Array("a\rb\r".utf8))
    }

    @Test func legacyBashTypesAndOthersPaste() {
        #expect(RemoteShellKind.legacyBash.submission == .typed)
        #expect(RemoteShellKind.bash.submission == .bracketedPaste)
        #expect(RemoteShellKind.zsh.submission == .bracketedPaste)
        #expect(RemoteShellKind.fish.submission == .bracketedPaste)
    }

    @Test func quotingFollowsTheShell() {
        #expect(RemoteShellKind.zsh.quoted("it's") == "'it'\\''s'")
        #expect(RemoteShellKind.fish.quoted("it's \\ here") == "'it\\'s \\\\ here'")
    }
}

struct RemoteShellInstallTests {
    private let expectedPaths = ["bootstrap.sh", "rc.bash", "integration.fish", "zsh/.zshenv", "zsh/.zprofile", "zsh/.zshrc"]

    @Test func filesAreListedInInstallOrderAndEndWithNewline() {
        #expect(RemoteShellInstall.files.map(\.path) == expectedPaths)
        #expect(RemoteShellInstall.files.allSatisfy { $0.contents.hasSuffix("\n") })
        #expect(RemoteShellInstall.files[1].contents == ShellScripts.bash + "\n")
        #expect(RemoteShellInstall.files[2].contents == ShellScripts.fish + "\n")
        #expect(RemoteShellInstall.files[0].contents == RemoteShellInstall.bootstrap)
    }

    @Test func versionHashesPathNulContentsForEveryFile() {
        let sources = [RemoteShellInstall.bootstrap, ShellScripts.bash, ShellScripts.fish] + ShellScripts.zsh.map(\.contents)
        var hasher = SHA256()
        for (path, contents) in zip(expectedPaths, sources) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data((contents.hasSuffix("\n") ? contents : contents + "\n").utf8))
        }
        let expected = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        #expect(RemoteShellInstall.version == expected)
        #expect(RemoteShellInstall.version.count == 16)
        #expect(RemoteShellInstall.version.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func installScriptWritesEveryFileThenTheVersion() {
        let script = RemoteShellInstall.installScript()
        #expect(script.hasPrefix("set -e\numask 022\nd=\"$HOME/.turm/shell\"\nmkdir -p \"$d/zsh\"\n"))
        for (index, path) in expectedPaths.enumerated() {
            #expect(script.contains("cat > \"$d/\(path).tmp\" <<'TURM_FILE_\(index)_END'\n"))
            #expect(script.contains("TURM_FILE_\(index)_END\nmv -f \"$d/\(path).tmp\" \"$d/\(path)\"\n"))
        }
        #expect(script.hasSuffix("printf '%s\\n' '\(RemoteShellInstall.version)' > \"$d/version\"\n"))
    }

    @Test func enableCommandStartsWithASpaceToStayOutOfHistory() {
        #expect(RemoteShellInstall.enableCommand == " TURM_BANNER=1 exec sh \"$HOME/.turm/shell/bootstrap.sh\"")
    }

    @Test func greetingKeepsTheBannerTheBootstrapPrintedAndDropsTheServersCopy() {
        let prelude = Array((
            "\r\nWelcome to box\r\nLast login: today\r\n"
                + "dev@box:~$  TURM_BANNER=1 exec sh \"$HOME/.turm/shell/bootstrap.sh\"\r\n"
                + "Welcome to box\r\n\r\n"
        ).utf8)
        #expect(RemoteShellInstall.greeting(from: prelude) == Array("Welcome to box\r".utf8))
    }

    @Test func greetingKeepsEverythingWhenNoBootstrapLineWasEchoed() {
        let prelude = Array("\r\nWelcome to box\r\n".utf8)
        #expect(RemoteShellInstall.greeting(from: prelude) == Array("Welcome to box\r".utf8))
    }

    @Test func bootstrapPrintsTheLoginBannerOnlyWhenAsked() {
        #expect(RemoteShellInstall.bootstrap.contains(#"if [ -n "$TURM_BANNER" ]; then"#))
        #expect(RemoteShellInstall.bootstrap.contains(#"[ ! -e "$HOME/.hushlogin" ]"#))
    }

    @Test func greetingIsNilWhenOnlyTheBootstrapWasPrinted() {
        let prelude = Array("\u{1B}[?2004h$  exec sh \"$HOME/.turm/shell/bootstrap.sh\"\r\n\u{1B}[?2004l\r\n".utf8)
        #expect(RemoteShellInstall.greeting(from: prelude) == nil)
        #expect(RemoteShellInstall.greeting(from: []) == nil)
    }
}

struct RemoteGitTests {
    @Test func statusScriptEntersTheQuotedDirectory() {
        let script = RemoteGit.statusScript(in: "/srv/it's")
        #expect(script.hasPrefix("export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0\ncd '/srv/it'\\''s' 2>/dev/null || exit 3\n"))
        #expect(script.hasSuffix("git diff HEAD --numstat 2>/dev/null"))
    }

    @Test func switchScriptQuotesTheBranch() {
        #expect(RemoteGit.switchScript(to: "feat/x y", in: "/r").hasSuffix("git switch 'feat/x y' 2>&1"))
    }

    @Test func parseStatusReadsBranchAndNumstat() {
        let git = RemoteGit.parseStatus("main\n3\t1\tsrc/a.swift\n-\t-\timage.png\n10\t0\tb.txt\n")
        #expect(git == CompanionGit(branch: "main", files: 3, added: 13, removed: 1))
    }

    @Test func parseStatusBranchOnlyAndEmpty() {
        #expect(RemoteGit.parseStatus("feature/x\n") == CompanionGit(branch: "feature/x", files: 0, added: 0, removed: 0))
        #expect(RemoteGit.parseStatus("abc1234") == CompanionGit(branch: "abc1234", files: 0, added: 0, removed: 0))
        #expect(RemoteGit.parseStatus("") == nil)
        #expect(RemoteGit.parseStatus("\n1\t1\ta\n") == nil)
    }

    @Test func branchesAreOnePerLine() {
        #expect(RemoteGit.branches(from: "main\ndev\n") == ["main", "dev"])
    }
}
