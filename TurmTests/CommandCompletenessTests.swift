import Testing
@testable import Turm

struct CommandCompletenessTests {
    @Test(arguments: [
        "ls", "ls -la ~/Projects", "echo 'it''s'", "echo \"a b\"", "echo \\'", "ls \\ ", "echo $(date)",
        "ls | grep a", "a && b || c", "if true; then echo; fi", "for f in *; do echo $f; done",
        "case $x in a) ls;; esac", "{ ls; }", "(cd /tmp && ls)", "echo \"line\nnext\"", "ls # it's fine",
        "cat <<EOF\nhello\nEOF", "cat <<-'END'\n\tbody\n\tEND\necho done", "cat <<< 'x'", "echo if then fi",
        "find . -exec rm {} \\;", "ls > done", "",
    ])
    func completeCommands(_ text: String) {
        #expect(CommandCompleteness.isComplete(text))
    }

    @Test(arguments: [
        "ls '/Users/me/Projects/", "echo \"unterminated", "echo $(date", "echo ${HOME", "echo `date",
        "ls \\", "ls \\\n", "ls |", "a &&", "a ||\n", "if true; then", "for f in *; do echo $f",
        "while true\ndo", "case $x in", "{ ls;", "(cd /tmp", "cat <<EOF", "cat <<EOF\nhello",
        "cat <<-END\n\tbody", "cat <<A <<B\nx\nA\ny",
    ])
    func incompleteCommands(_ text: String) {
        #expect(!CommandCompleteness.isComplete(text))
    }

    @Test func fishBlocksEndWithEnd() {
        #expect(!CommandCompleteness.isComplete("for f in *", fish: true))
        #expect(!CommandCompleteness.isComplete("if test -d x\necho yes", fish: true))
        #expect(CommandCompleteness.isComplete("for f in *; echo $f; end", fish: true))
        #expect(CommandCompleteness.isComplete("begin; ls; end", fish: true))
        #expect(!CommandCompleteness.isComplete("if true; ls; fi", fish: true))
    }
}
