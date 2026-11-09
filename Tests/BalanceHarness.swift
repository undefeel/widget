import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func parse(_ status: Int = 200, _ body: String) -> CheapVibeFetchResult {
    CheapVibeClient.parse(statusCode: status, data: Data(body.utf8))
}

private func parse(_ body: String) -> CheapVibeFetchResult {
    parse(200, body)
}

private func success(_ result: CheapVibeFetchResult, _ expected: Int, _ message: String) {
    guard case .success(let tokens) = result else { preconditionFailure(message) }
    check(tokens == expected, message)
}

private func invalid(_ result: CheapVibeFetchResult, _ message: String) {
    guard case .failure(.invalidResponse) = result else { preconditionFailure(message) }
}

private func oldSnapshotDecodes() {
    let json = #"{"providers":[{"provider":"claude","windows":[]}],"generatedAt":0}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let snapshot = try! decoder.decode(Snapshot.self, from: Data(json.utf8))
    check(snapshot.cheapVibe == nil, "old Snapshot unexpectedly has a balance")
}

@main
struct BalanceHarness {
    static func main() {
        success(parse(#"{"token_balance":12345}"#), 12345, "numeric token_balance failed")
        success(parse(#"{"token_balance":"67890"}"#), 67890, "numeric-string token_balance failed")
        success(parse(#"{"token_balance":"123.0"}"#), 123, "integral numeric string failed")
        success(parse(#"{"token_balance":42,"other":"ignored","nested":{"x":1}}"#), 42,
                "extra fields were not ignored")
        invalid(parse(#"{"other":1}"#), "missing token_balance was accepted")
        invalid(parse(#"{"token_balance":-1}"#), "negative token_balance was accepted")
        invalid(parse(#"{"token_balance":1.5}"#), "fractional token_balance was accepted")
        invalid(parse(#"{"token_balance":"42abc"}"#), "trailing garbage was accepted")
        invalid(parse(#"{"token_balance":"12,5"}"#), "comma decimal was accepted")
        invalid(parse(#"{"token_balance":"1 000"}"#), "space-separated number was accepted")
        success(parse(#"{"token_balance":9223372036854775807}"#), Int.max,
                "Int.max token_balance failed")
        invalid(parse(#"{"token_balance":9223372036854775808}"#), "over-Int token_balance was accepted")
        invalid(parse("not json"), "malformed JSON was accepted")
        check(({ if case .failure(.unauthorized) = parse(401, "{}"){ return true }; return false })(),
              "401 was not unauthorized")
        check(({ if case .failure(.rateLimited) = parse(429, "{}"){ return true }; return false })(),
              "429 was not rateLimited")
        check(({ if case .failure(.http(500)) = parse(500, "{}"){ return true }; return false })(),
              "500 was not http(500)")
        oldSnapshotDecodes()
        print("balance harness: ok")
    }
}
