import Foundation

@main
struct TranscriptStoreTests {
    static func main() {
        let store = TranscriptStore()

        store.addUserPrompt("hello")
        store.appendAssistantDelta("thread-1", turnId: "turn-1", text: "hel")
        store.appendAssistantDelta("thread-1", turnId: "turn-1", text: "lo")
        store.finishAssistantTurn("thread-1", turnId: "turn-1")

        require(store.entries.count == 2, "expected user prompt and one assistant message")
        require(store.entries[0].role == .user, "first message should be user")
        require(store.entries[0].text == "hello", "user text should be preserved")
        require(store.entries[1].role == .assistant, "second message should be assistant")
        require(store.entries[1].text == "hello", "assistant deltas should merge")
        require(store.entries[1].isStreaming == false, "completed turn should stop streaming")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
