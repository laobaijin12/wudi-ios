//
//  AuthService.swift
//  WudiApp
//
//  验证码与登录接口，与 H5 api/user.js、stores/user.js 一致
//

import Foundation

// MARK: - 验证码（与 H5 captcha 返回 data 一致）
struct CaptchaData: Codable {
    let captchaId: String
    let picPath: String       // base64 或 URL，H5 直接用作 img src
    let captchaLength: Int
    let openCaptcha: Bool
}

// MARK: - 登录请求体
struct LoginRequest: Encodable {
    let username: String
    let password: String
    var captcha: String?
    var captchaId: String?
}

// MARK: - 登录返回用户信息（与 H5 res.data.user 一致）
struct LoginUserData: Codable {
    let userName: String?
    let ID: Int?
    let nickName: String?
    let headerImg: String?
    let imEnabled: Bool?
    
    init(userName: String?, ID: Int?, nickName: String?, headerImg: String?, imEnabled: Bool?) {
        self.userName = userName
        self.ID = ID
        self.nickName = nickName
        self.headerImg = headerImg
        self.imEnabled = imEnabled
    }
    
    enum CodingKeys: String, CodingKey {
        case userName, ID, nickName, headerImg, imEnabled
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        ID = try c.decodeIfPresent(Int.self, forKey: .ID)
        nickName = try c.decodeIfPresent(String.self, forKey: .nickName)
        headerImg = try c.decodeIfPresent(String.self, forKey: .headerImg)
        imEnabled = try c.decodeIfPresent(Bool.self, forKey: .imEnabled)
    }
}

// MARK: - 登录返回 data（与 H5 res.data 一致）
struct LoginResponseData: Codable {
    let token: String?
    let accessToken: String?  // iOS 端可能返回 accessToken
    let user: LoginUserData?
    let imToken: String?
    let imUserID: String?
    let imExpireAt: Int64?
    
    var effectiveToken: String? { token ?? accessToken }
    
    enum CodingKeys: String, CodingKey {
        case token
        case accessToken
        case user
        case imToken
        case imUserID
        case imExpireAt
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        user = try c.decodeIfPresent(LoginUserData.self, forKey: .user)
        imToken = try c.decodeIfPresent(String.self, forKey: .imToken)
        imUserID = try c.decodeIfPresent(String.self, forKey: .imUserID)
        if let v = try c.decodeIfPresent(Int64.self, forKey: .imExpireAt) {
            imExpireAt = v
        } else if let v = try c.decodeIfPresent(Int.self, forKey: .imExpireAt) {
            imExpireAt = Int64(v)
        } else if let s = try c.decodeIfPresent(String.self, forKey: .imExpireAt), let v = Int64(s) {
            imExpireAt = v
        } else {
            imExpireAt = nil
        }
    }
}

struct UserAuthority: Codable {
    let authorityId: Int?
    let authorityName: String?
}

struct AuthorityNode: Codable, Identifiable {
    let authorityId: Int
    let authorityName: String
    let parentId: Int?
    let children: [AuthorityNode]?
    var id: Int { authorityId }

    enum CodingKeys: String, CodingKey {
        case authorityId, authorityName, parentId, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Int.self, forKey: .authorityId) {
            authorityId = v
        } else if let s = try c.decodeIfPresent(String.self, forKey: .authorityId), let v = Int(s) {
            authorityId = v
        } else {
            throw DecodingError.dataCorruptedError(forKey: .authorityId, in: c, debugDescription: "Missing authorityId")
        }
        authorityName = (try c.decodeIfPresent(String.self, forKey: .authorityName)) ?? ""
        if let v = try c.decodeIfPresent(Int.self, forKey: .parentId) {
            parentId = v
        } else if let s = try c.decodeIfPresent(String.self, forKey: .parentId), let v = Int(s) {
            parentId = v
        } else {
            parentId = nil
        }
        children = try c.decodeIfPresent([AuthorityNode].self, forKey: .children)
    }
}

struct UserInfoPayload: Codable {
    let userInfo: LoginUserData?
    let userName: String?
    let nickName: String?
    let headerImg: String?
    let ID: Int?
    
    var resolvedUser: LoginUserData {
        if let userInfo { return userInfo }
        return LoginUserData(
            userName: userName,
            ID: ID,
            nickName: nickName,
            headerImg: headerImg,
            imEnabled: nil
        )
    }
}

private struct MenuButtonValue: Decodable {
    let intValue: Int
    
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) {
            intValue = v
            return
        }
        if let v = try? c.decode(Bool.self) {
            intValue = v ? 1 : 0
            return
        }
        if let v = try? c.decode(String.self), let parsed = Int(v.trimmingCharacters(in: .whitespacesAndNewlines)) {
            intValue = parsed
            return
        }
        intValue = 0
    }
}

private struct MenuNode: Decodable {
    let name: String?
    let children: [MenuNode]?
    let btns: [String: MenuButtonValue]?
}

private struct MenuTreePayload: Decodable {
    let menus: [MenuNode]?
}

struct UserListItem: Codable, Identifiable {
    let userId: Int
    let userName: String?
    let nickName: String?
    let phone: String?
    let email: String?
    let enable: Int?
    let authority: UserAuthority?
    
    var id: Int { userId }
    
    enum CodingKeys: String, CodingKey {
        case userId = "ID"
        case userName, nickName, phone, email, enable, authority
    }
}

private struct UserListData: Codable {
    let list: [UserListItem]?
    let total: Int?
}

struct ChatReviewRecord: Codable, Identifiable {
    let id: UInt
    let userID: UInt?
    let instanceID: String?
    /// GVA 返回的云机展示名（与后台 container_name 对齐；客户端再用 formatInstanceName 去前缀）
    let containerName: String?
    /// 提交人登录名（GVA：submitter_username）
    let submitterUsername: String?
    let nickName: String?
    let userName: String?
    let boxIP: String?
    let index: UInt?
    let taskUUID: String?
    let chatText: String?
    let imageURL: String?
    let reviewReasons: String?
    let qrCodeData: String?
    let taskParamsJSON: String?
    let reviewStatus: String?
    let reviewedBy: String?
    let reviewNote: String?
    let reviewedAt: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case instanceID = "instance_id"
        case containerName = "container_name"
        case submitterUsername = "submitter_username"
        case nickName = "nick_name"
        case userName = "user_name"
        case boxIP = "box_ip"
        case index
        case taskUUID = "task_uuid"
        case chatText = "chat_text"
        case imageURL = "image_url"
        case reviewReasons = "review_reasons"
        case qrCodeData = "qr_code_data"
        case taskParamsJSON = "task_params_json"
        case reviewStatus = "review_status"
        case reviewedBy = "reviewed_by"
        case reviewNote = "review_note"
        case reviewedAt = "reviewed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ChatReviewListData: Codable {
    let list: [ChatReviewRecord]
    let total: Int
    let page: Int
    let pageSize: Int
}

#if DEBUG
private let chatReviewLogEnabled = false
@inline(__always) private func chatReviewLog(_ message: @autoclosure () -> String) {
    guard chatReviewLogEnabled else { return }
    print("[ChatReview] \(message())")
}
#else
@inline(__always) private func chatReviewLog(_ message: @autoclosure () -> String) {}
#endif

final class AuthService {
    static let shared = AuthService()
    private let client = APIClient.shared
    private let base = APIConfig.gvaBaseURL
    
    private init() {}
    
    /// 获取验证码 POST /base/captcha，与 H5 captcha() 一致，x-token 可为空
    func fetchCaptcha() async throws -> CaptchaData {
        let wrapper: APIResponse<CaptchaData> = try await postDecoded(
            path: "/base/captcha",
            body: nil as [String: String]?,
            useToken: false
        )
        guard let data = wrapper.data else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return data
    }
    
    /// 登录 POST /base/login，与 H5 login(loginInfo) 一致
    func login(username: String, password: String, captcha: String?, captchaId: String?) async throws -> LoginResponseData {
        var body: [String: Any] = [
            "username": username,
            "password": password
        ]
        if let c = captcha, let id = captchaId, !c.isEmpty, !id.isEmpty {
            body["captcha"] = c
            body["captchaId"] = id
        }
        let wrapper: APIResponse<LoginResponseData> = try await postDecoded(
            path: "/base/login",
            body: body,
            useToken: false
        )
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        guard let data = wrapper.data else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return data
    }
    
    /// 与 H5 changePassword 一致：POST /user/changePassword
    func changePassword(oldPassword: String, newPassword: String) async throws {
        let wrapper: APIResponseEmpty = try await requestDecoded(
            path: "/user/changePassword",
            method: "POST",
            body: [
                "password": oldPassword,
                "newPassword": newPassword
            ]
        )
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }
    
    /// 与 H5 getUserList 一致：POST /user/getUserList
    func getUserList(page: Int, pageSize: Int, username: String) async throws -> (list: [UserListItem], total: Int) {
        let wrapper: APIResponse<UserListData> = try await requestDecoded(
            path: "/user/getUserList",
            method: "POST",
            body: [
                "page": page,
                "pageSize": pageSize,
                "username": username,
                "nickname": "",
                "phone": "",
                "email": ""
            ]
        )
        guard wrapper.code == 0 else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return (wrapper.data?.list ?? [], wrapper.data?.total ?? 0)
    }

    /// 获取可分配角色列表：POST /authority/getAuthorityList（含 children 递归）
    func getAuthorityList(page: Int? = nil, pageSize: Int? = nil) async throws -> [AuthorityNode] {
        var body: [String: Any] = [:]
        if let page { body["page"] = page }
        if let pageSize { body["pageSize"] = pageSize }
        let wrapper: APIResponse<[AuthorityNode]> = try await requestDecoded(
            path: "/authority/getAuthorityList",
            method: "POST",
            body: body
        )
        guard wrapper.code == 0 else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return wrapper.data ?? []
    }

    /// 管理员创建用户：POST /user/admin_register
    func adminRegister(
        userName: String,
        passWord: String,
        nickName: String,
        authorityId: Int,
        headerImg: String = "",
        enable: Int = 1,
        imEnabled: Bool = false,
        authorityIds: [Int]? = nil,
        phone: String = "",
        email: String = ""
    ) async throws {
        let ids = authorityIds ?? [authorityId]
        let body: [String: Any] = [
            "userName": userName,
            "passWord": passWord,
            "nickName": nickName,
            "authorityId": authorityId,
            "headerImg": headerImg,
            "enable": enable,
            "imEnabled": imEnabled,
            "authorityIds": ids,
            "phone": phone,
            "email": email
        ]
        let wrapper: APIResponseEmpty = try await requestDecoded(
            path: "/user/admin_register",
            method: "POST",
            body: body
        )
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }
    
    /// 与 H5 setUserInfo 一致：PUT /user/setUserInfo（启用/停用）
    func setUserEnable(user: UserListItem, enable: Int) async throws {
        let body: [String: Any] = [
            "ID": user.userId,
            "userName": user.userName ?? "",
            "nickName": user.nickName ?? "",
            "phone": user.phone ?? "",
            "email": user.email ?? "",
            "enable": enable,
            "authorityId": user.authority?.authorityId ?? 0
        ]
        let wrapper: APIResponseEmpty = try await requestDecoded(path: "/user/setUserInfo", method: "PUT", body: body)
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }
    
    /// 与 H5 deleteUser 一致：DELETE /user/deleteUser
    func deleteUser(id: Int) async throws {
        let wrapper: APIResponseEmpty = try await requestDecoded(path: "/user/deleteUser", method: "DELETE", body: ["id": id])
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }
    
    /// 与 H5 LoginOut 一致：POST /jwt/jsonInBlacklist（失败不阻塞本地退出）
    func addTokenToBlacklist() async {
        do {
            let _: APIResponseEmpty = try await requestDecoded(path: "/jwt/jsonInBlacklist", method: "POST", body: nil)
        } catch {
            // 忽略错误，保持本地可退出
        }
    }
    
    /// 与 H5 GetUserInfo 一致：GET /user/getUserInfo
    func getCurrentUserInfo() async throws -> LoginUserData {
        let wrapper: APIResponse<UserInfoPayload> = try await requestDecoded(
            path: "/user/getUserInfo",
            method: "GET",
            body: nil
        )
        guard wrapper.code == 0, let data = wrapper.data else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return data.resolvedUser
    }

    /// 拉取审核列表。`userID` 仅在后端明确约定为「按该用户维度筛选」时传入；审核员看全量待审应传 `nil`。
    func getChatReviewList(
        page: Int,
        pageSize: Int,
        reviewStatus: String?,
        userID: Int?
    ) async throws -> ChatReviewListData {
        var query: [String: String] = [
            "page": "\(page)",
            "pageSize": "\(pageSize)"
        ]
        if let reviewStatus, !reviewStatus.isEmpty {
            query["reviewStatus"] = reviewStatus
        }
        if let userID {
            query["userID"] = "\(userID)"
        }
        chatReviewLog("getChatReviewList request base=\(base) path=/chatReview/getChatReviewList query=\(query)")
        let wrapper: APIResponse<ChatReviewListData> = try await getDecoded(
            path: "/chatReview/getChatReviewList",
            query: query
        )
        chatReviewLog("getChatReviewList response code=\(wrapper.code) total=\(wrapper.data?.total ?? -1) page=\(wrapper.data?.page ?? -1) pageSize=\(wrapper.data?.pageSize ?? -1)")
        guard wrapper.code == 0, let data = wrapper.data else {
            chatReviewLog("getChatReviewList failed msg=\(wrapper.msg ?? "")")
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        return data
    }

    func approveChatReview(id: UInt, reviewNote: String) async throws {
        chatReviewLog("approveChatReview request base=\(base) id=\(id)")
        let wrapper: APIResponseEmpty = try await requestDecoded(
            path: "/chatReview/approveChatReview",
            method: "PUT",
            body: [
                "id": id,
                "reviewNote": reviewNote
            ]
        )
        chatReviewLog("approveChatReview response code=\(wrapper.code) msg=\(wrapper.msg ?? "")")
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }

    func rejectChatReview(id: UInt, reviewNote: String) async throws {
        chatReviewLog("rejectChatReview request base=\(base) id=\(id)")
        let wrapper: APIResponseEmpty = try await requestDecoded(
            path: "/chatReview/rejectChatReview",
            method: "PUT",
            body: [
                "id": id,
                "reviewNote": reviewNote
            ]
        )
        chatReviewLog("rejectChatReview response code=\(wrapper.code) msg=\(wrapper.msg ?? "")")
        if wrapper.code != 0 {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
    }
    
    /// 与 H5 asyncMenu 一致：POST /menu/getMenu，提取 device/instances 的 btns 权限
    func getInstanceButtonPermissions() async throws -> [String: Int] {
        let wrapper: APIResponse<MenuTreePayload> = try await requestDecoded(
            path: "/menu/getMenu",
            method: "POST",
            body: nil
        )
        guard wrapper.code == 0 else {
            throw APIError.serverError(code: wrapper.code, message: wrapper.msg)
        }
        let menus = wrapper.data?.menus ?? []
        let deviceNode = menus.first { ($0.name ?? "").lowercased() == "device" }
        let instancesNode = deviceNode?.children?.first { ($0.name ?? "").lowercased() == "instances" }
        let raw = instancesNode?.btns ?? [:]
        var mapped: [String: Int] = [:]
        for (k, v) in raw {
            mapped[k] = v.intValue
        }
        return mapped
    }
    
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()
    
    private func postDecoded<T: Decodable>(
        path: String,
        body: [String: Any]?,
        useToken: Bool
    ) async throws -> APIResponse<T> {
        let url = URL(string: "\(base)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(useToken ? (client.token ?? "") : "", forHTTPHeaderField: "x-token")
        if let b = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: b)
        }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw httpStatusError(http.statusCode)
        }
        return try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }
    
    private func requestDecoded<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]?
    ) async throws -> T {
        let url = URL(string: "\(base)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        if let b = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: b)
        }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw httpStatusError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getDecoded<T: Decodable>(
        path: String,
        query: [String: String]
    ) async throws -> T {
        var components = URLComponents(string: "\(base)\(path)")
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.token ?? "", forHTTPHeaderField: "x-token")
        if let uid = client.userID { request.setValue(uid, forHTTPHeaderField: "x-user-id") }
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw httpStatusError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
