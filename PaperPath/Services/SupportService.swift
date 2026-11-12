import Foundation
import Security

struct SupportThread: Codable, Identifiable, Equatable {
    let id: String
    let conversationToken: String
    let title: String
    let createdAt: String
}

struct SupportConversation: Decodable {
    struct Feedback: Decodable {
        let id: String
        let product: String
        let title: String
        let status: String
    }
    struct Message: Decodable, Identifiable {
        let id: String
        let author: String
        let body: String
        let createdAt: String
    }
    let feedback: Feedback
    let messages: [Message]
}

enum SupportFailure: Error, LocalizedError, Equatable {
    case validation, unavailable, credentials, capacity, rejected, uncertain, storage, invalidResponse

    var errorDescription: String? {
        switch self {
        case .validation: return "Check your email, title (3–160 characters), and description (10–5,000 characters).".localizedUI
        case .unavailable: return "Support is unavailable. Your text is still here; try again later or email hello@monoware.app.".localizedUI
        case .credentials: return "This conversation cannot be opened with the saved credentials. Contact hello@monoware.app.".localizedUI
        case .capacity: return "Support has reached its message or storage limit. Email hello@monoware.app.".localizedUI
        case .rejected: return "Support could not accept this request. Check the text or email hello@monoware.app.".localizedUI
        case .uncertain: return "Delivery could not be confirmed. Check the conversation before sending again to avoid duplicates.".localizedUI
        case .storage: return "The conversation could not be saved securely. Try saving again, or close and reopen Support during this app session.".localizedUI
        case .invalidResponse: return "Support returned an unexpected response. Delivery may have completed; contact hello@monoware.app before resubmitting.".localizedUI
        }
    }
}

// All local conversation data, including bearer credentials, stays in the device Keychain.
struct SupportThreadStore {
    let service: String
    init(service: String = "com.monoware.paperpath.support.production") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "conversations"]
    }
    func load() throws -> [SupportThread] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SupportFailure.storage
        }
        return try JSONDecoder().decode([SupportThread].self, from: data)
    }
    func save(_ thread: SupportThread) throws {
        var threads = try load()
        threads.removeAll { $0.id == thread.id }
        threads.insert(thread, at: 0)
        let data = try JSONEncoder().encode(threads)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SupportFailure.storage
            }
        } else if status != errSecSuccess { throw SupportFailure.storage }
    }
}

final class SupportService: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SupportService()
    static let baseURL = URL(string: "https://support.monoware.app/api/v1/feedback")!
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    private lazy var session: URLSession = {
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Never forward a conversation bearer credential through a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func valid(email: String, title: String, description: String) -> Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.count <= 254
            && email.range(of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$"#, options: .caseInsensitive.union(.regularExpression)) != nil
            && (3...160).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
            && (10...5000).contains(description.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
    }

    func create(email: String, title: String, description: String, type: String,
                includeDeviceInfo: Bool) async throws -> SupportThread {
        guard Self.valid(email: email, title: title, description: description),
              ["bug", "feature_request", "improvement", "other"].contains(type) else {
            throw SupportFailure.validation
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = ["product": "paperpath", "type": type,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "title": title,
            "description": description.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeDeviceInfo {
            payload["extension"] = [
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString
            ]
        }
        struct Created: Decodable { let id: String; let conversationToken: String; let createdAt: String }
        let data = try await request(url: Self.baseURL, payload: payload)
        guard let result = try? JSONDecoder().decode(Created.self, from: data),
              UUID(uuidString: result.id) != nil,
              result.conversationToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw SupportFailure.invalidResponse
        }
        return SupportThread(id: result.id, conversationToken: result.conversationToken,
                             title: title, createdAt: result.createdAt)
    }

    func conversation(_ thread: SupportThread) async throws -> SupportConversation {
        let url = try threadURL(thread)
        let data = try await request(url: url, token: thread.conversationToken)
        guard let result = try? JSONDecoder().decode(SupportConversation.self, from: data),
              result.feedback.id == thread.id, result.feedback.product == "paperpath" else {
            throw SupportFailure.invalidResponse
        }
        return result
    }

    func reply(_ text: String, to thread: SupportThread) async throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...5000).contains(message.unicodeScalars.count) else { throw SupportFailure.validation }
        let url = try threadURL(thread).appendingPathComponent("messages")
        _ = try await request(url: url, token: thread.conversationToken, payload: ["message": message])
    }

    private func threadURL(_ thread: SupportThread) throws -> URL {
        guard UUID(uuidString: thread.id) != nil,
              thread.conversationToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw SupportFailure.credentials
        }
        return Self.baseURL.appendingPathComponent(thread.id)
    }

    private func request(url: URL, token: String? = nil, payload: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw payload == nil ? SupportFailure.unavailable : SupportFailure.uncertain }
        guard let http = response as? HTTPURLResponse else { throw SupportFailure.invalidResponse }
        switch http.statusCode {
        case payload == nil ? 200 : 201: return data
        case 401, 404: throw SupportFailure.credentials
        case 400, 403, 413: throw SupportFailure.rejected
        case 507: throw SupportFailure.capacity
        default: throw payload == nil ? SupportFailure.unavailable : SupportFailure.uncertain
        }
    }
}
