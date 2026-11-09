import Foundation
import Security

enum CheapVibeKeychain {
    private static let service = "dev.kodoku.AILimits"
    private static let account = "cheapvibecode.api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func hasKey() -> Bool {
        SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return }
        let update: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

private final class CheapVibeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CheapVibeClient {
    private static let endpoint = URL(string: "https://ru.cheapvibecode.ru/v1/balance")!

    static func fetch() async -> CheapVibeFetchResult {
        guard let key = CheapVibeKeychain.load() else { return .notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AILimits/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let delegate = CheapVibeRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { return .failure(.network) }
            return parse(statusCode: http.statusCode, data: data)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failure(.network)
        }
    }

    static func parse(statusCode: Int, data: Data) -> CheapVibeFetchResult {
        switch statusCode {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let value = integerValue(dictionary["token_balance"]) else {
                return .failure(.invalidResponse)
            }
            return .success(tokens: value)
        case 401, 403: return .failure(.unauthorized)
        case 429: return .failure(.rateLimited)
        default: return .failure(.http(statusCode))
        }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let type = String(cString: number.objCType)
            if "cCsSiIlLqQ".contains(type) {
                if type == "Q" {
                    let unsigned = number.uint64Value
                    return unsigned <= UInt64(Int.max) ? Int(unsigned) : nil
                }
                let signed = number.int64Value
                return signed >= 0 ? Int(exactly: signed) : nil
            }
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double.rounded(.towardZero) == double else { return nil }
            return decimalInteger(String(describing: number))
        }
        guard let string = value as? String else { return nil }
        return decimalInteger(string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decimalInteger(_ string: String) -> Int? {
        // Decimal(string:) accepts a numeric prefix and ignores trailing garbage.
        // Validate the whole token first so "42abc", "12,5" and "1 000" fail closed.
        guard string.range(of: #"^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                          options: .regularExpression) != nil,
              let decimal = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var rounded = Decimal()
        var source = decimal
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard decimal == rounded, let number = NSDecimalNumber(decimal: decimal).int64Value as Int64?,
              number >= 0, let result = Int(exactly: number) else { return nil }
        let reconstructed = Decimal(result)
        return reconstructed == decimal ? result : nil
    }
}
