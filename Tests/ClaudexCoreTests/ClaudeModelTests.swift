import Foundation
import Testing
@testable import ClaudexCore

@Suite struct ClaudeModelTests {
    static func assistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"id":"m","model":"\#(model)","content":[]}}"#
    }

    @Test func lastAssistantModelWins() {
        let lines = [
            Self.assistant("claude-sonnet-5-5"),
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            Self.assistant("claude-opus-5-5"),
            #"{"type":"user","message":{"model":"claude-not-assistant"}}"#,
        ]
        #expect(ClaudeSessionReader.lastModel(fromLines: lines) == "claude-opus-5-5")
    }

    @Test func syntheticIsSkipped() {
        let lines = [Self.assistant("claude-fable-5-1"), Self.assistant("<synthetic>")]
        #expect(ClaudeSessionReader.lastModel(fromLines: lines) == "claude-fable-5-1")
    }

    @Test func malformedLinesAreIgnored() {
        let lines = [Self.assistant("claude-opus-5-5"), "{broken", "", "]]"]
        #expect(ClaudeSessionReader.lastModel(fromLines: lines) == "claude-opus-5-5")
    }

    @Test func partialFirstLineIsDroppedWhenTailing() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let filler = Self.assistant("claude-sonnet-5-5") + String(repeating: " ", count: 200)
        let last = Self.assistant("claude-opus-5-5")
        let file = try dir.write("proj/session.jsonl", filler + "\n" + last + "\n")
        // Start reading in the middle of the first line.
        let lines = JSONLTail.lines(of: file, maxBytes: last.utf8.count + 50)
        #expect(lines == [last])
        #expect(JSONLTail.lines(of: file).count == 2)
    }

    @Test func newestTranscriptOneLevelBelowProjects() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let now = Date()
        try dir.write("a/one.jsonl", Self.assistant("claude-sonnet-5-5") + "\n", modified: now.addingTimeInterval(-500))
        try dir.write("b/two.jsonl", Self.assistant("claude-opus-5-5") + "\n", modified: now.addingTimeInterval(-10))
        try dir.write("b/notes.txt", "x", modified: now)
        let reader = ClaudeSessionReader(projectsDir: dir.url)
        let newest = try #require(reader.newestTranscript())
        #expect(newest.url.lastPathComponent == "two.jsonl")
        #expect(reader.read(file: newest.url, modified: newest.modified).model == "claude-opus-5-5")
    }

    @Test func findReturnsFirstMatchOfSortedKeyWalk() {
        // Within one object the walk is deterministic (sorted keys, depth-first), not
        // document order: "a" sorts before "z", and inside "a" the key "b" sorts before
        // "k", so the nested value is found first.
        let json: [String: Any] = ["z": [["k": 3]], "a": ["k": 1, "b": ["k": 2]]]
        #expect(JSONSearch.find(key: "k", in: json) as? Int == 2)
        #expect(JSONSearch.find(key: "k", in: ["b": ["k": 2], "c": 9]) as? Int == 2)
        #expect(JSONSearch.find(key: "missing", in: json) == nil)
    }
}
