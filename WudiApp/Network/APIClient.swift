//
//  APIClient.swift
//  WudiApp
//
//  统一网络请求：x-token 头、JSON 序列化、错误与 code 处理
//

import Foundation
import SQLite3

struct ConversationSearchHitSnippet: Identifiable, Hashable {
    let instanceId: String
    let jid: String
    let messageKey: String
    let messageID: Int?
    let text: String
    let timestamp: Int64
    let isTranslation: Bool
    var id: String { "\(instanceId)_\(jid)_\(messageKey)_\(isTranslation ? 1 : 0)" }
}

extension Notification.Name {
    static let apiUnauthorizedDetected = Notification.Name("apiUnauthorizedDetected")
}

enum UnauthorizedSessionHandler {
    private static var lastPostedAt: Date?
    
    static func reportHTTPStatus(_ code: Int) {
        guard code == 401 else { return }
        let now = Date()
        if let last = lastPostedAt, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastPostedAt = now
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .apiUnauthorizedDetected, object: nil)
        }
    }
}

@inline(__always)
func httpStatusError(_ code: Int) -> APIError {
    UnauthorizedSessionHandler.reportHTTPStatus(code)
    return .httpStatus(code)
}

#if DEBUG
private let sqliteLogEnabled = false
@inline(__always) private func sqliteLog(_ message: @autoclosure () -> String) {
    guard sqliteLogEnabled else { return }
    print("[SQLite] \(message())")
}
#else
@inline(__always) private func sqliteLog(_ message: @autoclosure () -> String) {}
#endif

enum APIError: LocalizedError {
    case invalidURL
    case noData
    case httpStatus(Int)
    case serverError(code: Int, message: String?)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请求地址无效"
        case .noData: return "无响应数据"
        case .httpStatus(let code): return "HTTP 错误 \(code)"
        case .serverError(let code, let msg): return msg ?? "服务器错误(\(code))"
        }
    }
}

/// 与 H5 一致：接口返回 code、msg、data
struct APIResponse<T: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: T?
}

/// 无 data 的响应（如部分登录接口）
struct APIResponseEmpty: Decodable {
    let code: Int
    let msg: String?
}

final class APIClient {
    static let shared = APIClient()
    
    /// 当前 token，与 H5 的 x-token 一致；由 AuthService 登录成功后设置
    var token: String? {
        get { UserDefaults.standard.string(forKey: "x-token") }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "x-token")
            } else {
                UserDefaults.standard.removeObject(forKey: "x-token")
            }
        }
    }
    
    /// 当前用户 ID，与 H5 的 x-user-id 一致；ios_manager_api 请求需带此头才能拿到云机数据
    var userID: String? {
        get {
            if let i = UserDefaults.standard.object(forKey: "user_id") as? Int { return "\(i)" }
            return UserDefaults.standard.string(forKey: "user_id")
        }
    }
    
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()
    
    private init() {}
    
    /// POST 请求，baseURL 为 gva_api 或 ios_manager_api
    func post<T: Decodable>(
        baseURL: String,
        path: String,
        body: [String: Any]? = nil,
        useToken: Bool = true
    ) async throws -> T {
        let urlString = baseURL.hasSuffix("/") ? baseURL + path.dropFirst() : "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if useToken, let t = token, !t.isEmpty {
            request.setValue(t, forHTTPHeaderField: "x-token")
        } else {
            request.setValue("", forHTTPHeaderField: "x-token")
        }
        
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            throw httpStatusError(http.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        if decoded.code != 0 {
            throw APIError.serverError(code: decoded.code, message: decoded.msg)
        }
        guard let value = decoded.data else {
            throw APIError.serverError(code: decoded.code, message: decoded.msg ?? "无数据")
        }
        return value
    }
    
    /// POST 无 data 的响应（仅 code/msg）
    func postEmpty(
        baseURL: String,
        path: String,
        body: [String: Any]? = nil,
        useToken: Bool = true
    ) async throws {
        let urlString = baseURL.hasSuffix("/") ? baseURL + path.dropFirst() : "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if useToken, let t = token, !t.isEmpty {
            request.setValue(t, forHTTPHeaderField: "x-token")
        } else {
            request.setValue("", forHTTPHeaderField: "x-token")
        }
        
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            throw httpStatusError(http.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(APIResponseEmpty.self, from: data)
        if decoded.code != 0 {
            throw APIError.serverError(code: decoded.code, message: decoded.msg)
        }
    }
    
    /// GET 请求（用于设备列表等）
    func get<T: Decodable>(
        baseURL: String,
        path: String,
        query: [String: String]? = nil,
        useToken: Bool = true
    ) async throws -> T {
        var urlString = baseURL.hasSuffix("/") ? baseURL + path.dropFirst() : "\(baseURL)\(path)"
        if let q = query, !q.isEmpty {
            let parts = q.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            urlString += "?" + parts.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if useToken, let t = token, !t.isEmpty {
            request.setValue(t, forHTTPHeaderField: "x-token")
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("", forHTTPHeaderField: "x-token")
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            throw httpStatusError(http.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(APIResponse<T>.self, from: data)
        if decoded.code != 0 {
            throw APIError.serverError(code: decoded.code, message: decoded.msg)
        }
        guard let value = decoded.data else {
            throw APIError.serverError(code: decoded.code, message: decoded.msg ?? "无数据")
        }
        return value
    }
}

actor AppCacheStore {
    static let shared = AppCacheStore()
    
    private let fm = FileManager.default
    private let rootFolder = "wudi_cache_sqlite_v1"
    private let dbFileName = "cache.sqlite3"
    private var db: OpaquePointer?
    private var openedDBPath: String?
    private var didRunChatsCacheMigration = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    
    private init() {}
    
    func saveBoxes(_ boxes: [Box]) async {
        guard ensureDBReady() else { return }
        let now = Date().timeIntervalSince1970
        let sqlDelete = "DELETE FROM boxes_cache;"
        _ = execute(sqlDelete)
        let sql = "INSERT OR REPLACE INTO boxes_cache (box_key, payload, updated_at) VALUES (?, ?, ?);"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in boxes {
            let key = "\(item.ID)|\(item.boxIP)"
            guard let data = try? encoder.encode(item) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: key)
            bindBlob(stmt, index: 2, data: data)
            sqlite3_bind_double(stmt, 3, now)
            _ = sqlite3_step(stmt)
        }
    }
    
    func loadBoxes(maxAge: TimeInterval? = nil) async -> [Box]? {
        guard ensureDBReady() else { return nil }
        var sql = "SELECT payload, updated_at FROM boxes_cache"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " WHERE updated_at >= \(threshold)"
        }
        sql += " ORDER BY updated_at DESC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        var rows: [Box] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Box.self, from: data) {
                rows.append(value)
            }
        }
        return rows.isEmpty ? nil : rows
    }
    
    func saveInstances(selectedBoxIPs: Set<String>, instances: [Instance]) async {
        guard ensureDBReady() else { return }
        let selectedKey = keyFromSet(selectedBoxIPs)
        let now = Date().timeIntervalSince1970
        let deleteSQL = "DELETE FROM instances_cache WHERE selected_key = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: selectedKey)
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
        let sql = """
        INSERT OR REPLACE INTO instances_cache
        (selected_key, instance_key, instance_id_for_api, box_ip, payload, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in instances {
            guard let data = try? encoder.encode(item) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: selectedKey)
            bindText(stmt, index: 2, value: item.instanceKey)
            bindText(stmt, index: 3, value: item.instanceIdForApi)
            bindText(stmt, index: 4, value: item.boxIP ?? "")
            bindBlob(stmt, index: 5, data: data)
            sqlite3_bind_double(stmt, 6, now)
            _ = sqlite3_step(stmt)
        }
    }
    
    func loadInstances(selectedBoxIPs: Set<String>, maxAge: TimeInterval? = nil) async -> [Instance]? {
        guard ensureDBReady() else { return nil }
        let selectedKey = keyFromSet(selectedBoxIPs)
        var sql = "SELECT payload, updated_at FROM instances_cache WHERE selected_key = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY updated_at DESC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: selectedKey)
        var rows: [Instance] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Instance.self, from: data) {
                rows.append(value)
            }
        }
        return rows.isEmpty ? nil : rows
    }
    
    func saveChats(instanceId: String, chats: [Chat]) async {
        guard ensureDBReady() else { return }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let deleteSQL = "DELETE FROM chats_cache WHERE instance_id = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: cleanInstanceId)
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
        let sql = """
        INSERT OR REPLACE INTO chats_cache
        (instance_id, jid, chat_row_id, last_timestamp, display_name, remark_name, phone, preview_text, payload, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in chats {
            let jid = (item.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty, let data = try? encoder.encode(item) else { continue }
            let preview = item.last_message?.text_data ?? ""
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: cleanInstanceId)
            bindText(stmt, index: 2, value: jid)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(item.chat_row_id ?? 0))
            sqlite3_bind_int64(stmt, 4, sqlite3_int64(item.last_message?.timestamp ?? 0))
            bindText(stmt, index: 5, value: item.display_name ?? "")
            bindText(stmt, index: 6, value: item.remark_name ?? "")
            bindText(stmt, index: 7, value: item.phone ?? "")
            bindText(stmt, index: 8, value: preview)
            bindBlob(stmt, index: 9, data: data)
            sqlite3_bind_double(stmt, 10, now)
            _ = sqlite3_step(stmt)
        }
    }
    
    func loadChats(instanceId: String, maxAge: TimeInterval? = nil) async -> [Chat]? {
        guard ensureDBReady() else { return nil }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty else { return nil }
        var sql = "SELECT payload, updated_at FROM chats_cache WHERE instance_id = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY last_timestamp DESC, updated_at DESC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: cleanInstanceId)
        var rows: [Chat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Chat.self, from: data) {
                rows.append(value)
            }
        }
        return rows.isEmpty ? nil : rows
    }

    /// 对话搜索：优先走 SQLite（联系人索引 + 会话索引），返回命中会话键 instanceId_jid
    func searchConversationKeys(keyword: String, instanceIds: [String], limit: Int = 1200) async -> Set<String> {
        guard ensureDBReady() else { return [] }
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let ids = Array(Set(instanceIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [] }
        let like = "%\(q)%"

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let cappedLimit = max(50, min(5000, limit))
        var results = Set<String>()

        let contactsSQL = """
        SELECT instance_id || '_' || jid AS conv_key
        FROM contacts_cache
        WHERE instance_id IN (\(placeholders))
          AND (
            lower(COALESCE(remark_name, '')) LIKE ?
            OR lower(COALESCE(display_name, '')) LIKE ?
            OR lower(COALESCE(number, '')) LIKE ?
            OR lower(COALESCE(jid, '')) LIKE ?
          )
        LIMIT ?;
        """
        if let stmt = prepare(contactsSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    results.insert(String(cString: c))
                }
            }
        }

        let chatsSQL = """
        SELECT instance_id || '_' || jid AS conv_key
        FROM chats_cache
        WHERE instance_id IN (\(placeholders))
          AND (
            lower(COALESCE(remark_name, '')) LIKE ?
            OR lower(COALESCE(display_name, '')) LIKE ?
            OR lower(COALESCE(phone, '')) LIKE ?
            OR lower(COALESCE(preview_text, '')) LIKE ?
            OR lower(COALESCE(jid, '')) LIKE ?
          )
        ORDER BY last_timestamp DESC
        LIMIT ?;
        """
        if let stmt = prepare(chatsSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    results.insert(String(cString: c))
                }
            }
        }

        let messageTextSQL = """
        SELECT c.instance_id || '_' || c.jid AS conv_key, MAX(COALESCE(m.sort_timestamp, 0)) AS max_ts
        FROM messages_cache m
        JOIN chats_cache c
          ON c.instance_id = m.instance_id
         AND c.chat_row_id = m.chat_row_id
        WHERE m.instance_id IN (\(placeholders))
          AND lower(CAST(m.payload AS TEXT)) LIKE ?
        GROUP BY c.instance_id, c.jid
        ORDER BY max_ts DESC
        LIMIT ?;
        """
        if let stmt = prepare(messageTextSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    results.insert(String(cString: c))
                }
            }
        }

        let translationSQL = """
        SELECT c.instance_id || '_' || c.jid AS conv_key, MAX(COALESCE(t.updated_at, 0)) AS max_ts
        FROM message_translations_cache t
        JOIN chats_cache c
          ON c.instance_id = t.instance_id
         AND c.chat_row_id = t.chat_row_id
        WHERE t.instance_id IN (\(placeholders))
          AND lower(COALESCE(t.translated_text, '')) LIKE ?
        GROUP BY c.instance_id, c.jid
        ORDER BY max_ts DESC
        LIMIT ?;
        """
        if let stmt = prepare(translationSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    results.insert(String(cString: c))
                }
            }
        }

        sqliteLog("searchConversationKeys keyword=\(q) ids=\(ids.count) hit=\(results.count)")
        return results
    }

    /// 对话搜索片段：按会话返回命中的消息/翻译片段（用于“会话分组展示”）
    func searchConversationSnippets(
        keyword: String,
        instanceIds: [String],
        perConversation: Int = 3,
        limit: Int = 3000
    ) async -> [String: [ConversationSearchHitSnippet]] {
        guard ensureDBReady() else { return [:] }
        let q = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [:] }
        let ids = Array(Set(instanceIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let like = "%\(q)%"
        let cappedLimit = max(200, min(8000, limit))
        let capPerConversation = max(1, min(120, perConversation))
        var grouped: [String: [ConversationSearchHitSnippet]] = [:]

        let messageSQL = """
        SELECT c.instance_id, c.jid, m.message_key, COALESCE(m.sort_timestamp, 0), m.payload
        FROM messages_cache m
        JOIN chats_cache c
          ON c.instance_id = m.instance_id
         AND c.chat_row_id = m.chat_row_id
        WHERE m.instance_id IN (\(placeholders))
          AND lower(CAST(m.payload AS TEXT)) LIKE ?
        ORDER BY COALESCE(m.sort_timestamp, 0) DESC
        LIMIT ?;
        """
        if let stmt = prepare(messageSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let instC = sqlite3_column_text(stmt, 0),
                      let jidC = sqlite3_column_text(stmt, 1),
                      let keyC = sqlite3_column_text(stmt, 2),
                      let blob = sqlite3_column_blob(stmt, 4) else { continue }
                let instanceId = String(cString: instC)
                let jid = String(cString: jidC)
                let messageKey = String(cString: keyC)
                let ts = Int64(sqlite3_column_int64(stmt, 3))
                let len = Int(sqlite3_column_bytes(stmt, 4))
                let payload = Data(bytes: blob, count: len)
                guard let msg = try? decoder.decode(Message.self, from: payload) else { continue }
                let raw = (msg.text_data ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let text = raw.isEmpty ? messageTypePlaceholder(msg.message_type) : raw
                guard !text.isEmpty else { continue }
                guard text.lowercased().contains(q) else { continue }
                let convKey = "\(instanceId)_\(jid)"
                let snippet = ConversationSearchHitSnippet(
                    instanceId: instanceId,
                    jid: jid,
                    messageKey: messageKey,
                    messageID: msg.message_id,
                    text: text,
                    timestamp: ts > 0 ? ts : (msg.timestamp ?? 0),
                    isTranslation: false
                )
                var arr = grouped[convKey] ?? []
                if !arr.contains(where: { $0.messageKey == messageKey && !$0.isTranslation }) {
                    arr.append(snippet)
                    grouped[convKey] = arr
                }
            }
        }

        let translationSQL = """
        SELECT c.instance_id, c.jid, t.message_key, COALESCE(t.updated_at, 0), t.translated_text
        FROM message_translations_cache t
        JOIN chats_cache c
          ON c.instance_id = t.instance_id
         AND c.chat_row_id = t.chat_row_id
        WHERE t.instance_id IN (\(placeholders))
          AND lower(COALESCE(t.translated_text, '')) LIKE ?
        ORDER BY COALESCE(t.updated_at, 0) DESC
        LIMIT ?;
        """
        if let stmt = prepare(translationSQL) {
            defer { sqlite3_finalize(stmt) }
            var bindIdx: Int32 = 1
            for id in ids {
                bindText(stmt, index: bindIdx, value: id)
                bindIdx += 1
            }
            bindText(stmt, index: bindIdx, value: like); bindIdx += 1
            sqlite3_bind_int(stmt, bindIdx, Int32(cappedLimit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let instC = sqlite3_column_text(stmt, 0),
                      let jidC = sqlite3_column_text(stmt, 1),
                      let keyC = sqlite3_column_text(stmt, 2),
                      let txtC = sqlite3_column_text(stmt, 4) else { continue }
                let instanceId = String(cString: instC)
                let jid = String(cString: jidC)
                let messageKey = String(cString: keyC)
                let text = String(cString: txtC).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let ts = Int64(sqlite3_column_double(stmt, 3) * 1000)
                let convKey = "\(instanceId)_\(jid)"
                let snippet = ConversationSearchHitSnippet(
                    instanceId: instanceId,
                    jid: jid,
                    messageKey: messageKey,
                    messageID: nil,
                    text: text,
                    timestamp: ts,
                    isTranslation: true
                )
                var arr = grouped[convKey] ?? []
                if !arr.contains(where: { $0.messageKey == messageKey && $0.isTranslation }) {
                    arr.append(snippet)
                    grouped[convKey] = arr
                }
            }
        }

        for key in grouped.keys {
            let sorted = (grouped[key] ?? []).sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.messageKey > rhs.messageKey
            }
            grouped[key] = Array(sorted.prefix(capPerConversation))
        }
        return grouped
    }
    
    func saveContacts(instanceId: String, contacts: [Contact]) async {
        guard ensureDBReady() else { return }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let deleteSQL = "DELETE FROM contacts_cache WHERE instance_id = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: cleanInstanceId)
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
        let sql = """
        INSERT OR REPLACE INTO contacts_cache
        (instance_id, jid, number, display_name, remark_name, payload, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in contacts {
            let jid = (item.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !jid.isEmpty, let data = try? encoder.encode(item) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: cleanInstanceId)
            bindText(stmt, index: 2, value: jid)
            bindText(stmt, index: 3, value: item.number ?? "")
            bindText(stmt, index: 4, value: item.display_name ?? "")
            bindText(stmt, index: 5, value: item.remark_name ?? "")
            bindBlob(stmt, index: 6, data: data)
            sqlite3_bind_double(stmt, 7, now)
            _ = sqlite3_step(stmt)
        }
        sqliteLog("saveContacts instance=\(cleanInstanceId) count=\(contacts.count)")
    }
    
    func loadContacts(instanceId: String, maxAge: TimeInterval? = nil) async -> [Contact]? {
        guard ensureDBReady() else { return nil }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty else { return nil }
        var sql = "SELECT payload, updated_at FROM contacts_cache WHERE instance_id = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY COALESCE(remark_name, ''), COALESCE(display_name, ''), COALESCE(number, '') COLLATE NOCASE ASC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: cleanInstanceId)
        var rows: [Contact] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Contact.self, from: data) {
                rows.append(value)
            }
        }
        sqliteLog("loadContacts instance=\(cleanInstanceId) count=\(rows.count)")
        return rows.isEmpty ? nil : rows
    }

    func saveGroupUsers(instanceId: String, groupJidRowId: Int, users: [GroupUser]) async {
        guard ensureDBReady() else { return }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty, groupJidRowId > 0 else { return }
        let now = Date().timeIntervalSince1970

        let deleteSQL = "DELETE FROM group_users_cache WHERE instance_id = ? AND group_jid_row_id = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: cleanInstanceId)
            sqlite3_bind_int64(deleteStmt, 2, sqlite3_int64(groupJidRowId))
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }

        let insertSQL = """
        INSERT OR REPLACE INTO group_users_cache
        (instance_id, group_jid_row_id, member_jid, instance_group_user_id, payload, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(insertSQL) else { return }
        defer { sqlite3_finalize(stmt) }
        for item in users {
            let memberJid = (item.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !memberJid.isEmpty, let data = try? encoder.encode(item) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: cleanInstanceId)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(groupJidRowId))
            bindText(stmt, index: 3, value: memberJid)
            sqlite3_bind_int64(stmt, 4, sqlite3_int64(item.mergedGroupUserID))
            bindBlob(stmt, index: 5, data: data)
            sqlite3_bind_double(stmt, 6, now)
            _ = sqlite3_step(stmt)
        }
        sqliteLog("saveGroupUsers instance=\(cleanInstanceId) group=\(groupJidRowId) count=\(users.count)")
    }

    func loadGroupUsers(instanceId: String, groupJidRowId: Int, maxAge: TimeInterval? = nil) async -> [GroupUser]? {
        guard ensureDBReady() else { return nil }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty, groupJidRowId > 0 else { return nil }
        var sql = """
        SELECT payload, updated_at
        FROM group_users_cache
        WHERE instance_id = ? AND group_jid_row_id = ?
        """
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY instance_group_user_id ASC, member_jid ASC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: cleanInstanceId)
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(groupJidRowId))
        var rows: [GroupUser] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(GroupUser.self, from: data) {
                rows.append(value)
            }
        }
        sqliteLog("loadGroupUsers instance=\(cleanInstanceId) group=\(groupJidRowId) count=\(rows.count)")
        return rows.isEmpty ? nil : rows
    }

    /// 备注即时回写：联系人备注更新成功后，立刻更新本地联系人/会话缓存，避免等待下一次拉取。
    func updateContactRemark(instanceId: String, jid: String, remarkName: String) async {
        guard ensureDBReady() else { return }
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJid = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInstanceId.isEmpty, !cleanJid.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let cleanRemark = remarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        var contactsUpdated = false
        var chatsUpdated = false
        var pendingUpdated = false

        // 1) contacts_cache: 更新 remark_name 与 payload
        let contactSelectSQL = "SELECT payload FROM contacts_cache WHERE instance_id = ? AND jid = ? LIMIT 1;"
        if let selectStmt = prepare(contactSelectSQL) {
            defer { sqlite3_finalize(selectStmt) }
            bindText(selectStmt, index: 1, value: cleanInstanceId)
            bindText(selectStmt, index: 2, value: cleanJid)
            if sqlite3_step(selectStmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(selectStmt, 0) {
                let len = Int(sqlite3_column_bytes(selectStmt, 0))
                let data = Data(bytes: blob, count: len)
                if var contact = try? decoder.decode(Contact.self, from: data) {
                    contact.remark_name = cleanRemark
                    if let encoded = try? encoder.encode(contact),
                       let updateStmt = prepare("UPDATE contacts_cache SET remark_name = ?, payload = ?, updated_at = ? WHERE instance_id = ? AND jid = ?;") {
                        bindText(updateStmt, index: 1, value: cleanRemark)
                        bindBlob(updateStmt, index: 2, data: encoded)
                        sqlite3_bind_double(updateStmt, 3, now)
                        bindText(updateStmt, index: 4, value: cleanInstanceId)
                        bindText(updateStmt, index: 5, value: cleanJid)
                        contactsUpdated = sqlite3_step(updateStmt) == SQLITE_DONE
                        sqlite3_finalize(updateStmt)
                    }
                }
            }
        }

        // 2) chats_cache: 更新 chat payload 中的 remark_name，保证会话页/聊天页标题即时一致
        let chatSelectSQL = "SELECT payload FROM chats_cache WHERE instance_id = ? AND jid = ? LIMIT 1;"
        if let chatStmt = prepare(chatSelectSQL) {
            defer { sqlite3_finalize(chatStmt) }
            bindText(chatStmt, index: 1, value: cleanInstanceId)
            bindText(chatStmt, index: 2, value: cleanJid)
            if sqlite3_step(chatStmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(chatStmt, 0) {
                let len = Int(sqlite3_column_bytes(chatStmt, 0))
                let data = Data(bytes: blob, count: len)
                if var chat = try? decoder.decode(Chat.self, from: data) {
                    chat.remark_name = cleanRemark
                    if let encoded = try? encoder.encode(chat),
                       let updateStmt = prepare("UPDATE chats_cache SET payload = ?, updated_at = ? WHERE instance_id = ? AND jid = ?;") {
                        bindBlob(updateStmt, index: 1, data: encoded)
                        sqlite3_bind_double(updateStmt, 2, now)
                        bindText(updateStmt, index: 3, value: cleanInstanceId)
                        bindText(updateStmt, index: 4, value: cleanJid)
                        chatsUpdated = sqlite3_step(updateStmt) == SQLITE_DONE
                        sqlite3_finalize(updateStmt)
                    }
                }
            }
        }

        // 3) pending_chats_cache: 新建会话种子也同步备注，避免会话列表回退成手机号
        let pendingSelectSQL = "SELECT payload FROM pending_chats_cache WHERE instance_id = ? AND jid = ? LIMIT 1;"
        if let pendingStmt = prepare(pendingSelectSQL) {
            defer { sqlite3_finalize(pendingStmt) }
            bindText(pendingStmt, index: 1, value: cleanInstanceId)
            bindText(pendingStmt, index: 2, value: cleanJid)
            if sqlite3_step(pendingStmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(pendingStmt, 0) {
                let len = Int(sqlite3_column_bytes(pendingStmt, 0))
                let data = Data(bytes: blob, count: len)
                if var chat = try? decoder.decode(Chat.self, from: data) {
                    chat.remark_name = cleanRemark
                    if let encoded = try? encoder.encode(chat),
                       let updateStmt = prepare("UPDATE pending_chats_cache SET payload = ?, updated_at = ? WHERE instance_id = ? AND jid = ?;") {
                        bindBlob(updateStmt, index: 1, data: encoded)
                        sqlite3_bind_double(updateStmt, 2, now)
                        bindText(updateStmt, index: 3, value: cleanInstanceId)
                        bindText(updateStmt, index: 4, value: cleanJid)
                        pendingUpdated = sqlite3_step(updateStmt) == SQLITE_DONE
                        sqlite3_finalize(updateStmt)
                    }
                }
            }
        }
        sqliteLog("updateContactRemark instance=\(cleanInstanceId) jid=\(cleanJid) remark=\(cleanRemark) contacts=\(contactsUpdated) chats=\(chatsUpdated) pending=\(pendingUpdated)")
    }
    
    /// 本地新建会话种子：用于服务端尚未同步时保持会话在“全部对话”可见，重启后仍保留
    func upsertPendingConversation(instanceId: String, chat: Chat) async {
        guard let jidRaw = chat.jid else { return }
        let jid = jidRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jid.isEmpty else { return }
        guard ensureDBReady() else { return }
        guard let data = try? encoder.encode(chat) else { return }
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT OR REPLACE INTO pending_chats_cache
        (instance_id, jid, payload, updated_at)
        VALUES (?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: instanceId)
        bindText(stmt, index: 2, value: jid)
        bindBlob(stmt, index: 3, data: data)
        sqlite3_bind_double(stmt, 4, now)
        _ = sqlite3_step(stmt)
    }
    
    func loadPendingConversations(instanceId: String, maxAge: TimeInterval? = nil) async -> [Chat] {
        guard ensureDBReady() else { return [] }
        var sql = "SELECT payload, updated_at FROM pending_chats_cache WHERE instance_id = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY updated_at DESC;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: instanceId)
        var rows: [Chat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Chat.self, from: data) {
                rows.append(value)
            }
        }
        return rows
    }
    
    func removePendingConversation(instanceId: String, jid: String) async {
        let cleanJid = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanJid.isEmpty else { return }
        guard ensureDBReady() else { return }
        let sql = "DELETE FROM pending_chats_cache WHERE instance_id = ? AND jid = ?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: instanceId)
        bindText(stmt, index: 2, value: cleanJid)
        _ = sqlite3_step(stmt)
    }
    
    func saveMessages(instanceId: String, chatRowId: Int, messages: [Message], keepLast: Int = 600) async {
        let trimmed = Array(messages.suffix(max(1, keepLast)))
        guard ensureDBReady() else { return }
        let deleteSQL = "DELETE FROM messages_cache WHERE instance_id = ? AND chat_row_id = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: instanceId)
            sqlite3_bind_int64(deleteStmt, 2, sqlite3_int64(chatRowId))
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT OR REPLACE INTO messages_cache
        (instance_id, chat_row_id, message_key, sort_timestamp, sort_message_id, payload, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for (idx, msg) in trimmed.enumerated() {
            guard let data = try? encoder.encode(msg) else { continue }
            let key = messageCacheKey(msg, fallbackIndex: idx)
            let sortTs = msg.timestamp ?? 0
            let sortMid = Int64(msg.message_id ?? Int.max - 1000 + idx)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: instanceId)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(chatRowId))
            bindText(stmt, index: 3, value: key)
            sqlite3_bind_int64(stmt, 4, sqlite3_int64(sortTs))
            sqlite3_bind_int64(stmt, 5, sqlite3_int64(sortMid))
            bindBlob(stmt, index: 6, data: data)
            sqlite3_bind_double(stmt, 7, now)
            _ = sqlite3_step(stmt)
        }
    }
    
    func loadMessages(instanceId: String, chatRowId: Int, maxAge: TimeInterval? = nil) async -> [Message]? {
        guard ensureDBReady() else { return nil }
        var sql = "SELECT payload, updated_at FROM messages_cache WHERE instance_id = ? AND chat_row_id = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += " ORDER BY sort_timestamp ASC, sort_message_id ASC;"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: instanceId)
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(chatRowId))
        var rows: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let value = try? decoder.decode(Message.self, from: data) {
                rows.append(value)
            }
        }
        return rows.isEmpty ? nil : rows
    }
    
    func saveMessageTranslations(instanceId: String, chatRowId: Int, translations: [String: String]) async {
        guard ensureDBReady() else { return }
        let now = Date().timeIntervalSince1970
        let deleteSQL = "DELETE FROM message_translations_cache WHERE instance_id = ? AND chat_row_id = ?;"
        if let deleteStmt = prepare(deleteSQL) {
            bindText(deleteStmt, index: 1, value: instanceId)
            sqlite3_bind_int64(deleteStmt, 2, sqlite3_int64(chatRowId))
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
        let sql = """
        INSERT OR REPLACE INTO message_translations_cache
        (instance_id, chat_row_id, message_key, translated_text, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for (key, value) in translations {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, index: 1, value: instanceId)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(chatRowId))
            bindText(stmt, index: 3, value: key)
            bindText(stmt, index: 4, value: value)
            sqlite3_bind_double(stmt, 5, now)
            _ = sqlite3_step(stmt)
        }
    }
    
    func loadMessageTranslations(instanceId: String, chatRowId: Int, maxAge: TimeInterval? = nil) async -> [String: String]? {
        guard ensureDBReady() else { return nil }
        var sql = "SELECT message_key, translated_text, updated_at FROM message_translations_cache WHERE instance_id = ? AND chat_row_id = ?"
        if let maxAge {
            let threshold = Date().timeIntervalSince1970 - maxAge
            sql += " AND updated_at >= \(threshold)"
        }
        sql += ";"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: instanceId)
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(chatRowId))
        var dict: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(stmt, 0),
                  let valC = sqlite3_column_text(stmt, 1) else { continue }
            let key = String(cString: keyC)
            let val = String(cString: valC)
            dict[key] = val
        }
        return dict.isEmpty ? nil : dict
    }
    
    func removeCurrentUserCache() async {
        let dir = userScopedDir()
        let dirPath = dir.path
        if let opened = openedDBPath, opened.hasPrefix(dirPath) {
            closeDB()
        }
        try? fm.removeItem(at: dir)
    }
    
    private func ensureDBReady() -> Bool {
        let dir = userScopedDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(dbFileName).path
        if db != nil, openedDBPath == path {
            if !didRunChatsCacheMigration {
                _ = migrateChatsCacheSchema()
            }
            return true
        }
        closeDB()
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              db != nil else {
            closeDB()
            return false
        }
        openedDBPath = path
        _ = execute("PRAGMA journal_mode=WAL;")
        _ = execute("PRAGMA synchronous=NORMAL;")
        _ = execute("PRAGMA foreign_keys=ON;")
        didRunChatsCacheMigration = false
        sqliteLog("open db path=\(path)")
        return createSchema()
    }
    
    private func createSchema() -> Bool {
        let sqlList: [String] = [
            """
            CREATE TABLE IF NOT EXISTS boxes_cache (
                box_key TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS instances_cache (
                selected_key TEXT NOT NULL,
                instance_key TEXT NOT NULL,
                instance_id_for_api TEXT NOT NULL,
                box_ip TEXT,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (selected_key, instance_key)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_instances_selected ON instances_cache(selected_key);",
            "CREATE INDEX IF NOT EXISTS idx_instances_api ON instances_cache(instance_id_for_api);",
            "CREATE INDEX IF NOT EXISTS idx_instances_box_ip ON instances_cache(box_ip);",
            """
            CREATE TABLE IF NOT EXISTS chats_cache (
                instance_id TEXT NOT NULL,
                jid TEXT NOT NULL,
                chat_row_id INTEGER,
                last_timestamp INTEGER,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, jid)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_chats_instance_ts ON chats_cache(instance_id, last_timestamp DESC);",
            """
            CREATE TABLE IF NOT EXISTS pending_chats_cache (
                instance_id TEXT NOT NULL,
                jid TEXT NOT NULL,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, jid)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS contacts_cache (
                instance_id TEXT NOT NULL,
                jid TEXT NOT NULL,
                number TEXT,
                display_name TEXT,
                remark_name TEXT,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, jid)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_contacts_instance_name ON contacts_cache(instance_id, remark_name, display_name, number);",
            "CREATE INDEX IF NOT EXISTS idx_contacts_number ON contacts_cache(number);",
            """
            CREATE TABLE IF NOT EXISTS messages_cache (
                instance_id TEXT NOT NULL,
                chat_row_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                sort_timestamp INTEGER,
                sort_message_id INTEGER,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, chat_row_id, message_key)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_thread_sort ON messages_cache(instance_id, chat_row_id, sort_timestamp, sort_message_id);",
            """
            CREATE TABLE IF NOT EXISTS message_translations_cache (
                instance_id TEXT NOT NULL,
                chat_row_id INTEGER NOT NULL,
                message_key TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, chat_row_id, message_key)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS group_users_cache (
                instance_id TEXT NOT NULL,
                group_jid_row_id INTEGER NOT NULL,
                member_jid TEXT NOT NULL,
                instance_group_user_id INTEGER NOT NULL DEFAULT 0,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, group_jid_row_id, member_jid, instance_group_user_id)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_group_users_thread ON group_users_cache(instance_id, group_jid_row_id, instance_group_user_id, member_jid);"
        ]
        for sql in sqlList where !execute(sql) {
            return false
        }
        return migrateChatsCacheSchema()
    }
    
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        let ok = sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        if !ok, let err = sqlite3_errmsg(db) {
            sqliteLog("execute failed sql=\(sql) err=\(String(cString: err))")
        }
        return ok
    }
    
    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
    
    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }
    
    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                sqlite3_bind_blob(stmt, index, nil, 0, sqliteTransient)
                return
            }
            sqlite3_bind_blob(stmt, index, base, Int32(data.count), sqliteTransient)
        }
    }

    private func messageTypePlaceholder(_ type: Int?) -> String {
        switch type ?? 0 {
        case 1: return "[图片]"
        case 2: return "[语音]"
        case 3, 13: return "[视频]"
        case 9: return "[文件]"
        case 90: return "[通话]"
        default: return ""
        }
    }
    
    private func messageCacheKey(_ message: Message, fallbackIndex: Int) -> String {
        if let key = message.key_id?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let mid = message.message_id, mid > 0 {
            return "mid_\(mid)"
        }
        let ts = message.timestamp ?? 0
        return "tmp_\(ts)_\(fallbackIndex)"
    }
    
    private func closeDB() {
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
        openedDBPath = nil
        didRunChatsCacheMigration = false
    }

    @discardableResult
    private func ensureColumn(table: String, column: String, definition: String) -> Bool {
        guard let stmt = prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(stmt) }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let name = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: name).caseInsensitiveCompare(column) == .orderedSame {
                exists = true
                break
            }
        }
        if !exists {
            return execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
        return true
    }

    private func migrateChatsCacheSchema() -> Bool {
        let ok1 = ensureColumn(table: "chats_cache", column: "display_name", definition: "TEXT")
        let ok2 = ensureColumn(table: "chats_cache", column: "remark_name", definition: "TEXT")
        let ok3 = ensureColumn(table: "chats_cache", column: "phone", definition: "TEXT")
        let ok4 = ensureColumn(table: "chats_cache", column: "preview_text", definition: "TEXT")
        let ok5 = execute("CREATE INDEX IF NOT EXISTS idx_chats_instance_name ON chats_cache(instance_id, remark_name, display_name, phone);")
        let ok6 = execute("CREATE INDEX IF NOT EXISTS idx_chats_instance_ts ON chats_cache(instance_id, last_timestamp DESC);")
        let ok = ok1 && ok2 && ok3 && ok4 && ok5 && ok6
        if ok {
            didRunChatsCacheMigration = true
            sqliteLog("migrateChatsCacheSchema ok")
            return true
        }
        
        // 旧库异常兜底：重建 chats_cache，避免后续持续写入失败导致首屏回填变慢。
        sqliteLog("migrateChatsCacheSchema fallback: rebuild chats_cache")
        let rebuilt = rebuildChatsCacheTable()
        didRunChatsCacheMigration = rebuilt
        return rebuilt
    }
    
    private func rebuildChatsCacheTable() -> Bool {
        guard execute("DROP TABLE IF EXISTS chats_cache;") else { return false }
        guard execute(
            """
            CREATE TABLE IF NOT EXISTS chats_cache (
                instance_id TEXT NOT NULL,
                jid TEXT NOT NULL,
                chat_row_id INTEGER,
                last_timestamp INTEGER,
                display_name TEXT,
                remark_name TEXT,
                phone TEXT,
                preview_text TEXT,
                payload BLOB NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (instance_id, jid)
            );
            """
        ) else { return false }
        guard execute("CREATE INDEX IF NOT EXISTS idx_chats_instance_ts ON chats_cache(instance_id, last_timestamp DESC);") else { return false }
        guard execute("CREATE INDEX IF NOT EXISTS idx_chats_instance_name ON chats_cache(instance_id, remark_name, display_name, phone);") else { return false }
        return true
    }
    
    private func userScopedDir() -> URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let uid = APIClient.shared.userID ?? "guest"
        return base
            .appendingPathComponent(rootFolder, isDirectory: true)
            .appendingPathComponent("u_\(safeKey(uid))", isDirectory: true)
    }
    
    private func safeKey(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9_\\-]+", with: "_", options: .regularExpression)
    }
    
    private func keyFromSet(_ set: Set<String>) -> String {
        safeKey(set.sorted().joined(separator: ","))
    }
}
