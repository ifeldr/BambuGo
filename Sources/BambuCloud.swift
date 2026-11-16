import Foundation
import Security

enum CloudRegion: String, CaseIterable, Identifiable {
    case global
    case china

    var id: String { rawValue }
    var label: String { self == .global ? "Globale / Europa" : "Cina" }
    var apiBase: String { self == .global ? "https://api.bambulab.com" : "https://api.bambulab.cn" }
    var webBase: String { self == .global ? "https://bambulab.com" : "https://bambulab.cn" }
    var mqttHost: String { self == .global ? "us.mqtt.bambulab.com" : "cn.mqtt.bambulab.com" }
}

struct CloudDevice: Identifiable, Hashable {
    let id: String        // numero di serie
    let name: String
    let model: String
    let online: Bool
    let accessCode: String
}

enum LoginResult {
    case success(token: String)
    case needsEmailCode
    case needsTFA(tfaKey: String)
}

struct CloudError: LocalizedError {
    let message: String
    var isUnauthorized = false
    var errorDescription: String? { message }
}

/// Client per le API HTTP del cloud Bambu Lab (login, profilo, elenco stampanti).
struct BambuCloud {
    let region: CloudRegion

    // MARK: - Login

    func login(email: String, password: String) async throws -> LoginResult {
        let json = try await post("/v1/user-service/user/login",
                                  body: ["account": email, "password": password, "apiError": ""])
        if let token = json["accessToken"] as? String, !token.isEmpty {
            return .success(token: token)
        }
        switch json["loginType"] as? String {
        case "verifyCode":
            try await sendEmailCode(email: email)
            return .needsEmailCode
        case "tfa":
            return .needsTFA(tfaKey: json["tfaKey"] as? String ?? "")
        default:
            throw CloudError(message: Self.message(from: json) ?? "Accesso non riuscito")
        }
    }

    func sendEmailCode(email: String) async throws {
        _ = try await post("/v1/user-service/user/sendemail/code",
                           body: ["email": email, "type": "codeLogin"])
    }

    func login(email: String, code: String) async throws -> String {
        let json = try await post("/v1/user-service/user/login", body: ["account": email, "code": code])
        guard let token = json["accessToken"] as? String, !token.isEmpty else {
            throw CloudError(message: Self.message(from: json) ?? "Codice non valido o scaduto")
        }
        return token
    }

    func login(tfaKey: String, code: String) async throws -> String {
        guard let url = URL(string: region.webBase + "/api/sign-in/tfa") else {
            throw CloudError(message: "URL non valido")
        }
        let (json, response) = try await send(url: url, method: "POST",
                                              body: ["tfaKey": tfaKey, "tfaCode": code], token: nil)
        if let token = json["accessToken"] as? String, !token.isEmpty { return token }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        if let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .first(where: { $0.name == "token" }) {
            return cookie.value
        }
        throw CloudError(message: Self.message(from: json) ?? "Codice di verifica non valido")
    }

    // MARK: - Dati account

    /// Username MQTT: "u_" + id utente.
    func mqttUsername(token: String) async throws -> String {
        if let fromJWT = Self.usernameFromJWT(token) { return fromJWT }
        let json = try await get("/v1/design-user-service/my/preference", token: token)
        if let uid = json["uid"] as? NSNumber { return "u_\(uid.int64Value)" }
        if let uid = json["uid"] as? String, !uid.isEmpty { return "u_\(uid)" }
        throw CloudError(message: "Impossibile leggere l'ID utente dal cloud")
    }

    func devices(token: String) async throws -> [CloudDevice] {
        let json = try await get("/v1/iot-service/api/user/bind", token: token)
        let list = json["devices"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let serial = item["dev_id"] as? String else { return nil }
            return CloudDevice(
                id: serial,
                name: item["name"] as? String ?? serial,
                model: item["dev_product_name"] as? String ?? item["dev_model_name"] as? String ?? "",
                online: (item["online"] as? NSNumber)?.boolValue ?? false,
                accessCode: item["dev_access_code"] as? String ?? ""
            )
        }
    }

    // MARK: - HTTP

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        guard let url = URL(string: region.apiBase + path) else { throw CloudError(message: "URL non valido") }
        return try await send(url: url, method: "GET", body: nil, token: token).0
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: region.apiBase + path) else { throw CloudError(message: "URL non valido") }
        return try await send(url: url, method: "POST", body: body, token: nil).0
    }

    private func send(url: URL, method: String, body: [String: Any]?, token: String?)
        async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("bambu_network_agent/01.09.05.01", forHTTPHeaderField: "User-Agent")
        request.setValue("OrcaSlicer", forHTTPHeaderField: "X-BBL-Client-Name")
        request.setValue("slicer", forHTTPHeaderField: "X-BBL-Client-Type")
        request.setValue("01.09.05.51", forHTTPHeaderField: "X-BBL-Client-Version")
        request.setValue("it-IT", forHTTPHeaderField: "X-BBL-Language")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudError(message: "Cloud Bambu non raggiungibile: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError(message: "Risposta non valida") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        switch http.statusCode {
        case 200..<300:
            return (json, http)
        case 401, 403:
            throw CloudError(message: Self.message(from: json) ?? "Sessione scaduta o credenziali errate",
                             isUnauthorized: token != nil)
        default:
            throw CloudError(message: Self.message(from: json) ?? "Errore dal cloud (HTTP \(http.statusCode))")
        }
    }

    private static func message(from json: [String: Any]) -> String? {
        for key in ["message", "error", "msg"] {
            if let text = json[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private static func usernameFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let username = json["username"] as? String,
              username.hasPrefix("u_") else { return nil }
        return username
    }
}

// MARK: - Portachiavi

enum Keychain {
    private static let service = "it.ifeldr.BambuGo"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
