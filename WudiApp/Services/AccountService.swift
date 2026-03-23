//
//  AccountService.swift
//  WudiApp
//
//  账号页：gva_api myt/box/list 云机列表；ios_manager 设备接口保留备用
//

import Foundation

private let accountStatusTraceEnabled = false
@inline(__always) private func accountStatusTrace(_ message: @autoclosure () -> String) {
    guard accountStatusTraceEnabled else { return }
    print("[SyncStatus] \(message())")
}

private let accountNetworkTraceEnabled = false
@inline(__always) private func accountNetworkTrace(_ message: @autoclosure () -> String) {
    guard accountNetworkTraceEnabled else { return }
    print("[AccountNet] \(message())")
}

private func accountPayloadPreview(_ data: Data, limit: Int = 1200) -> String {
    guard !data.isEmpty else { return "<empty>" }
    let clipped = data.prefix(limit)
    var text = String(decoding: clipped, as: UTF8.self)
    if data.count > limit { text += "...(truncated)" }
    return text.replacingOccurrences(of: "\n", with: " ")
}

// MARK: - 云机盒子（gva_api myt/box/list 返回结构，与 H5 res.data.list 一致）
struct Box: Codable {
    let ID: Int
    let name: String
    let boxIP: String
    let boxType: String?
    let deviceCode: String?
    let area: String?
    let remark: String?
    let sdkStatus: String?
    let rpaStatus: String?
    let runningCount: Int?
    let totalCount: Int?
    let lastSyncTime: String?
    let imageType: String?
}

struct BoxListData: Decodable {
    let list: [Box]
}

// MARK: - 实例/容器（gva_api myt/instance/list 返回的 data.list 项，与 H5 一致）
struct Instance: Codable {
    let ID: Int?
    let uuid: String?
    let name: String?
    let boxIP: String?
    let index: Int?
    let state: String?  // running / stopped 等
    let appType: String?
    let scrmRemark: String?
    let scrmWsStatus: String?
    let scrmWsError: String?
    let newMessageCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case ID, uuid, name, boxIP, index, state
        case appType = "app_type"
        case scrmRemark = "scrm_remark"
        case scrmWsStatus = "scrm_ws_status"
        case scrmWsError = "scrm_ws_error"
        case newMessageCount = "new_message_count"
    }
}

/// start-scrcpy 接口返回的 data（与 H5 一致）
struct StartScrcpyData: Decodable {
    let adbAddr: String?
    let apiUrl: String?
    let authorization: String?
    let deviceId: String?
    let screenURL: String?
    let username: String?
}

extension Instance {
    /// 复制并覆盖部分字段（供 WebSocket 推送更新容器状态使用）
    func with(scrmRemark: String? = nil, scrmWsStatus: String? = nil, scrmWsError: String? = nil, newMessageCount: Int? = nil) -> Instance {
        Instance(
            from: self,
            scrmRemark: scrmRemark,
            scrmWsStatus: scrmWsStatus,
            scrmWsError: scrmWsError,
            newMessageCount: newMessageCount
        )
    }
}

extension Instance {
    /// 从已有实例复制并可选覆盖部分字段，避免与 Decodable 合成的 init 冲突
    init(from other: Instance, scrmRemark: String? = nil, scrmWsStatus: String? = nil, scrmWsError: String? = nil, newMessageCount: Int? = nil) {
        self.ID = other.ID
        self.uuid = other.uuid
        self.name = other.name
        self.boxIP = other.boxIP
        self.index = other.index
        self.state = other.state
        self.appType = other.appType
        self.scrmRemark = scrmRemark ?? other.scrmRemark
        self.scrmWsStatus = scrmWsStatus ?? other.scrmWsStatus
        self.scrmWsError = scrmWsError ?? other.scrmWsError
        self.newMessageCount = newMessageCount ?? other.newMessageCount
    }
}

extension Instance {
    /// 与 H5 onopen 订阅策略对齐：优先 uuid（iOS 机型），回退 ID（通用容器）。
    var syncSubscriptionId: String? {
        if let u = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { return u }
        if let id = ID { return "\(id)" }
        return nil
    }
    
    /// 同步 WS 推送中的 instance_id 兼容匹配键（uuid / ID / business ID）
    var syncMatchKeys: Set<String> {
        var keys = Set<String>()
        if let u = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            keys.insert(u)
            if appType == "business" { keys.insert("\(u)_business") }
        }
        if let id = ID {
            keys.insert("\(id)")
            if appType == "business" { keys.insert("\(id)_business") }
        }
        return keys
    }
}

struct InstanceListData: Decodable {
    let list: [Instance]
    let total: Int?
}

// MARK: - 设备/云机盒子（ios_manager 用，保留）
struct DeviceBox: Decodable {
    let uuid: String
    let ip: String?
    let location: String?  // 机柜，后端可能为 number 或 string
    let display_name: String?
    let state: Int?        // 1 运行 0 退出
    let deviceid: String?
    
    enum CodingKeys: String, CodingKey {
        case uuid, ip, location, display_name, state, deviceid
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
        if let s = try? c.decodeIfPresent(String.self, forKey: .location) {
            location = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .location) {
            location = "\(n)"
        } else {
            location = nil
        }
        display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
        state = try c.decodeIfPresent(Int.self, forKey: .state)
        deviceid = try c.decodeIfPresent(String.self, forKey: .deviceid)
    }
}

struct DeviceListData: Decodable {
    let list: [DeviceBox]
}

/// iOS 接口返回 res.data.data.list 双层 data
struct DeviceListDataWrapper: Decodable {
    let data: DeviceListData?
}

// MARK: - 设备位置（筛选机柜）
struct DeviceLocationsResponse: Codable {
    let data: [String]?
    let code: Int?
}

// MARK: - 设备分配
struct AssignableUser: Decodable, Identifiable {
    let id: Int
    let username: String?
    let nickName: String?
    
    var displayName: String {
        let nick = (nickName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { return nick }
        let user = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty { return user }
        return "用户\(id)"
    }
    
    enum CodingKeys: String, CodingKey {
        case id, ID, username, userName, nickName, nickname
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Int.self, forKey: .id) {
            id = v
        } else if let v = try c.decodeIfPresent(Int.self, forKey: .ID) {
            id = v
        } else if let s = try c.decodeIfPresent(String.self, forKey: .id), let parsed = Int(s) {
            id = parsed
        } else if let s = try c.decodeIfPresent(String.self, forKey: .ID), let parsed = Int(s) {
            id = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing user id")
        }
        if let v = try c.decodeIfPresent(String.self, forKey: .username) {
            username = v
        } else if let v = try c.decodeIfPresent(String.self, forKey: .userName) {
            username = v
        } else {
            username = nil
        }
        if let v = try c.decodeIfPresent(String.self, forKey: .nickName) {
            nickName = v
        } else if let v = try c.decodeIfPresent(String.self, forKey: .nickname) {
            nickName = v
        } else {
            nickName = nil
        }
    }
}

struct AssignedInstance: Decodable {
    let id: Int?
    let userId: Int?
    let userAuthId: Int?
    let boxIP: String?
    let index: Int?
    let instanceId: Int?
    let assignerId: Int?
}

final class AccountService {
    static let shared = AccountService()
    private let client = APIClient.shared
    private let gvaBase = APIConfig.gvaBaseURL
    private let iosBase = APIConfig.iosManagerBaseURL
    
    private init() {}
    
    /// 获取云机列表 GET gva_api/myt/box/list?page=1&pageSize=9999（与 H5 一致）
    func getBoxList(page: Int = 1, pageSize: Int = 9999) async throws -> [Box] {
        accountNetworkTrace("getBoxList request page=\(page) pageSize=\(pageSize)")
        let data = try await getGvaRawData(path: "/myt/box/list", query: ["page": "\(page)", "pageSize": "\(pageSize)"])
        let res = try JSONDecoder().decode(APIResponse<BoxListData>.self, from: data)
        guard res.code == 0 else {
            accountNetworkTrace("getBoxList serverError code=\(res.code) msg=\(res.msg ?? "-")")
            throw APIError.serverError(code: res.code, message: res.msg)
        }
        accountNetworkTrace("getBoxList success count=\(res.data?.list.count ?? 0)")
        return res.data?.list ?? []
    }
    
    /// 获取实例列表（不传 boxIP 时由后端按当前用户分配自动过滤）
    func getInstanceList(
        boxIP: String? = nil,
        name: String? = nil,
        state: String? = nil,
        page: Int = 1,
        pageSize: Int = 9999
    ) async throws -> [Instance] {
        let pageData = try await getInstanceListPage(boxIP: boxIP, name: name, state: state, page: page, pageSize: pageSize)
        return pageData.list
    }

    /// 分页聚合拉取当前用户可见实例（后端按分配自动过滤）
    func getAllVisibleInstances(pageSize: Int = 200) async throws -> [Instance] {
        let safePageSize = max(1, pageSize)
        var page = 1
        var all: [Instance] = []
        var expectedTotal: Int?

        while true {
            let pageData = try await getInstanceListPage(page: page, pageSize: safePageSize)
            let chunk = pageData.list
            if expectedTotal == nil {
                expectedTotal = pageData.total
            }
            if chunk.isEmpty { break }
            all.append(contentsOf: chunk)
            if chunk.count < safePageSize { break }
            if let total = expectedTotal, all.count >= total { break }
            page += 1
        }

        accountNetworkTrace("getAllVisibleInstances done pageSize=\(safePageSize) total=\(all.count)")
        return all
    }

    private func getInstanceListPage(
        boxIP: String? = nil,
        name: String? = nil,
        state: String? = nil,
        page: Int,
        pageSize: Int
    ) async throws -> InstanceListData {
        var query: [String: String] = ["page": "\(page)", "pageSize": "\(pageSize)"]
        if let boxIP = boxIP?.trimmingCharacters(in: .whitespacesAndNewlines), !boxIP.isEmpty {
            query["boxIP"] = boxIP
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            query["name"] = name
        }
        if let state = state?.trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty {
            query["state"] = state
        }

        accountNetworkTrace("getInstanceList request boxIP=\(query["boxIP"] ?? "-") page=\(page) pageSize=\(pageSize)")
        let data = try await getGvaRawData(path: "/myt/instance/list", query: query)
        let res = try JSONDecoder().decode(APIResponse<InstanceListData>.self, from: data)
        guard res.code == 0 else {
            accountNetworkTrace("getInstanceList serverError boxIP=\(query["boxIP"] ?? "-") code=\(res.code) msg=\(res.msg ?? "-")")
            throw APIError.serverError(code: res.code, message: res.msg)
        }
        let listCount = res.data?.list.count ?? 0
        accountNetworkTrace("getInstanceList success boxIP=\(query["boxIP"] ?? "-") count=\(listCount) page=\(page)")
        return res.data ?? InstanceListData(list: [], total: nil)
    }

    /// 获取可分配用户列表 GET /myt/instance/wait_assign_users?is_all=true
    func getAssignableUsers(isAll: Bool = true) async throws -> [AssignableUser] {
        let data = try await getGvaRawData(
            path: "/myt/instance/wait_assign_users",
            query: ["is_all": isAll ? "true" : "false"]
        )
        if let res = try? JSONDecoder().decode(APIResponse<[AssignableUser]>.self, from: data), res.code == 0 {
            return res.data ?? []
        }
        struct UserListWrapper: Decodable { let list: [AssignableUser]? }
        if let res = try? JSONDecoder().decode(APIResponse<UserListWrapper>.self, from: data), res.code == 0 {
            return res.data?.list ?? []
        }
        throw APIError.serverError(code: -1, message: "解析可分配用户失败")
    }

    /// 获取用户当前分配 GET /myt/instance/assign?userId={id}
    func getAssignedInstances(userId: Int) async throws -> [AssignedInstance] {
        let data = try await getGvaRawData(
            path: "/myt/instance/assign",
            query: ["userId": "\(userId)"]
        )
        if let res = try? JSONDecoder().decode(APIResponse<[AssignedInstance]>.self, from: data), res.code == 0 {
            return res.data ?? []
        }
        struct AssignedListWrapper: Decodable { let list: [AssignedInstance]? }
        if let res = try? JSONDecoder().decode(APIResponse<AssignedListWrapper>.self, from: data), res.code == 0 {
            return res.data?.list ?? []
        }
        throw APIError.serverError(code: -1, message: "解析已分配数据失败")
    }

    /// 分配/取消分配 POST /myt/instance/assign?userIds=1,2,3
    func assignInstances(
        userIds: [Int],
        instanceIDs: Set<Int>,
        boxIPIndexKeys: Set<String>,
        boxIPs: Set<String>
    ) async throws {
        let ids = userIds.map(String.init).joined(separator: ",")
        guard !ids.isEmpty else { throw APIError.serverError(code: 7, message: "未提供有效的用户ID") }
        let instanceMap = Dictionary(uniqueKeysWithValues: instanceIDs.map { (String($0), true) })
        let boxIPIndexMap = Dictionary(uniqueKeysWithValues: boxIPIndexKeys.map { ($0, true) })
        let boxIPMap = Dictionary(uniqueKeysWithValues: boxIPs.map { ($0, true) })
        let body: [String: Any] = [
            "instanceMap": instanceMap,
            "boxIPIndexMap": boxIPIndexMap,
            "boxIPMap": boxIPMap
        ]
        _ = try await postGvaWithData(path: "/myt/instance/assign", query: ["userIds": ids], body: body)
    }
    
    /// gva_api GET 请求（x-token + x-user-id）
    private func getGvaRawData(path: String, query: [String: String]?) async throws -> Data {
        var urlString = "\(gvaBase)\(path)"
        if let q = query, !q.isEmpty {
            let parts = q.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            urlString += "?" + parts.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        let traceBody = (path == "/myt/instance/list" || path == "/myt/box/list")
        accountNetworkTrace("GET \(urlString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID {
            request.setValue(uid, forHTTPHeaderField: "x-user-id")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            accountNetworkTrace("GET failed path=\(path) err=\(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        accountNetworkTrace("GET response path=\(path) status=\(http.statusCode) bytes=\(data.count)")
        if traceBody {
            accountNetworkTrace("GET body path=\(path) preview=\(accountPayloadPreview(data))")
        }
        guard (200...299).contains(http.statusCode) else {
            accountNetworkTrace("GET non2xx path=\(path) status=\(http.statusCode)")
            throw httpStatusError(http.statusCode)
        }
        return data
    }
    
    /// gva_api POST 请求（可选 box-ip 头，与 H5 instance.js 一致）
    private func postGva(path: String, body: [String: Any], boxIP: String? = nil) async throws {
        guard let url = URL(string: "\(gvaBase)\(path)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP, !ip.isEmpty {
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            request.setValue(prefix, forHTTPHeaderField: "box-ip")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        let res = try? JSONDecoder().decode(APIResponseEmpty.self, from: data)
        if let r = res, r.code != 0 { throw APIError.serverError(code: r.code, message: r.msg) }
    }

    /// gva_api POST 无 body（用于 path 参数型接口）
    private func postGvaWithoutBody(path: String) async throws {
        guard let url = URL(string: "\(gvaBase)\(path)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID {
            request.setValue(uid, forHTTPHeaderField: "x-user-id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        let res = try? JSONDecoder().decode(APIResponseEmpty.self, from: data)
        if let r = res, r.code != 0 { throw APIError.serverError(code: r.code, message: r.msg) }
    }
    
    /// gva_api GET 带 box-ip 头（如 startScrcpy）
    /// - Parameters:
    ///   - useFullBoxIP: true 时传完整 IP；false 时传前三段（兼容旧路由策略）
    private func getGva(path: String, query: [String: String]?, boxIP: String?, useFullBoxIP: Bool = false) async throws -> Data {
        var urlString = "\(gvaBase)\(path)"
        if let q = query, !q.isEmpty {
            urlString += "?" + q.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("\(APIConfig.host)/", forHTTPHeaderField: "Referer")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP?.trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty {
            if useFullBoxIP {
                request.setValue(ip, forHTTPHeaderField: "box-ip")
            } else {
                request.setValue(ip.split(separator: ".").prefix(3).joined(separator: "."), forHTTPHeaderField: "box-ip")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        return data
    }
    
    // MARK: - 实例操作（与 H5 wudi/instance.js 一致）
    
    func updateInstanceRemark(instanceId: Int, remark: String) async throws {
        try await postGva(path: "/myt/instance/update_remark", body: ["id": instanceId, "remark": remark])
    }
    
    func rebootInstance(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/reboot", body: ["id": instanceId])
    }

    /// 重启云机盒子（示例：POST /api/myt/box/reboot/{boxIP}）
    func rebootBox(boxIP: String) async throws {
        let clean = boxIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clean
        try await postGvaWithoutBody(path: "/myt/box/reboot/\(encoded)")
    }
    
    func updateInstanceName(instanceId: Int, name: String, reason: String) async throws {
        try await postGva(path: "/myt/instance/update_name", body: ["id": instanceId, "name": name, "reason": reason])
    }
    
    func randomDeviceInfo(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/random_device_info", body: ["id": instanceId])
    }
    
    func switchInstanceImage(instanceId: Int, imageId: Int, imageName: String) async throws {
        try await postGva(path: "/myt/instance/switch_image", body: ["id": instanceId, "imageId": imageId, "name": imageName])
    }
    
    func moveInstance(instanceId: Int, index: Int) async throws {
        try await postGva(path: "/myt/instance/move", body: ["id": instanceId, "index": index])
    }
    
    func resetInstance(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/reset", body: ["id": instanceId])
    }

    /// 更新 WhatsApp APK：POST /api/myt/instance/update-ws，body: { "id": 112266 }
    @discardableResult
    func updateInstanceWS(instanceId: Int) async throws -> String {
        let candidates = [
            "\(gvaBase)/myt/instance/update-ws",        // 与登录/验证码同一 gva_api 风格
            "\(APIConfig.host)/api/myt/instance/update-ws" // 兼容旧网关
        ]

        var lastError: Error?
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
            if let uid = client.userID {
                request.setValue(uid, forHTTPHeaderField: "x-user-id")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": instanceId])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.noData }
                guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
                if let res = try? JSONDecoder().decode(APIResponseEmpty.self, from: data) {
                    if res.code != 0 {
                        // 某些网关会返回 HTTP 200 + code=404，按路由未命中继续尝试下一个候选路径。
                        if res.code == 404 { throw APIError.httpStatus(404) }
                        throw APIError.serverError(code: res.code, message: res.msg)
                    }
                    return res.msg ?? "更新成功"
                }
                return "更新成功"
            } catch {
                lastError = error
                // 主路径 404 时继续尝试兼容路径
                if case APIError.httpStatus(let code) = error, code == 404 {
                    continue
                }
                break
            }
        }
        throw lastError ?? APIError.invalidURL
    }
    
    func copyInstance(instanceId: Int, dstName: String, dstIndex: Int, count: Int) async throws {
        try await postGva(path: "/myt/instance/copy", body: ["id": instanceId, "dst_name": dstName, "dst_index": dstIndex, "count": count])
    }
    
    func deleteInstance(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/delete", body: ["id": instanceId])
    }
    
    /// 启动实例（与 H5 startInstanceNoLoading 一致）
    func startInstance(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/start", body: ["id": instanceId])
    }
    
    /// 停止实例（与 H5 stopInstanceNoLoading 一致）
    func stopInstance(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/stop", body: ["id": instanceId])
    }
    
    /// 启动投屏（与 H5 一致：先 GET start-scrcpy，再根据响应建 WebSocket）
    /// GET gva_api/myt/instance/start-scrcpy?id=xx&type=screen，头：Accept、accept-language、Referer、box-ip、x-token
    func startScrcpy(boxIP: String, instanceId: Int, type: String = "screen") async throws -> (authorization: String, screenURL: String?, fullData: StartScrcpyData?) {
        // 投屏连接要求精确路由到具体机器，box-ip 需传完整 IP。
        let data = try await getGva(
            path: "/myt/instance/start-scrcpy",
            query: ["id": "\(instanceId)", "type": type],
            boxIP: boxIP,
            useFullBoxIP: true
        )
        if let raw = String(data: data, encoding: .utf8) {
            print("[Scrcpy] start-scrcpy raw response: \(raw)")
        } else {
            print("[Scrcpy] start-scrcpy raw response: <invalid utf8> bytes=\(data.count)")
        }
        let res = try JSONDecoder().decode(APIResponse<StartScrcpyData>.self, from: data)
        print("[Scrcpy] start-scrcpy response: code=\(res.code) msg=\(res.msg ?? "")")
        guard res.code == 0, let d = res.data else {
            print("[Scrcpy] start-scrcpy failed: code=\(res.code) msg=\(res.msg ?? "")")
            throw APIError.serverError(code: res.code, message: res.msg)
        }
        print("[Scrcpy] start-scrcpy data: authorization=\(d.authorization ?? "") adbAddr=\(d.adbAddr ?? "") apiUrl=\(d.apiUrl ?? "") screenURL=\(d.screenURL ?? "")")
        if (d.authorization ?? "").isEmpty {
            print("[Scrcpy] start-scrcpy warning: authorization is empty")
        }
        return (d.authorization ?? "", d.screenURL, d)
    }
    
    func setInstanceS5(instanceId: Int, s5ip: String, s5port: String, s5user: String, s5pwd: String) async throws {
        try await postGva(path: "/myt/instance/set_s5", body: ["id": instanceId, "s5ip": s5ip, "s5port": s5port, "s5user": s5user, "s5pwd": s5pwd])
    }
    
    func stopInstanceS5(instanceId: Int) async throws {
        try await postGva(path: "/myt/instance/stop_s5", body: ["id": instanceId])
    }
    
    func setInstanceS5FilterUrl(instanceId: Int, urlList: [String]) async throws {
        try await postGva(path: "/myt/instance/set_s5_filter_url", body: ["id": instanceId, "url_list": urlList])
    }
    
    func queryInstanceS5(instanceId: Int) async throws -> String? {
        let data = try await postGvaWithData(path: "/myt/instance/query_s5", body: ["id": instanceId])
        let res = try JSONDecoder().decode(APIResponse<String>.self, from: data)
        return res.data
    }
    
    func queryInstanceAllS5(boxIP: String) async throws -> [[String: Any]] {
        let data = try await postGvaWithData(path: "/myt/instance/query_all_s5", body: ["box_ip": boxIP])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let list = json["data"] as? [[String: Any]] else {
            throw APIError.serverError(code: -1, message: "解析 S5 列表失败")
        }
        return list
    }
    
    private func postGvaWithData(path: String, body: [String: Any]) async throws -> Data {
        try await postGvaWithData(path: path, query: nil, body: body)
    }

    private func postGvaWithData(path: String, query: [String: String]?, body: [String: Any]) async throws -> Data {
        var urlString = "\(gvaBase)\(path)"
        if let query, !query.isEmpty {
            let qs = query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            urlString += "?" + qs.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        if let res = try? JSONDecoder().decode(APIResponseEmpty.self, from: data), res.code != 0 {
            throw APIError.serverError(code: res.code, message: res.msg)
        }
        return data
    }
    
    struct InstanceImage: Decodable { let id: Int?; let name: String? }
    
    func getInstanceImages(instanceId: Int) async throws -> [InstanceImage] {
        let data = try await postGvaWithData(path: "/myt/instance/get_images", body: ["id": instanceId])
        struct ImgList: Decodable { let list: [InstanceImage]? }
        let res = try JSONDecoder().decode(APIResponse<ImgList>.self, from: data)
        guard res.code == 0 else { throw APIError.serverError(code: res.code, message: res.msg) }
        return res.data?.list ?? []
    }
    
    /// 获取容器 WhatsApp 同步状态（与 H5 getSyncStatus 一致，用于账号页每行右侧「已登录/未登录/需升级」）
    /// POST /api/v2/sync_status，body 为运行中容器的 app_type_key 数组，返回 key 为 app_type_key 的 status 字典
    struct SyncStatusItem: Decodable {
        let scrmWsStatus: String?
        let scrmWsPhone: String?
        let scrmWsError: String?
        let scrmWsSyncStatus: String?
        let scrmWsStatusDetail: String?
        enum CodingKeys: String, CodingKey {
            case scrmWsStatus = "scrmWsStatus"
            case scrmWsPhone = "scrmWsPhone"
            case scrmWsError = "scrmWsError"
            case scrmWsSyncStatus = "scrmWsSyncStatus"
            case scrmWsStatusDetail = "scrmWsStatusDetail"
        }
    }
    
    func getSyncStatus(instanceIds: [String]) async throws -> [String: SyncStatusItem] {
        let base = APIConfig.host
        guard let url = URL(string: "\(base)/api/v2/sync_status") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        request.setValue("true", forHTTPHeaderField: "ignore-funnel")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: instanceIds)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        if let map = try? JSONDecoder().decode([String: SyncStatusItem].self, from: data) {
            accountStatusTrace("getSyncStatus direct decode ok instanceIds=\(instanceIds.count) map=\(map.count)")
            for (k, v) in map.prefix(12) {
                accountStatusTrace("instance=\(k) ws=\(v.scrmWsStatus ?? "-") detail=\(v.scrmWsStatusDetail ?? "-") err=\(v.scrmWsError ?? "-")")
            }
            return map
        }
        struct Wrapper: Decodable { let data: [String: SyncStatusItem]? }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data), let map = w.data {
            accountStatusTrace("getSyncStatus wrapper decode ok instanceIds=\(instanceIds.count) map=\(map.count)")
            for (k, v) in map.prefix(12) {
                accountStatusTrace("instance=\(k) ws=\(v.scrmWsStatus ?? "-") detail=\(v.scrmWsStatusDetail ?? "-") err=\(v.scrmWsError ?? "-")")
            }
            return map
        }
        if let raw = String(data: data, encoding: .utf8) {
            accountStatusTrace("getSyncStatus decode failed raw=\(raw)")
        } else {
            accountStatusTrace("getSyncStatus decode failed bytes=\(data.count)")
        }
        return [:]
    }
    
    /// 与 H5 enableSync/disableSync 一致：/api/v2/enable_sync 与 /api/v2/disable_sync
    func enableSync(instanceId: String, boxIP: String, index: Int) async throws {
        _ = try await getHostAPI(path: "/api/v2/enable_sync", query: [
            "instance_id": instanceId,
            "box_ip": boxIP,
            "index": "\(index)"
        ], boxIP: boxIP)
    }
    
    func disableSync(instanceId: String, boxIP: String, index: Int) async throws {
        _ = try await getHostAPI(path: "/api/v2/disable_sync", query: [
            "instance_id": instanceId,
            "box_ip": boxIP,
            "index": "\(index)"
        ], boxIP: boxIP)
    }
    
    /// 重建聊天数据（与 H5 whatsapp rebuildChat 一致，调用 api/v2）
    func rebuildChat(instanceId: String, boxIP: String, index: Int) async throws {
        let base = APIConfig.host
        guard let url = URL(string: "\(base)/api/v2/instances/\(instanceId)/rebuild_chat_data?ip=\(boxIP)&index=\(index)") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        let res = try? JSONDecoder().decode(APIResponseEmpty.self, from: data)
        if let r = res, r.code != 0 { throw APIError.serverError(code: r.code, message: r.msg) }
    }
    
    /// 获取设备/盒子列表 GET ios_manager api/device/get（备用）
    func getDeviceList() async throws -> [DeviceBox] {
        let data = try await getIosRawData(path: "/api/device/get", query: nil)
        // 尝试 data.data.list（双层）
        if let wrapper = try? JSONDecoder().decode(APIResponse<DeviceListDataWrapper>.self, from: data),
           let list = wrapper.data?.data?.list, !list.isEmpty {
            return list
        }
        // 尝试 data.list（单层 data）
        struct DataList: Decodable { let list: [DeviceBox]? }
        if let res = try? JSONDecoder().decode(APIResponse<DataList>.self, from: data),
           let list = res.data?.list {
            return list
        }
        // 尝试 data 直接为数组
        if let res = try? JSONDecoder().decode(APIResponse<[DeviceBox]>.self, from: data),
           let list = res.data {
            return list
        }
        return []
    }
    
    /// 获取设备位置列表 GET ios_manager api/device/locations
    func getDeviceLocations() async throws -> [String] {
        let data = try await getIosRawData(path: "/api/device/locations", query: nil)
        if let res = try? JSONDecoder().decode(APIResponse<[String]>.self, from: data), let list = res.data {
            return list
        }
        struct Wrapper: Decodable { let data: [String]? }
        if let res = try? JSONDecoder().decode(APIResponse<Wrapper>.self, from: data), let list = res.data?.data {
            return list
        }
        return []
    }
    
    private func getIosRawData(path: String, query: [String: String]?) async throws -> Data {
        var urlString = "\(iosBase)\(path)"
        if let q = query, !q.isEmpty {
            let parts = q.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            urlString += "?" + parts.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.setValue("Bearer \(client.token ?? "")", forHTTPHeaderField: "Authorization")
        if let uid = client.userID {
            request.setValue(uid, forHTTPHeaderField: "x-user-id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        return data
    }
    
    /// 同步主机 POST ios_manager（备用）
    func syncHost() async throws {
        var request = URLRequest(url: URL(string: "\(iosBase)/api/system/cabinet-subnet/sync-all")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.setValue("Bearer \(client.token ?? "")", forHTTPHeaderField: "Authorization")
        if let uid = client.userID {
            request.setValue(uid, forHTTPHeaderField: "x-user-id")
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        let decoded = try? JSONDecoder().decode(APIResponseEmpty.self, from: responseData)
        if let d = decoded, d.code != 0 {
            throw APIError.serverError(code: d.code, message: d.msg)
        }
    }
    
    /// 刷新选中设备状态 POST ios_manager（备用）
    func refreshDeviceStatus(deviceIds: [String]) async throws {
        let body: [String: Any] = ["deviceIds": deviceIds]
        var request = URLRequest(url: URL(string: "\(iosBase)/api/device/refresh-status")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.setValue("Bearer \(client.token ?? "")", forHTTPHeaderField: "Authorization")
        if let uid = client.userID {
            request.setValue(uid, forHTTPHeaderField: "x-user-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        let decoded = try JSONDecoder().decode(APIResponseEmpty.self, from: responseData)
        if decoded.code != 0 {
            throw APIError.serverError(code: decoded.code, message: decoded.msg)
        }
    }
    
    private func getDecoded<T: Decodable>(path: String, query: [String: String]?) async throws -> APIResponse<T> {
        var urlString = "\(iosBase)\(path)"
        if let q = query, !q.isEmpty {
            let parts = q.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            urlString += "?" + parts.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        request.setValue("Bearer \(client.token ?? "")", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        return try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }
    
    private func getHostAPI(path: String, query: [String: String], boxIP: String?) async throws -> Data {
        var urlString = "\(APIConfig.host)\(path)"
        if !query.isEmpty {
            urlString += "?" + query.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let ip = boxIP, !ip.isEmpty {
            request.setValue(ip.split(separator: ".").prefix(3).joined(separator: "."), forHTTPHeaderField: "box-ip")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.noData }
        guard (200...299).contains(http.statusCode) else { throw httpStatusError(http.statusCode) }
        if let wrapped = try? JSONDecoder().decode(APIResponseEmpty.self, from: data), wrapped.code != 0 {
            throw APIError.serverError(code: wrapped.code, message: wrapped.msg)
        }
        return data
    }
}
