//
//  ChatService.swift
//  WudiApp
//
//  与 H5 whatsapp.ts 一致：getChats(instance_id)、getContacts(instance_id)，用于账号页进入会话后的对话/联系人列表。
//

import Foundation

#if DEBUG
private let debugLogEnabled = false
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {
    guard debugLogEnabled else { return }
    print(message())
}
private let aiStreamLogEnabled = false
@inline(__always) private func aiStreamLog(_ message: @autoclosure () -> String) {
    guard aiStreamLogEnabled else { return }
    print("[AIStream] \(message())")
}
private let customerDebugLogEnabled = false
@inline(__always) private func customerDebugLog(_ message: @autoclosure () -> String) {
    guard customerDebugLogEnabled else { return }
    print(message())
}
private let groupUsersLogEnabled = false
@inline(__always) private func groupUsersLog(_ message: @autoclosure () -> String) {
    guard groupUsersLogEnabled else { return }
    print("[GroupUsers] \(message())")
}
private let scrmSendLogEnabled = false
@inline(__always) private func scrmSendLog(_ message: @autoclosure () -> String) {
    guard scrmSendLogEnabled else { return }
    print("[SCRM Send] \(message())")
}
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func aiStreamLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func customerDebugLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func groupUsersLog(_ message: @autoclosure () -> String) {}
@inline(__always) private func scrmSendLog(_ message: @autoclosure () -> String) {}
#endif

private actor MediaStreamCacheStore {
    static let shared = MediaStreamCacheStore()
    
    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private let memoryLimit = 120
    private let diskFolder = "media_stream_cache_v1"
    
    func load(_ key: String, maxAge: TimeInterval = 24 * 3600) async -> Data? {
        if let cached = memory[key] {
            return cached
        }
        let fileURL = diskURL(for: key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            remember(key: key, data: data)
            return data
        }
        if Date().timeIntervalSince(modified) > maxAge {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        remember(key: key, data: data)
        return data
    }
    
    func save(_ key: String, data: Data) async {
        remember(key: key, data: data)
        let fileURL = diskURL(for: key)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
    
    func remove(_ key: String) async {
        memory.removeValue(forKey: key)
        order.removeAll { $0 == key }
        let fileURL = diskURL(for: key)
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    private func remember(key: String, data: Data) {
        memory[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > memoryLimit {
            let first = order.removeFirst()
            memory.removeValue(forKey: first)
        }
    }
    
    private func diskURL(for key: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent(diskFolder, isDirectory: true)
            .appendingPathComponent(key)
    }
}

// MARK: - 对话项（与 H5 响应一致：chat_row_id 为数字，last_message 含 message_type/text_data/timestamp，avatar 为 base64）
struct Chat: Codable, Identifiable {
    var chat_row_id: Int?
    var jid_row_id: Int?
    var jid: String?
    var remark_name: String?
    var display_name: String?
    var phone: String?
    var avatar: String?  // base64，与 H5 itemData.avatar 一致
    var newMessageCount: Int?
    var last_message: LastMessage?
    
    var id: String { "\(chat_row_id ?? 0)_\(jid ?? "")" }
    
    enum CodingKeys: String, CodingKey {
        case chat_row_id, jid_row_id, jid, remark_name, display_name, phone, avatar, last_message
        case newMessageCount = "new_message_count"
    }
}

struct LastMessage: Codable {
    var message_type: Int?
    var text_data: String?
    var timestamp: Int64?
}

// MARK: - 单条消息（与 H5 Message 一致，用于聊天页消息列表）
struct Message: Codable, Identifiable {
    var message_id: Int?
    var sort_id: Int?
    var key_id: String?
    var from_me: Int?
    var key_from_me: Int?
    var text_data: String?
    var timestamp: Int64?
    var message_type: Int?
    var status: Int?
    var sender: String?
    var sender_name: String?
    var media_file_path: String?
    var media_url: String?
    var media_key: String?
    var reaction: String?
    var quote_message: QuotedMessage? = nil
    
    var id: String { key_id ?? "\(message_id ?? 0)" }
    
    enum CodingKeys: String, CodingKey {
        case message_id = "id"
        case sort_id
        case key_id
        case from_me
        case key_from_me
        case text_data = "data"
        case timestamp
        case message_type
        case status
        case sender
        case sender_name
        case media_file_path
        case media_url
        case media_key
        case reaction
        case quote_message
    }
}

struct QuotedMessage: Codable, Identifiable {
    var message_id: Int?
    var sort_id: Int?
    var key_id: String?
    var from_me: Int?
    var key_from_me: Int?
    var data: String?
    var text_data: String?
    var timestamp: Int64?
    var message_type: Int?
    var sender: String?
    var sender_name: String?
    var media_file_path: String?
    var media_url: String?
    var media_key: String?
    var reaction: String?
    
    var id: String { key_id ?? "\(message_id ?? 0)" }
    
    enum CodingKeys: String, CodingKey {
        case message_id = "id"
        case sort_id
        case key_id
        case from_me
        case key_from_me
        case data
        case text_data
        case timestamp
        case message_type
        case sender
        case sender_name
        case media_file_path
        case media_url
        case media_key
        case reaction
    }
}

enum MessageDeliveryState {
    case localProcessing
    case pendingSync
    case sending
    case failed
    case sent
    case delivered
    case read
    case unknown
    
    var isTransient: Bool {
        switch self {
        case .localProcessing, .pendingSync, .sending:
            return true
        default:
            return false
        }
    }
}

extension Message {
    var deliveryState: MessageDeliveryState {
        let s = status ?? 0
        switch s {
        case 999: return .localProcessing
        case 998: return .pendingSync
        case 0, 1: return .sending
        case 997: return .failed
        case 4: return .sent
        // 兼容不同来源状态码：2/5=送达，3/13=已读
        case 2, 5: return .delivered
        case 3, 13: return .read
        default: return .unknown
        }
    }
    
    var isDeletedMessage: Bool {
        (message_type ?? 0) == 15
    }
}

struct MessageDetailResponse: Decodable {
    var messageID: Int?
    var keyID: String?
    var textData: String?
    var timestamp: Int64?
    var messageType: Int?
    var status: Int?
    var mediaFilePath: String?
    var mediaURL: String?
    var mediaKey: String?
    var reaction: String?
    
    enum CodingKeys: String, CodingKey {
        case messageID = "id"
        case keyID = "key_id"
        case data
        case text_data
        case timestamp
        case messageType = "message_type"
        case status
        case file_path
        case media_file_path
        case mediaURL = "media_url"
        case mediaKey = "media_key"
        case reaction
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try c.decodeIfPresent(Int.self, forKey: .messageID)
        keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
        let textDataPrimary = try c.decodeIfPresent(String.self, forKey: .text_data)
        let textDataFallback = try c.decodeIfPresent(String.self, forKey: .data)
        textData = textDataPrimary ?? textDataFallback
        timestamp = try c.decodeIfPresent(Int64.self, forKey: .timestamp)
        messageType = try c.decodeIfPresent(Int.self, forKey: .messageType)
        status = try c.decodeIfPresent(Int.self, forKey: .status)
        let mediaPathPrimary = try c.decodeIfPresent(String.self, forKey: .media_file_path)
        let mediaPathFallback = try c.decodeIfPresent(String.self, forKey: .file_path)
        mediaFilePath = mediaPathPrimary ?? mediaPathFallback
        mediaURL = try c.decodeIfPresent(String.self, forKey: .mediaURL)
        mediaKey = try c.decodeIfPresent(String.self, forKey: .mediaKey)
        reaction = try c.decodeIfPresent(String.self, forKey: .reaction)
    }
}

private struct MessagesResponse: Decodable {
    let messages: [Message]?
}

private struct MessagesDataResponse: Decodable {
    let data: MessagesData?
    struct MessagesData: Decodable {
        let messages: [Message]?
    }
}

// MARK: - 联系人项（与 H5 contact 一致）
struct Contact: Codable, Identifiable {
    var contact_id: Int?
    var jid: String?
    var display_name: String?
    var number: String?
    var remark_name: String?
    var avatar: String?  // base64
    var is_whatsapp_user: Int?
    
    var id: String { jid ?? "\(contact_id ?? 0)" }
    
    enum CodingKeys: String, CodingKey {
        case contact_id, jid, display_name, number, remark_name, avatar
        case is_whatsapp_user = "is_whatsapp_user"
    }
}

/// 群成员项（与 web_h5 /api/v2/group/*/users 返回字段对齐）
struct GroupUser: Codable, Identifiable, Hashable {
    var id: String {
        let gid = instance_group_user_id ?? InstanceGroupUserID ?? 0
        return "\(gid)_\(jid ?? "")"
    }
    var ID: Int?
    var InstanceID: Int?
    var CloneID: String?
    var InstanceGroupUserID: Int?
    var instance_group_user_id: Int?
    var group_jid_row_id: Int?
    var jid: String?
    var rank: Int?
    var display_name: String?
    var remark_name: String?
    
    var mergedGroupUserID: Int {
        instance_group_user_id ?? InstanceGroupUserID ?? 0
    }
    
    enum CodingKeys: String, CodingKey {
        case ID
        case InstanceID
        case CloneID
        case InstanceGroupUserID
        case instance_group_user_id
        case group_jid_row_id
        case jid
        case rank
        case display_name
        case remark_name
    }
}

struct CustomerUserInfo: Codable {
    var name: String?
    var remark: String?
    var age: String?
    var source: String?
    var industry: String?
    var occupation: String?
    var family_status: String?
    var annual_income: String?
    var profile: String?
    var profile_photo: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case remark
        case age
        case source
        case industry
        case occupation
        case family_status
        case familyStatus
        case annual_income
        case annualIncome
        case profile
        case profile_photo
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        remark = try c.decodeIfPresent(String.self, forKey: .remark)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        industry = try c.decodeIfPresent(String.self, forKey: .industry)
        occupation = try c.decodeIfPresent(String.self, forKey: .occupation)
        family_status = try c.decodeIfPresent(String.self, forKey: .family_status) ?? c.decodeIfPresent(String.self, forKey: .familyStatus)
        annual_income = try c.decodeIfPresent(String.self, forKey: .annual_income) ?? c.decodeIfPresent(String.self, forKey: .annualIncome)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        profile_photo = try c.decodeIfPresent(String.self, forKey: .profile_photo)
        if let ageInt = try c.decodeIfPresent(Int.self, forKey: .age) {
            age = "\(ageInt)"
        } else if let ageDouble = try c.decodeIfPresent(Double.self, forKey: .age) {
            age = String(Int(ageDouble))
        } else {
            age = try c.decodeIfPresent(String.self, forKey: .age)
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(remark, forKey: .remark)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(industry, forKey: .industry)
        try c.encodeIfPresent(occupation, forKey: .occupation)
        try c.encodeIfPresent(family_status, forKey: .family_status)
        try c.encodeIfPresent(annual_income, forKey: .annual_income)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(profile_photo, forKey: .profile_photo)
    }
    
    var hasMeaningfulValue: Bool {
        let candidates: [String?] = [
            name, remark, age, source, industry, occupation, family_status, annual_income, profile, profile_photo
        ]
        for raw in candidates {
            let clean = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                return true
            }
        }
        return false
    }
}

private struct CustomerUserInfoEnvelope: Codable {
    let success: Bool?
    let data: CustomerUserInfo?
}

struct FollowUpItem: Codable {
    var id: Int?
    var phone: String?
    var content: String?
    var createAt: String?
    var created_at: String?
    var createdAt: String?
    var creatorName: String?
    var createdByName: String?
    var ownerName: String?
    var username: String?
    var userName: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case phone
        case content
        case createAt
        case created_at
        case createdAt = "createdAt"
        case creatorName = "creator_name"
        case createdByName = "created_by_name"
        case ownerName = "owner_name"
        case username
        case userName = "user_name"
    }
    
    private enum ExtraCodingKeys: String, CodingKey {
        case contentText = "text"
        case createAtSnake = "create_at"
        case createAtCamel = "createAt"
        case creatorNameCamel = "creatorName"
        case createdByNameCamel = "createdByName"
        case ownerNameCamel = "ownerName"
        case userNameCamel = "userName"
        case createUserName = "create_user_name"
        case createUser = "create_user"
        case operatorName = "operator_name"
        case operatorNameCamel = "operatorName"
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ex = try decoder.container(keyedBy: ExtraCodingKeys.self)
        func pick(_ values: String?...) -> String? {
            for value in values {
                if let v = value {
                    return v
                }
            }
            return nil
        }
        
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        
        let contentPrimary = try c.decodeIfPresent(String.self, forKey: .content)
        let contentFallback = try ex.decodeIfPresent(String.self, forKey: .contentText)
        content = pick(contentPrimary, contentFallback)
        
        let createAtPrimary = try c.decodeIfPresent(String.self, forKey: .createAt)
        let createAtSnake = try ex.decodeIfPresent(String.self, forKey: .createAtSnake)
        let createAtCamel = try ex.decodeIfPresent(String.self, forKey: .createAtCamel)
        createAt = pick(createAtPrimary, createAtSnake, createAtCamel)
        
        let createdAtSnakePrimary = try c.decodeIfPresent(String.self, forKey: .created_at)
        created_at = pick(createdAtSnakePrimary, createAtSnake)
        
        let createdAtPrimary = try c.decodeIfPresent(String.self, forKey: .createdAt)
        createdAt = pick(createdAtPrimary, createAtCamel)
        
        let creatorNamePrimary = try c.decodeIfPresent(String.self, forKey: .creatorName)
        let creatorNameCamel = try ex.decodeIfPresent(String.self, forKey: .creatorNameCamel)
        let createUserName = try ex.decodeIfPresent(String.self, forKey: .createUserName)
        let createUser = try ex.decodeIfPresent(String.self, forKey: .createUser)
        let operatorName = try ex.decodeIfPresent(String.self, forKey: .operatorName)
        let operatorNameCamel = try ex.decodeIfPresent(String.self, forKey: .operatorNameCamel)
        creatorName = pick(creatorNamePrimary, creatorNameCamel, createUserName, createUser, operatorName, operatorNameCamel)
        
        let createdByPrimary = try c.decodeIfPresent(String.self, forKey: .createdByName)
        let createdByCamel = try ex.decodeIfPresent(String.self, forKey: .createdByNameCamel)
        createdByName = pick(createdByPrimary, createdByCamel)
        
        let ownerPrimary = try c.decodeIfPresent(String.self, forKey: .ownerName)
        let ownerCamel = try ex.decodeIfPresent(String.self, forKey: .ownerNameCamel)
        ownerName = pick(ownerPrimary, ownerCamel, operatorName, operatorNameCamel)
        
        let usernamePrimary = try c.decodeIfPresent(String.self, forKey: .username)
        username = pick(usernamePrimary, createUserName, createUser)
        
        let userNamePrimary = try c.decodeIfPresent(String.self, forKey: .userName)
        let userNameCamel = try ex.decodeIfPresent(String.self, forKey: .userNameCamel)
        userName = pick(userNamePrimary, userNameCamel)
    }
}

struct AIChatStreamMessage: Codable {
    let role: String
    let content: String
}

// MARK: - API 响应（兼容顶层 chats 或 data.chats）
private struct ChatsResponse: Decodable {
    let chats: [Chat]?
    let data: ChatsData?
    struct ChatsData: Decodable {
        let chats: [Chat]?
    }
}

final class ChatService {
    static let shared = ChatService()
    /// /api/v2 接口用 host 根路径，与 H5 一致（H5 请求为 http://host/api/v2/contacts，无 /gva_api）
    private let apiV2Base = APIConfig.host
    private var client: APIClient { APIClient.shared }
    
    private init() {}
    
    struct CallSCRMFuncParams {
        let instanceID: String
        let method: String
        let name: String
        let ip: String
        let index: Int
        let jid: String?
        let message: String?
        let contactName: String?
        let phoneOverride: String?
        let lastName: String?
        let firstName: String?
        let emoji: String?
        let quotedIndex: Int?
        let quotedText: String?
        let quotedType: Int?
        let quotedTimestamp: Int64?
        let appType: String?
        let cloneID: String?
        let targetLang: String?
        let imageData: Data?
        let imageFileName: String?
        let extraFields: [String: String]
        
        init(
            instanceID: String,
            method: String,
            name: String,
            ip: String,
            index: Int,
            jid: String?,
            message: String?,
            contactName: String?,
            phoneOverride: String? = nil,
            lastName: String? = nil,
            firstName: String? = nil,
            emoji: String?,
            quotedIndex: Int?,
            quotedText: String?,
            quotedType: Int?,
            quotedTimestamp: Int64?,
            appType: String?,
            cloneID: String?,
            targetLang: String?,
            imageData: Data?,
            imageFileName: String?,
            extraFields: [String: String] = [:]
        ) {
            self.instanceID = instanceID
            self.method = method
            self.name = name
            self.ip = ip
            self.index = index
            self.jid = jid
            self.message = message
            self.contactName = contactName
            self.phoneOverride = phoneOverride
            self.lastName = lastName
            self.firstName = firstName
            self.emoji = emoji
            self.quotedIndex = quotedIndex
            self.quotedText = quotedText
            self.quotedType = quotedType
            self.quotedTimestamp = quotedTimestamp
            self.appType = appType
            self.cloneID = cloneID
            self.targetLang = targetLang
            self.imageData = imageData
            self.imageFileName = imageFileName
            self.extraFields = extraFields
        }
    }
    
    struct CallSCRMFuncResult {
        let code: Int
        let msg: String?
        let taskID: String?
        let taskStatus: String?
    }
    
    struct RunningTaskStatus {
        let locked: Bool
        let type: String?
        let taskID: String?
    }

    struct SCRMTaskItem: Decodable, Identifiable {
        let taskID: String
        let instanceID: String
        let ip: String?
        let port: Int?
        let index: Int?
        let method: String?
        let name: String?
        let phone: String?
        let jid: String?
        let message: String?
        let contactName: String?
        let appType: String?
        let cloneID: String?
        let groupMembers: String?
        let imagePath: String?
        let status: String?
        let msg: String?
        let createdAt: Int64?
        let updatedAt: Int64?

        var id: String { taskID }

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case instanceID = "instance_id"
            case ip
            case port
            case index
            case method
            case name
            case phone
            case jid
            case message
            case contactName = "contact_name"
            case appType = "app_type"
            case cloneID = "clone_id"
            case groupMembers = "group_members"
            case imagePath = "image_path"
            case status
            case msg
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }
    
    /// 与 H5 AIChat.vue 一致：POST /api/v1/ai-chat/stream，按 SSE data: 增量返回（纯文本消息）
    func streamAIChat(messages: [AIChatStreamMessage], onDelta: @escaping (String) async -> Void) async throws {
        let rawMessages = messages.map { ["role": $0.role, "content": $0.content] as [String : Any] }
        try await streamAIChatRaw(messages: rawMessages, onDelta: onDelta)
    }
    
    /// 多模态版本：messages 支持 OpenAI 风格 content parts（text + image_url）
    func streamAIChatRaw(messages: [[String: Any]], onDelta: @escaping (String) async -> Void) async throws {
        let urlString = "\(apiV2Base)/api/v1/ai-chat/stream"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        request.timeoutInterval = 180
        let latestTextContent: String = {
            for message in messages.reversed() {
                guard let content = message["content"] else { continue }
                if let text = content as? String, !text.isEmpty { return text }
                if let parts = content as? [[String: Any]] {
                    for part in parts {
                        if let type = part["type"] as? String, type == "text",
                           let text = part["text"] as? String, !text.isEmpty {
                            return text
                        }
                    }
                }
            }
            return ""
        }()
        let payload: [String: Any] = [
            "messages": messages,
            "stream": true,
            "content": latestTextContent
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        aiStreamLog("request url=\(urlString) msgCount=\(messages.count) latestTextLen=\(latestTextContent.count)")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        aiStreamLog("response status=\(http.statusCode)")
        guard (200...299).contains(http.statusCode) else {
            throw httpStatusError(http.statusCode)
        }
        
        var receivedDataLines = 0
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            receivedDataLines += 1
            if receivedDataLines <= 3 {
                let preview = String(trimmed.prefix(180))
                aiStreamLog("sse line#\(receivedDataLines) preview=\(preview)")
            }
            let raw = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw == "[DONE]" || raw == "DONE" { continue }
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }
            let think = delta["reasoning_content"] as? String ?? ""
            let content = delta["content"] as? String ?? ""
            let piece = think + content
            if !piece.isEmpty {
                await onDelta(piece)
            }
        }
        aiStreamLog("stream end dataLines=\(receivedDataLines)")
    }
    
    /// GET /api/v2/chats?instance_id=xxx，需传 boxIP 以设置 box-ip 头（与 H5 一致）
    func getChats(instanceId: String, boxIP: String?) async throws -> [Chat] {
        let data = try await getApiV2(path: "/api/v2/chats", query: ["instance_id": instanceId], boxIP: boxIP)
        let res = try JSONDecoder().decode(ChatsResponse.self, from: data)
        return res.chats ?? res.data?.chats ?? []
    }
    
    /// GET /api/v2/chats/search?keyword=xxx（与 H5 searchBoxChats 一致）
    func searchBoxChats(keyword: String, boxIP: String) async throws -> [[String: Any]] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let data = try await getApiV2(path: "/api/v2/chats/search", query: ["keyword": key], boxIP: boxIP)
        if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return list
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let list = obj["data"] as? [[String: Any]] { return list }
            if let list = obj["list"] as? [[String: Any]] { return list }
            if let map = obj["data"] as? [String: Any], let list = map["list"] as? [[String: Any]] { return list }
        }
        return []
    }
    
    /// GET /api/v2/chats/{chat_row_id}/messages?page=&page_size=&instance_id=&sort_id=，与 H5 getChatMessages 一致
    func getMessages(chatRowId: Int, instanceId: String, boxIP: String?, page: Int = 1, pageSize: Int = 50, sortId: Int = 0) async throws -> [Message] {
        let path = "/api/v2/chats/\(chatRowId)/messages"
        let query: [String: String] = [
            "page": "\(page)",
            "page_size": "\(pageSize)",
            "instance_id": instanceId,
            "sort_id": "\(sortId)"
        ]
        let data = try await getApiV2(path: path, query: query, boxIP: boxIP)
        let decoder = JSONDecoder()
        if let res = try? decoder.decode(MessagesResponse.self, from: data), let list = res.messages, !list.isEmpty { return list }
        if let res = try? decoder.decode(MessagesDataResponse.self, from: data), let list = res.data?.messages, !list.isEmpty { return list }
        if let list = try? decoder.decode([Message].self, from: data) { return list }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = (obj["messages"] as? [[String: Any]]) ?? ((obj["data"] as? [String: Any])?["messages"] as? [[String: Any]]) {
            let listData = try JSONSerialization.data(withJSONObject: raw)
            return (try? decoder.decode([Message].self, from: listData)) ?? []
        }
        return []
    }
    
    /// GET /api/v2/contacts?instance_id=xxx，需传 boxIP 以设置 box-ip 头（与 H5 一致）
    func getContacts(instanceId: String, boxIP: String?) async throws -> [Contact] {
        do {
            let data = try await getApiV2(path: "/api/v2/contacts", query: ["instance_id": instanceId], boxIP: boxIP)
            let list: [Contact]
            if let direct = try? JSONDecoder().decode([Contact].self, from: data) {
                list = direct
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = obj["data"] as? [[String: Any]],
                      let listData = try? JSONSerialization.data(withJSONObject: raw),
                      let decoded = try? JSONDecoder().decode([Contact].self, from: listData) {
                list = decoded
            } else {
                list = []
            }
            await AppCacheStore.shared.saveContacts(instanceId: instanceId, contacts: list)
            return list
        } catch {
            if let cached = await AppCacheStore.shared.loadContacts(instanceId: instanceId, maxAge: nil), !cached.isEmpty {
                return cached
            }
            throw error
        }
    }
    
    /// GET /api/v2/group/{group_jid_row_id}/users?instance_id=xxx
    func getGroupUsersV2(instanceId: String, groupJidRowId: Int, boxIP: String?) async throws -> [GroupUser] {
        guard groupJidRowId > 0 else { return [] }
        groupUsersLog("service full request groupJidRowId=\(groupJidRowId) instanceId=\(instanceId) boxIP=\(boxIP ?? "")")
        let data = try await getApiV2(
            path: "/api/v2/group/\(groupJidRowId)/users",
            query: ["instance_id": instanceId],
            boxIP: boxIP
        )
        if let direct = try? JSONDecoder().decode([GroupUser].self, from: data) {
            groupUsersLog("service full decode direct count=\(direct.count) bytes=\(data.count)")
            return direct
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["data"] is NSNull {
            let msg = (obj["message"] as? String) ?? (obj["msg"] as? String) ?? ""
            groupUsersLog("service full decode empty(null) message=\(msg) bytes=\(data.count)")
            return []
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["data"] as? [[String: Any]],
           let listData = try? JSONSerialization.data(withJSONObject: raw),
           let list = try? JSONDecoder().decode([GroupUser].self, from: listData) {
            groupUsersLog("service full decode wrapped count=\(list.count) bytes=\(data.count)")
            return list
        }
        let preview = String(data: data.prefix(240), encoding: .utf8) ?? "<non-utf8>"
        groupUsersLog("service full decode failed bytes=\(data.count) preview=\(preview)")
        return []
    }
    
    /// GET /api/v2/group/{group_jid_row_id}/users/fetch
    /// query: instance_id, instance_group_user_id, 可选 box_ip/index（与 web_h5 一致）
    func getGroupUserBySQLiteV2(
        instanceId: String,
        groupJidRowId: Int,
        instanceGroupUserId: Int,
        boxIP: String?,
        index: Int?
    ) async throws -> [GroupUser] {
        guard groupJidRowId > 0 else { return [] }
        var query: [String: String] = [
            "instance_id": instanceId,
            "instance_group_user_id": "\(max(0, instanceGroupUserId))"
        ]
        if let ip = boxIP?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
            query["box_ip"] = ip
        }
        if let idx = index {
            query["index"] = "\(idx)"
        }
        groupUsersLog("service incremental request groupJidRowId=\(groupJidRowId) instanceId=\(instanceId) since=\(max(0, instanceGroupUserId)) boxIP=\(query["box_ip"] ?? "") index=\(query["index"] ?? "")")
        let data = try await getApiV2(
            path: "/api/v2/group/\(groupJidRowId)/users/fetch",
            query: query,
            boxIP: boxIP
        )
        if let direct = try? JSONDecoder().decode([GroupUser].self, from: data) {
            groupUsersLog("service incremental decode direct count=\(direct.count) bytes=\(data.count)")
            return direct
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["data"] is NSNull {
            let msg = (obj["message"] as? String) ?? (obj["msg"] as? String) ?? ""
            groupUsersLog("service incremental decode empty(null) message=\(msg) bytes=\(data.count)")
            return []
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["data"] as? [[String: Any]],
           let listData = try? JSONSerialization.data(withJSONObject: raw),
           let list = try? JSONDecoder().decode([GroupUser].self, from: listData) {
            groupUsersLog("service incremental decode wrapped count=\(list.count) bytes=\(data.count)")
            return list
        }
        let preview = String(data: data.prefix(240), encoding: .utf8) ?? "<non-utf8>"
        groupUsersLog("service incremental decode failed bytes=\(data.count) preview=\(preview)")
        return []
    }
    
    /// 未读批量查询：同步 WS 已连接时优先 `get_unread_count`（AI-REDEME.md），否则 HTTP POST /api/v2/instances/unread_count
    func getUnreadCounts(instanceIds: [String]) async throws -> [String: [String: Int]] {
        let ids = Array(Set(instanceIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }
        let wsUp = await MainActor.run { SyncWebSocketService.shared.isConnected }
        if wsUp {
            do {
                return try await SyncWebSocketService.shared.requestGetUnreadCount(instanceIds: ids)
            } catch {
                // 并发 rpcBusy 或 WS 异常时回退 HTTP
            }
        }
        return try await getUnreadCountsHTTP(instanceIds: ids)
    }
    
    private func getUnreadCountsHTTP(instanceIds ids: [String]) async throws -> [String: [String: Int]] {
        let body: [String: Any] = ["instance_ids": ids]
        let data = try await requestApiV2(path: "/api/v2/instances/unread_count", query: [:], method: "POST", body: body, boxIP: nil)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let rawMap = (obj["data"] as? [String: Any]) ?? [:]
        var result: [String: [String: Int]] = [:]
        for (instanceId, any) in rawMap {
            guard let jidMap = any as? [String: Any] else { continue }
            var unreadByJid: [String: Int] = [:]
            for (jid, value) in jidMap {
                let count: Int = {
                    if let i = value as? Int { return i }
                    if let d = value as? Double { return Int(d) }
                    if let s = value as? String, let i = Int(s) { return i }
                    return 0
                }()
                unreadByJid[jid] = max(0, count)
            }
            result[instanceId] = unreadByJid
        }
        return result
    }
    
    /// 清未读：同步 WS 已连接时优先 `clear_unread`（AI-REDEME.md），否则 HTTP POST .../clear_unread
    func clearChatUnreadCount(instanceId: String, jid: String, boxIP: String?) async throws {
        let cleanJid = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstanceId = instanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanJid.isEmpty, !cleanInstanceId.isEmpty else { return }
        let wsUp = await MainActor.run { SyncWebSocketService.shared.isConnected }
        if wsUp {
            do {
                try await SyncWebSocketService.shared.requestClearUnread(instanceId: cleanInstanceId, jid: cleanJid)
                return
            } catch {
                // 回退 HTTP
            }
        }
        let encodedJid = cleanJid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanJid
        let path = "/api/v2/chats/jid/\(encodedJid)/clear_unread"
        _ = try await requestApiV2(
            path: path,
            query: ["instance_id": cleanInstanceId],
            method: "POST",
            body: [:],
            boxIP: boxIP
        )
    }
    
    /// POST /api/v1/translation，与 H5 translateText 一致；body: { text, key_id }，响应 { data: "翻译结果", success: true }
    func translate(text: String, keyId: String, boxIP: String?) async throws -> String {
        let body: [String: Any] = ["text": text, "key_id": keyId]
        // 历史翻译与 H5 一样需要携带当前容器 box-ip，避免多网段场景下后端路由失败
        let data = try await postApiV1(path: "/api/v1/translation", body: body, boxIP: boxIP)
        struct TranslationResponse: Decodable { let data: String?; let success: Bool? }
        let res = try JSONDecoder().decode(TranslationResponse.self, from: data)
        return res.data ?? ""
    }
    
    /// POST /api/v1/translation_text，与 H5 translateTextWithTargetLang 一致；工具页精准翻译，需传 boxIP 以设置 box-ip 头（否则服务端可能返回 500）
    func translateTextWithTargetLang(text: String, targetLang: String, boxIP: String?) async throws -> String {
        // 严格对齐可用请求样例：
        // POST http://47.76.156.108/api/v1/translation_text
        // Headers: x-token, Content-Type: application/json, Accept: */*
        // Body: { "text": "...", "target_lang": "en" }
        let body: [String: Any] = ["text": text, "target_lang": targetLang]
        let urlString = "\(APIConfig.host)/api/v1/translation_text"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                ($0["msg"] as? String) ?? ($0["message"] as? String)
            } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
            throw APIError.serverError(code: http.statusCode, message: msg)
        }
        struct TranslationResponse: Decodable { let data: String? }
        let res = try JSONDecoder().decode(TranslationResponse.self, from: data)
        return res.data ?? ""
    }

    /// POST /api/v1/translation_batch，批量翻译文本；body: { texts: ["..."] }，响应 { data: ["...", ...], success: true }
    func translateBatch(texts: [String], boxIP: String?) async throws -> [String] {
        let clean = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmpty = clean.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return [] }
        let body: [String: Any] = ["texts": nonEmpty]
        
        // 严格对齐可用请求样例：
        // POST http://47.76.156.108/api/v1/translation_batch
        // Headers: x-token, Content-Type: application/json, Accept: */*
        // Body: { "texts": [...] }
        let urlString = "\(APIConfig.host)/api/v1/translation_batch"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                ($0["msg"] as? String) ?? ($0["message"] as? String)
            } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
            throw APIError.serverError(code: http.statusCode, message: msg)
        }
        
        struct BatchResponse: Decodable {
            let data: [String]?
            let success: Bool?
            let message: String?
        }
        let res = try JSONDecoder().decode(BatchResponse.self, from: data)
        return res.data ?? []
    }
    
    /// 联系人备注：与 H5 updateContactRemarkName 一致
    func updateContactRemarkName(boxIP: String?, instanceId: String, jid: String, remarkName: String) async throws {
        let cleanJid = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanJid.isEmpty else { return }
        let path = "/api/v2/contacts/\(cleanJid)/update_remark_name"
        let query = ["instance_id": instanceId]
        let body: [String: Any] = ["remark_name": remarkName]
        _ = try await requestApiV2(path: path, query: query, method: "POST", body: body, boxIP: boxIP)
        await AppCacheStore.shared.updateContactRemark(
            instanceId: instanceId,
            jid: cleanJid,
            remarkName: remarkName
        )
    }
    
    /// 用户画像：GET /api/v1/user-info?phone=xxx
    func getUserInfo(phone: String) async throws -> CustomerUserInfo? {
        let clean = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        customerDebugLog("[CustomerDebug] getUserInfo request phone=\(clean)")
        let data = try await getApiV1(path: "/api/v1/user-info", query: ["phone": clean])
        if let wrapped = try? JSONDecoder().decode(CustomerUserInfoEnvelope.self, from: data),
           let info = wrapped.data,
           info.hasMeaningfulValue {
            customerDebugLog("[CustomerDebug] getUserInfo envelope decode ok phone=\(clean) name=\(info.name ?? "-") remark=\(info.remark ?? "-")")
            return info
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let topKeys = obj.keys.sorted().joined(separator: ",")
            customerDebugLog("[CustomerDebug] getUserInfo wrapped response keys=[\(topKeys)] phone=\(clean)")
            var candidates: [[String: Any]] = []
            if let dataMap = obj["data"] as? [String: Any] {
                candidates.append(dataMap)
                if let nested = dataMap["user_info"] as? [String: Any] { candidates.append(nested) }
                if let nested = dataMap["userInfo"] as? [String: Any] { candidates.append(nested) }
            }
            if let topNested = obj["user_info"] as? [String: Any] { candidates.append(topNested) }
            if let topNested = obj["userInfo"] as? [String: Any] { candidates.append(topNested) }
            for (idx, map) in candidates.enumerated() {
                if let d = try? JSONSerialization.data(withJSONObject: map),
                   let decoded = try? JSONDecoder().decode(CustomerUserInfo.self, from: d),
                   decoded.hasMeaningfulValue {
                    let keys = map.keys.sorted().joined(separator: ",")
                    customerDebugLog("[CustomerDebug] getUserInfo candidate[\(idx)] decode ok keys=[\(keys)] name=\(decoded.name ?? "-") remark=\(decoded.remark ?? "-")")
                    return decoded
                }
            }
            customerDebugLog("[CustomerDebug] getUserInfo decode failed phone=\(clean)")
        }
        if let direct = try? JSONDecoder().decode(CustomerUserInfo.self, from: data),
           direct.hasMeaningfulValue {
            customerDebugLog("[CustomerDebug] getUserInfo direct decode ok phone=\(clean) name=\(direct.name ?? "-") remark=\(direct.remark ?? "-")")
            return direct
        }
        return nil
    }
    
    /// 用户画像：PUT /api/v1/user-info?phone=xxx
    func updateUserInfo(phone: String, fields: [String: Any]) async throws {
        let clean = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = try await requestApiV1(path: "/api/v1/user-info", method: "PUT", body: fields, query: ["phone": clean])
    }
    
    /// 跟进记录：GET /api/v1/follow-ups?phone=xxx
    func getFollowUps(phone: String) async throws -> [FollowUpItem] {
        let clean = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        customerDebugLog("[CustomerDebug] getFollowUps request phone=\(clean)")
        let data = try await getApiV1(path: "/api/v1/follow-ups", query: ["phone": clean])
        if let list = try? JSONDecoder().decode([FollowUpItem].self, from: data) {
            customerDebugLog("[CustomerDebug] getFollowUps direct decode count=\(list.count) phone=\(clean)")
            if let first = list.first {
                customerDebugLog("[CustomerDebug] getFollowUps first id=\(first.id ?? 0) owner=\(first.ownerName ?? "-") creator=\(first.creatorName ?? "-") createdBy=\(first.createdByName ?? "-") username=\(first.username ?? "-") userName=\(first.userName ?? "-")")
            }
            return list
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["data"] as? [[String: Any]],
           let d = try? JSONSerialization.data(withJSONObject: list) {
            let decoded = (try? JSONDecoder().decode([FollowUpItem].self, from: d)) ?? []
            let keys = list.first?.keys.sorted().joined(separator: ",") ?? "-"
            customerDebugLog("[CustomerDebug] getFollowUps wrapped decode count=\(decoded.count) phone=\(clean) rawFirstKeys=[\(keys)]")
            if let first = decoded.first {
                customerDebugLog("[CustomerDebug] getFollowUps wrapped first id=\(first.id ?? 0) owner=\(first.ownerName ?? "-") creator=\(first.creatorName ?? "-") createdBy=\(first.createdByName ?? "-") username=\(first.username ?? "-") userName=\(first.userName ?? "-")")
            }
            return decoded
        }
        customerDebugLog("[CustomerDebug] getFollowUps decode failed phone=\(clean)")
        return []
    }
    
    /// 跟进记录：POST /api/v1/follow-ups
    func addFollowUp(phone: String, ownerName: String? = nil, content: String) async throws {
        let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhone.isEmpty, !cleanContent.isEmpty else { return }
        var body: [String: Any] = [
            "phone": cleanPhone,
            "content": cleanContent
        ]
        let owner = (ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty {
            body["owner_name"] = owner
            body["creator_name"] = owner
        }
        _ = try await requestApiV1(path: "/api/v1/follow-ups", method: "POST", body: body)
    }
    
    /// 跟进记录：PUT /api/v1/follow-ups/{id}
    func updateFollowUp(id: Int, phone: String, ownerName: String? = nil, content: String) async throws {
        let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id > 0, !cleanPhone.isEmpty, !cleanContent.isEmpty else { return }
        var body: [String: Any] = [
            "phone": cleanPhone,
            "content": cleanContent
        ]
        let owner = (ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty {
            body["owner_name"] = owner
            body["creator_name"] = owner
        }
        _ = try await requestApiV1(path: "/api/v1/follow-ups/\(id)", method: "PUT", body: body)
    }
    
    /// 跟进记录：DELETE /api/v1/follow-ups/{id}
    func deleteFollowUp(id: Int) async throws {
        guard id > 0 else { return }
        let urlString = "\(apiV2Base)/api/v1/follow-ups/\(id)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["msg"] as? String) ?? ($0["message"] as? String) } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
        }
    }
    
    /// 加载媒体流：
    /// - 图片缩略图：需传 msg_id + is_thumb=1
    /// - 图片原图：需传 msg_id，不传 is_thumb
    /// - 视频/文件：msg_id 可不传，is_thumb 不生效
    func fetchMediaStream(
        boxIP: String,
        index: Int,
        filePath: String,
        messageId: Int? = nil,
        isThumb: Bool? = nil,
        appType: String? = nil,
        instanceId: String? = nil
    ) async throws -> Data {
        let ip = boxIP
        let wsType = appType ?? "person"
        let uuid = (instanceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let msgIdString = messageId.map(String.init) ?? ""
        let thumbFlag = isThumb == nil ? "nil" : ((isThumb ?? false) ? "1" : "0")
        debugLog("[Media] fetchMediaStream start ip=\(ip) index=\(index) msg_id=\(msgIdString) is_thumb=\(thumbFlag) ws_type=\(wsType) uuid=\(uuid) filePath=\(filePath)")
        let cacheKeyRaw = "\(ip)|\(index)|\(filePath)|\(msgIdString)|\(thumbFlag)|\(wsType)|\(uuid)"
        let cacheKey = cacheKeyRaw.replacingOccurrences(of: "[^A-Za-z0-9_\\-\\.]+", with: "_", options: .regularExpression)
        if let cached = await MediaStreamCacheStore.shared.load(cacheKey) {
            if isLikelyImageData(cached) {
                debugLog("[Media] fetchMediaStream hit cache key=\(cacheKey)")
                return cached
            }
            await MediaStreamCacheStore.shared.remove(cacheKey)
        }
        
        var iosQuery: [String: String] = [
            "ip": ip,
            "ws_type": wsType,
            "file_type": "message",
            "uuid": uuid,
            "filePath": filePath
        ]
        if ip.isEmpty { iosQuery["ip"] = nil }
        
        var apiV1Query: [String: String] = ["box_ip": boxIP, "index": "\(index)", "file_path": filePath]
        if boxIP.isEmpty { apiV1Query["box_ip"] = nil }
        if let messageId {
            apiV1Query["msg_id"] = "\(messageId)"
        }
        if let isThumb {
            apiV1Query["is_thumb"] = isThumb ? "1" : "0"
        }
        
        // 某些环境 host 根路径命中前端 SPA，媒体接口实际挂在 /gva_api 下，按优先级逐个尝试。
        let candidates: [(base: String, path: String, query: [String: String], tag: String)] = [
            (apiV2Base, "/api/v1/media/stream", apiV1Query, "host/api_v1"),
            (APIConfig.gvaBaseURL, "/api/v1/media/stream", apiV1Query, "gva/api_v1"),
            (apiV2Base, "/ios_api/v1/media/stream", iosQuery, "host/ios_api_compat"),
            (APIConfig.gvaBaseURL, "/ios_api/v1/media/stream", iosQuery, "gva/ios_api_compat")
        ]
        
        var lastError: Error = APIError.serverError(code: -2, message: "媒体响应不是图片数据")
        for c in candidates {
            for attempt in 0..<2 {
                do {
                    let data = try await getApiV2(baseURL: c.base, path: c.path, query: c.query, boxIP: boxIP)
                    if data.isEmpty {
                        debugLog("[Media] candidate \(c.tag) empty")
                        continue
                    }
                    let normalized = try await normalizeMediaPayload(data, boxIP: boxIP)
                    if isLikelyImageData(normalized) {
                        debugLog("[Media] candidate \(c.tag) ok raw=\(data.count) normalized=\(normalized.count) attempt=\(attempt + 1)")
                        await MediaStreamCacheStore.shared.save(cacheKey, data: normalized)
                        return normalized
                    }
                    let preview = String(data: normalized.prefix(200), encoding: .utf8) ?? "<binary \(normalized.count)b>"
                    debugLog("[Media] candidate \(c.tag) non-image preview=\(preview)")
                    lastError = APIError.serverError(code: -2, message: "媒体响应不是图片数据")
                } catch {
                    debugLog("[Media] candidate \(c.tag) error attempt=\(attempt + 1): \(error.localizedDescription)")
                    lastError = error
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                    }
                }
            }
        }
        throw lastError
    }
    
    /// GET /api/v2/chats/{chat_row_id}/messages/{id}，与 H5 refreshMessages 一致
    func getMessageDetail(chatRowId: Int, instanceId: String, messageId: Int, boxIP: String?, index: Int?) async throws -> MessageDetailResponse {
        let path = "/api/v2/chats/\(chatRowId)/messages/\(messageId)"
        var query: [String: String] = ["instance_id": instanceId]
        if let ip = boxIP, !ip.isEmpty { query["box_ip"] = ip }
        if let idx = index { query["index"] = "\(idx)" }
        let data = try await getApiV2(path: path, query: query, boxIP: boxIP)
        if let direct = try? JSONDecoder().decode(MessageDetailResponse.self, from: data) { return direct }
        if let wrapped = try? JSONDecoder().decode(APIResponse<MessageDetailResponse>.self, from: data), let value = wrapped.data {
            return value
        }
        throw APIError.noData
    }
    
    /// POST /api/v1/call_scrm_func，与 H5 callSCRMFun 一致（multipart/form-data）
    func callSCRMFunc(_ params: CallSCRMFuncParams) async throws -> CallSCRMFuncResult {
        try await sendSCRMMultipart(path: "/api/v1/call_scrm_func", params: params, timeout: 180)
    }

    /// POST /api/v1/tasks/enqueue_scrm：文本/图片发送走队列+审核链路
    func enqueueSCRMTask(_ params: CallSCRMFuncParams) async throws -> CallSCRMFuncResult {
        try await sendSCRMMultipart(path: "/api/v1/tasks/enqueue_scrm", params: params, timeout: 180)
    }

    private func sendSCRMMultipart(path: String, params: CallSCRMFuncParams, timeout: TimeInterval) async throws -> CallSCRMFuncResult {
        let urlString = "\(apiV2Base)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.setValue("Bearer \(client.token ?? "")", forHTTPHeaderField: "Authorization")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if !params.ip.isEmpty {
            let prefix = params.ip.split(separator: ".").prefix(3).joined(separator: ".")
            request.setValue(prefix, forHTTPHeaderField: "box-ip")
        }
        
        // 与 web_h5 对齐：群组会话（@g.us）走 group 路径，不使用手机号。
        let jid = (params.jid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let jidParts = jid.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let jidUser = jidParts.first.map(String.init) ?? ""
        let jidDomain = jidParts.count > 1 ? String(jidParts[1]) : ""
        let phone = params.phoneOverride ?? ((jidDomain == "g.us") ? "group" : jidUser)
        let extraSummary = params.extraFields.keys.sorted().map { key in
            "\(key)=\(params.extraFields[key] ?? "")"
        }.joined(separator: ",")
        scrmSendLog("request path=\(path) method=\(params.method) instance=\(params.instanceID) ip=\(params.ip) index=\(params.index) jid=\(jid) phone=\(phone) name=\(params.name) contact=\(params.contactName ?? "") appType=\(params.appType ?? "") clone=\(params.cloneID ?? "") message=\(params.message ?? "") quotedIndex=\(params.quotedIndex.map { String($0) } ?? "") quotedTimestamp=\(params.quotedTimestamp.map { String($0) } ?? "") hasImage=\(params.imageData != nil) extra=\(extraSummary)")
        var fields: [(String, String)] = [
            ("instance_id", params.instanceID),
            ("ip", params.ip),
            ("index", String(params.index)),
            ("method", params.method),
            ("jid", jid)
        ]
        func appendOptional(_ name: String, _ value: String?) {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            fields.append((name, trimmed))
        }
        appendOptional("name", params.name)
        appendOptional("phone", phone)
        appendOptional("message", params.message)
        appendOptional("contact_name", params.contactName)
        appendOptional("last_name", params.lastName)
        appendOptional("first_name", params.firstName)
        appendOptional("quoted_index", params.quotedIndex.map { String($0) })
        appendOptional("quoted_text", params.quotedText)
        appendOptional("quoted_type", params.quotedType.map { String($0) })
        appendOptional("quoted_timestamp", params.quotedTimestamp.map { String($0) })
        appendOptional("target_lang", params.targetLang)
        appendOptional("app_type", params.appType)
        appendOptional("clone_id", params.cloneID)
        appendOptional("emoji", params.emoji)
        for key in params.extraFields.keys.sorted() {
            appendOptional(key, params.extraFields[key])
        }

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        for (name, value) in fields {
            appendField(name, value)
        }
        if let image = params.imageData, !image.isEmpty {
            let filename = params.imageFileName ?? "image.jpg"
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image_file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(image)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let data = try await performWithRetry(maxAttempts: 2) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.noData }
            guard (200...299).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["msg"] as? String } ?? "HTTP \(http.statusCode)"
                scrmSendLog("httpFailure path=\(path) status=\(http.statusCode) msg=\(msg)")
                UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
            }
            return data
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = (obj["code"] as? Int) ?? ((obj["code"] as? Double).map { Int($0) } ?? -1)
            let msg = obj["msg"] as? String
            let dataObj = obj["data"] as? [String: Any]
            let taskID = dataObj?["task_id"] as? String
            let taskStatus = dataObj?["status"] as? String
            scrmSendLog("response path=\(path) code=\(code) msg=\(msg ?? "") taskID=\(taskID ?? "") taskStatus=\(taskStatus ?? "") raw=\(String(data: data, encoding: .utf8) ?? "")")
            return CallSCRMFuncResult(code: code, msg: msg, taskID: taskID, taskStatus: taskStatus)
        }
        scrmSendLog("response path=\(path) decodeFailed raw=\(String(data: data, encoding: .utf8) ?? "")")
        throw APIError.noData
    }
    
    /// GET /api/v1/tasks/get_running，与 H5 getRunningTask 一致
    func getRunningTask(ip: String, index: Int) async throws -> RunningTaskStatus {
        let path = "/api/v1/tasks/get_running"
        var query: [String: String] = ["ip": ip]
        let port = instancePort(index: index)
        if !port.isEmpty { query["port"] = port }
        let data = try await getApiV2(path: path, query: query, boxIP: ip)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RunningTaskStatus(locked: false, type: nil, taskID: nil)
        }
        
        let source: [String: Any] = {
            if let nested = obj["data"] as? [String: Any] { return nested }
            return obj
        }()
        let locked = boolValue(source["locked"]) ?? boolValue(obj["locked"]) ?? false
        let type = stringValue(source["type"]) ?? stringValue(obj["type"])
        let taskID = stringValue(source["task_id"]) ?? stringValue(source["taskId"]) ?? stringValue(obj["task_id"]) ?? stringValue(obj["taskId"])
        return RunningTaskStatus(locked: locked, type: type, taskID: taskID)
    }
    
    /// GET /api/v1/tasks/stop?scrm=1，与 H5 stopRunningTask 一致
    func stopRunningTask(ip: String, index: Int) async throws {
        let path = "/api/v1/tasks/stop"
        var query: [String: String] = ["ip": ip, "scrm": "1"]
        let port = instancePort(index: index)
        if !port.isEmpty { query["port"] = port }
        _ = try await getApiV2(path: path, query: query, boxIP: ip)
    }

    /// GET /api/v1/tasks/by_instance：查询某实例的 SCRM 队列任务
    func getSCRMTasksByInstance(instanceId: String, status: String? = nil, jid: String? = nil, boxIP: String?) async throws -> [SCRMTaskItem] {
        let path = "/api/v1/tasks/by_instance"
        var query: [String: String] = ["instance_id": instanceId]
        if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query["status"] = status
        }
        if let jid, !jid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query["jid"] = jid
        }
        let data = try await getApiV2(path: path, query: query, boxIP: boxIP)
        struct Response: Decodable {
            let code: Int?
            let msg: String?
            let data: [SCRMTaskItem]?
        }
        let res = try JSONDecoder().decode(Response.self, from: data)
        guard (res.code ?? 0) == 1 else {
            throw APIError.serverError(code: res.code ?? 0, message: res.msg)
        }
        return res.data ?? []
    }
    
    private func instancePort(index: Int) -> String {
        if index <= 0 { return "" }
        if index < 10 { return "110\(index)0" }
        return "11\(index)0"
    }
    
    private func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let d = value as? Double { return Int(d) != 0 }
        if let s = value as? String {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if v == "1" || v == "true" { return true }
            if v == "0" || v == "false" { return false }
        }
        return nil
    }
    
    private func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    
    private func shouldRetry(_ error: Error) -> Bool {
        if let api = error as? APIError {
            switch api {
            case .httpStatus(let code):
                return code == 429 || code >= 500
            case .serverError(let code, _):
                return code == 429 || code >= 500
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
    
    private func performWithRetry<T>(
        maxAttempts: Int,
        initialDelayNs: UInt64 = 180_000_000,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt >= attempts - 1 || !shouldRetry(error) {
                    throw error
                }
                let delay = initialDelayNs * UInt64(attempt + 1)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? APIError.noData
    }
    
    private func getApiV2(baseURL: String? = nil, path: String, query: [String: String], boxIP: String?) async throws -> Data {
        let base = baseURL ?? apiV2Base
        var urlString = "\(base)\(path)"
        if !query.isEmpty {
            urlString += "?" + query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        if path.contains("/media/stream") {
            let rawFilePath = query["filePath"] ?? query["file_path"] ?? ""
            debugLog("[Media] request url=\(urlString)")
            debugLog("[Media] request raw filePath=\(rawFilePath)")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP, !ip.isEmpty {
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            request.setValue(prefix, forHTTPHeaderField: "box-ip")
        }
        let (data, http) = try await performWithRetry(maxAttempts: 2) {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.noData }
            guard (200...299).contains(http.statusCode) else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["msg"] as? String } ?? "HTTP \(http.statusCode)"
                UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
            }
            return (data, http)
        }
        if path.contains("/media/stream") {
            let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "<nil>"
            debugLog("[Media] response status=\(http.statusCode) content-type=\(ct) bytes=\(data.count)")
        }
        return data
    }
    
    /// 兼容后端可能返回的媒体格式：
    /// 1) 原始图片二进制；2) JSON(data=base64/dataURL/url)；3) 纯 base64 文本。
    private func normalizeMediaPayload(_ data: Data, boxIP: String) async throws -> Data {
        if isLikelyImageData(data) { return data }
        
        if let text = String(data: data, encoding: .utf8) {
            let preview = String(text.prefix(220))
            debugLog("[Media] normalize payload text preview=\(preview)")
            
            // 纯 base64 字符串
            if let decoded = Data(base64Encoded: compactBase64(text)), isLikelyImageData(decoded) {
                debugLog("[Media] normalize hit: plain base64")
                return decoded
            }
            
            // JSON 包裹
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let dataField = obj["data"]
                if let s = dataField as? String, let decoded = try await decodeMediaStringPayload(s, boxIP: boxIP) {
                    debugLog("[Media] normalize hit: json.data string")
                    return decoded
                }
                if let s = obj["media_url"] as? String, let decoded = try await decodeMediaStringPayload(s, boxIP: boxIP) {
                    debugLog("[Media] normalize hit: json.media_url string")
                    return decoded
                }
            }
        }
        
        // 维持原数据回传，交给上层继续打日志
        return data
    }
    
    private func decodeMediaStringPayload(_ raw: String, boxIP: String) async throws -> Data? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        
        if s.hasPrefix("data:image"), let comma = s.firstIndex(of: ",") {
            let b64 = String(s[s.index(after: comma)...])
            if let d = Data(base64Encoded: compactBase64(b64)), isLikelyImageData(d) { return d }
        }
        
        if let d = Data(base64Encoded: compactBase64(s)), isLikelyImageData(d) {
            return d
        }
        
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("/") {
            guard let url = URL(string: s.hasPrefix("/") ? "\(apiV2Base)\(s)" : s) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
            if let uid = client.userID { req.setValue(uid, forHTTPHeaderField: "x-user-id") }
            if !boxIP.isEmpty {
                let prefix = boxIP.split(separator: ".").prefix(3).joined(separator: ".")
                req.setValue(prefix, forHTTPHeaderField: "box-ip")
            }
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                debugLog("[Media] follow-url status=\(http.statusCode) bytes=\(d.count) url=\(url.absoluteString)")
            }
            if isLikelyImageData(d) { return d }
        }
        return nil
    }
    
    private func compactBase64(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
    
    private func isLikelyImageData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data.prefix(12))
        // JPEG
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return true }
        // PNG
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return true }
        // GIF
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return true }
        // WEBP: "RIFF....WEBP"
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
            bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 { return true }
        return false
    }
    
    private func postApiV1(path: String, body: [String: Any], boxIP: String?) async throws -> Data {
        let urlString = "\(apiV2Base)\(path)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP, !ip.isEmpty {
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            request.setValue(prefix, forHTTPHeaderField: "box-ip")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["message"] as? String } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
        }
        return data
    }
    
    private func requestApiV1(path: String, method: String, body: [String: Any], query: [String: String]? = nil) async throws -> Data {
        let urlString = "\(apiV2Base)\(path)"
        var finalURLString = urlString
        if let query, !query.isEmpty {
            finalURLString += "?" + query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        guard let url = URL(string: finalURLString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["msg"] as? String) ?? ($0["message"] as? String) } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let codeAny = obj["code"] {
            let code: Int = {
                if let i = codeAny as? Int { return i }
                if let d = codeAny as? Double { return Int(d) }
                if let s = codeAny as? String, let i = Int(s) { return i }
                return 0
            }()
            if code != 0 {
                let msg = (obj["msg"] as? String) ?? (obj["message"] as? String)
                throw APIError.serverError(code: code, message: msg)
            }
        }
        return data
    }
    
    private func getApiV1(path: String, query: [String: String]) async throws -> Data {
        var urlString = "\(apiV2Base)\(path)"
        if !query.isEmpty {
            urlString += "?" + query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["msg"] as? String) ?? ($0["message"] as? String) } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
        }
        return data
    }
    
    private func requestApiV2(path: String, query: [String: String], method: String, body: [String: Any], boxIP: String?) async throws -> Data {
        var urlString = "\(apiV2Base)\(path)"
        if !query.isEmpty {
            urlString += "?" + query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP, !ip.isEmpty {
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            request.setValue(prefix, forHTTPHeaderField: "box-ip")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["msg"] as? String) ?? ($0["message"] as? String) } ?? "HTTP \(http.statusCode)"
            UnauthorizedSessionHandler.reportHTTPStatus(http.statusCode)
                throw APIError.serverError(code: http.statusCode, message: msg)
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let codeAny = obj["code"] {
            let code: Int = {
                if let i = codeAny as? Int { return i }
                if let d = codeAny as? Double { return Int(d) }
                if let s = codeAny as? String, let i = Int(s) { return i }
                return 0
            }()
            if code != 0 {
                let msg = (obj["msg"] as? String) ?? (obj["message"] as? String)
                throw APIError.serverError(code: code, message: msg)
            }
        }
        return data
    }
}
