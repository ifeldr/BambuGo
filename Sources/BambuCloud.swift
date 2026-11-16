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
            let detail = Self.message(from: json) ?? "loginType: \(json["loginType"] as? String ?? "-")"
            throw CloudError(message: "Codice non accettato da Bambu Lab (\(detail))")
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

    /// Username MQTT: "u_" + id utente. Il token oggi è opaco (non JWT): l'id si legge
    /// dal profilo, con un paio di endpoint di riserva.
    func mqttUsername(token: String) async throws -> String {
        if let fromJWT = Self.usernameFromJWT(token) { return fromJWT }

        let endpoints = [
            region.apiBase + "/v1/user-service/my/profile",
            region.apiBase + "/v1/design-user-service/my/preference",
            (region == .global ? "https://makerworld.com" : "https://makerworld.com.cn")
                + "/api/v1/design-user-service/my/preference",
        ]
        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (json, _) = try await send(url: url, method: "GET", body: nil, token: token)
                if let uid = Self.uid(from: json) { return "u_\(uid)" }
            } catch {
                lastError = error
            }
        }
        let detail = lastError?.localizedDescription ?? "risposta senza uid"
        throw CloudError(message: "Accesso riuscito, ma non riesco a leggere l'ID utente: \(detail)")
    }

    private static func uid(from json: [String: Any]) -> String? {
        for key in ["uid", "uidStr", "userId"] {
            if let n = json[key] as? NSNumber { return String(n.int64Value) }
            if let s = json[key] as? String, !s.isEmpty { return s }
        }
        if let user = json["user"] as? [String: Any] { return uid(from: user) }
        return nil
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

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

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
        // BambuGo si presenta con il proprio nome: non si spaccia per Bambu Studio o OrcaSlicer.
        request.setValue("BambuGo/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
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
        guard !(200..<300).contains(http.statusCode) else { return (json, http) }

        // Messaggio dettagliato: cosa ha risposto il server, con quale codice e su quale endpoint.
        let serverText = Self.message(from: json)
            ?? String(data: data.prefix(160), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let isHTML = serverText?.hasPrefix("<") ?? false
        let reason = (serverText?.isEmpty == false && !isHTML) ? serverText! : "nessun dettaglio"
        let place = "HTTP \(http.statusCode) su \(url.host ?? "")\(url.path)"
        throw CloudError(message: "\(reason) (\(place))",
                         isUnauthorized: token != nil && http.statusCode == 401)
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
