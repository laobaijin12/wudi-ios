import Foundation

#if DEBUG
private let customerMetaDebugLogEnabled = false
@inline(__always) private func customerMetaLog(_ message: @autoclosure () -> String) {
    guard customerMetaDebugLogEnabled else { return }
    print(message())
}
#else
@inline(__always) private func customerMetaLog(_ message: @autoclosure () -> String) {}
#endif

struct CustomerSyncContext {
    let conversationKey: String
    let boxIP: String?
    let instanceId: String
    let jid: String?
    let phone: String?
}

struct CustomerFollowUpRecord: Codable, Identifiable, Equatable {
    let id: String
    var text: String
    var ts: Int64
    var remoteID: Int?
    var phone: String?
    var ownerName: String?
    var synced: Bool
}

struct CustomerMeta: Codable, Equatable {
    var name: String
    var remark: String
    var age: String
    var source: String
    var industry: String
    var occupation: String
    var familyStatus: String
    var annualIncome: String
    var profile: String
    var followUps: [CustomerFollowUpRecord]
    var pendingProfileSync: Bool
    var pendingRemarkSync: Bool
    
    enum CodingKeys: String, CodingKey {
        case name
        case remark
        case age
        case source
        case industry
        case occupation
        case familyStatus
        case family_status
        case annualIncome
        case annual_income
        case profile
        case followUps
        case pendingProfileSync
        case pendingRemarkSync
    }
    
    init(
        name: String = "",
        remark: String = "",
        age: String = "",
        source: String = "",
        industry: String = "",
        occupation: String = "",
        familyStatus: String = "",
        annualIncome: String = "",
        profile: String = "",
        followUps: [CustomerFollowUpRecord] = [],
        pendingProfileSync: Bool = false,
        pendingRemarkSync: Bool = false
    ) {
        self.name = name
        self.remark = remark
        self.age = age
        self.source = source
        self.industry = industry
        self.occupation = occupation
        self.familyStatus = familyStatus
        self.annualIncome = annualIncome
        self.profile = profile
        self.followUps = followUps
        self.pendingProfileSync = pendingProfileSync
        self.pendingRemarkSync = pendingRemarkSync
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        age = try c.decodeIfPresent(String.self, forKey: .age) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        industry = try c.decodeIfPresent(String.self, forKey: .industry) ?? ""
        occupation = try c.decodeIfPresent(String.self, forKey: .occupation) ?? ""
        familyStatus = try c.decodeIfPresent(String.self, forKey: .familyStatus)
            ?? c.decodeIfPresent(String.self, forKey: .family_status)
            ?? ""
        annualIncome = try c.decodeIfPresent(String.self, forKey: .annualIncome)
            ?? c.decodeIfPresent(String.self, forKey: .annual_income)
            ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        followUps = try c.decodeIfPresent([CustomerFollowUpRecord].self, forKey: .followUps) ?? []
        pendingProfileSync = try c.decodeIfPresent(Bool.self, forKey: .pendingProfileSync) ?? false
        pendingRemarkSync = try c.decodeIfPresent(Bool.self, forKey: .pendingRemarkSync) ?? false
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(remark, forKey: .remark)
        try c.encode(age, forKey: .age)
        try c.encode(source, forKey: .source)
        try c.encode(industry, forKey: .industry)
        try c.encode(occupation, forKey: .occupation)
        try c.encode(familyStatus, forKey: .familyStatus)
        try c.encode(annualIncome, forKey: .annualIncome)
        try c.encode(profile, forKey: .profile)
        try c.encode(followUps, forKey: .followUps)
        try c.encode(pendingProfileSync, forKey: .pendingProfileSync)
        try c.encode(pendingRemarkSync, forKey: .pendingRemarkSync)
    }
}

actor CustomerMetaStore {
    static let shared = CustomerMetaStore()
    private init() {}
    
    private func key(_ conversationKey: String) -> String {
        "customer_meta_v1_\(conversationKey)"
    }
    
    func load(conversationKey: String) -> CustomerMeta {
        guard let data = UserDefaults.standard.data(forKey: key(conversationKey)),
              let meta = try? JSONDecoder().decode(CustomerMeta.self, from: data) else {
            return CustomerMeta()
        }
        return meta
    }
    
    func save(_ meta: CustomerMeta, conversationKey: String) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        UserDefaults.standard.set(data, forKey: key(conversationKey))
    }
    
    func setRemark(_ remark: String, context: CustomerSyncContext) async {
        var meta = load(conversationKey: context.conversationKey)
        meta.remark = remark
        meta.pendingProfileSync = true
        meta.pendingRemarkSync = true
        save(meta, conversationKey: context.conversationKey)
        await sync(context: context)
    }
    
    func updateProfileAndRemark(profile: String, remark: String, context: CustomerSyncContext) async {
        var meta = load(conversationKey: context.conversationKey)
        meta.profile = profile
        meta.remark = remark
        meta.pendingProfileSync = true
        meta.pendingRemarkSync = true
        save(meta, conversationKey: context.conversationKey)
        await sync(context: context)
    }
    
    func updateUserInfo(
        name: String,
        remark: String,
        age: String,
        source: String,
        industry: String,
        occupation: String,
        familyStatus: String,
        annualIncome: String,
        context: CustomerSyncContext
    ) async {
        var meta = load(conversationKey: context.conversationKey)
        meta.name = name
        meta.remark = remark
        meta.age = age
        meta.source = source
        meta.industry = industry
        meta.occupation = occupation
        meta.familyStatus = familyStatus
        meta.annualIncome = annualIncome
        meta.pendingProfileSync = true
        meta.pendingRemarkSync = true
        save(meta, conversationKey: context.conversationKey)
        await sync(context: context)
    }
    
    func addFollowUp(_ text: String, ownerName: String?, context: CustomerSyncContext) async {
        var meta = load(conversationKey: context.conversationKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let record = CustomerFollowUpRecord(
            id: "fu_\(now)_\(UUID().uuidString)",
            text: text,
            ts: now,
            remoteID: nil,
            phone: context.phone,
            ownerName: ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
            synced: false
        )
        meta.followUps.insert(record, at: 0)
        save(meta, conversationKey: context.conversationKey)
        await sync(context: context)
    }
    
    func updateFollowUp(recordID: String, ownerName: String, content: String, context: CustomerSyncContext) async -> Bool {
        let cleanOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOwner.isEmpty, !clean.isEmpty else { return false }
        var meta = load(conversationKey: context.conversationKey)
        guard let idx = meta.followUps.firstIndex(where: { $0.id == recordID }) else { return false }
        meta.followUps[idx].ownerName = cleanOwner
        meta.followUps[idx].text = clean
        meta.followUps[idx].synced = false
        save(meta, conversationKey: context.conversationKey)
        
        if let remoteID = meta.followUps[idx].remoteID, remoteID > 0 {
            let phone = context.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !phone.isEmpty else { return false }
            do {
                try await ChatService.shared.updateFollowUp(
                    id: remoteID,
                    phone: phone,
                    ownerName: cleanOwner,
                    content: clean
                )
                meta = load(conversationKey: context.conversationKey)
                if let latestIdx = meta.followUps.firstIndex(where: { $0.id == recordID }) {
                    meta.followUps[latestIdx].synced = true
                    save(meta, conversationKey: context.conversationKey)
                }
                return true
            } catch {
                return false
            }
        }
        await sync(context: context)
        return true
    }
    
    func deleteFollowUp(recordID: String, context: CustomerSyncContext) async -> Bool {
        var meta = load(conversationKey: context.conversationKey)
        guard let idx = meta.followUps.firstIndex(where: { $0.id == recordID }) else { return false }
        let record = meta.followUps[idx]

        meta.followUps.removeAll { $0.id == recordID }
        save(meta, conversationKey: context.conversationKey)
        
        if let remoteID = record.remoteID, remoteID > 0 {
            do {
                try await ChatService.shared.deleteFollowUp(id: remoteID)
            } catch {
                // 本地先删，远端失败不阻断交互，后续可由拉取同步兜底。
            }
        }
        return true
    }
    
    /// 本地先显后后台同步：失败不清除 pending，下次进入会话自动重试。
    func sync(context: CustomerSyncContext) async {
        var meta = load(conversationKey: context.conversationKey)
        var changed = false
        let phone = context.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if meta.pendingRemarkSync,
           let jid = context.jid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jid.isEmpty,
           !context.instanceId.isEmpty {
            do {
                try await ChatService.shared.updateContactRemarkName(
                    boxIP: context.boxIP,
                    instanceId: context.instanceId,
                    jid: jid,
                    remarkName: meta.remark
                )
                meta.pendingRemarkSync = false
                changed = true
            } catch { }
        }
        
        if meta.pendingProfileSync, !phone.isEmpty {
            do {
                let profileFields = buildProfileUpdateFields(meta)
                if profileFields.isEmpty {
                    meta.pendingProfileSync = false
                    changed = true
                } else {
                try await ChatService.shared.updateUserInfo(
                    phone: phone,
                        fields: profileFields
                )
                meta.pendingProfileSync = false
                changed = true
                }
            } catch { }
        }
        
        if !phone.isEmpty {
            for idx in meta.followUps.indices {
                guard !meta.followUps[idx].synced else { continue }
                do {
                    try await ChatService.shared.addFollowUp(
                        phone: phone,
                        ownerName: meta.followUps[idx].ownerName,
                        content: meta.followUps[idx].text
                    )
                    meta.followUps[idx].synced = true
                    meta.followUps[idx].phone = phone
                    changed = true
                } catch {
                    break
                }
            }
        }
        
        if changed {
            save(meta, conversationKey: context.conversationKey)
        }
    }
    
    /// 后台拉远端画像/跟进，和本地待同步数据合并（本地优先显示，再逐步收敛到服务端）
    func pullRemoteAndMerge(context: CustomerSyncContext) async {
        let phone = context.phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !phone.isEmpty else { return }
        customerMetaLog("[CustomerDebug] pullRemoteAndMerge start conversation=\(context.conversationKey) phone=\(phone)")
        var meta = load(conversationKey: context.conversationKey)
        var changed = false
        customerMetaLog("[CustomerDebug] merge flags pendingProfileSync=\(meta.pendingProfileSync) pendingRemarkSync=\(meta.pendingRemarkSync) localName=\(meta.name) localRemark=\(meta.remark)")
        
        if let remoteInfo = try? await ChatService.shared.getUserInfo(phone: phone) {
            customerMetaLog("[CustomerDebug] remote userInfo name=\(remoteInfo.name ?? "-") remark=\(remoteInfo.remark ?? "-") age=\(remoteInfo.age ?? "-") source=\(remoteInfo.source ?? "-")")
            if !meta.pendingProfileSync {
                changed = mergeNonEmpty(remoteInfo.name, into: &meta.name) || changed
                changed = mergeNonEmpty(remoteInfo.age, into: &meta.age) || changed
                changed = mergeNonEmpty(remoteInfo.source, into: &meta.source) || changed
                changed = mergeNonEmpty(remoteInfo.industry, into: &meta.industry) || changed
                changed = mergeNonEmpty(remoteInfo.occupation, into: &meta.occupation) || changed
                changed = mergeNonEmpty(remoteInfo.family_status, into: &meta.familyStatus) || changed
                changed = mergeNonEmpty(remoteInfo.annual_income, into: &meta.annualIncome) || changed
                changed = mergeNonEmpty(remoteInfo.profile, into: &meta.profile) || changed
            } else {
                customerMetaLog("[CustomerDebug] skip remote profile merge because pendingProfileSync=true")
            }
            if !meta.pendingRemarkSync {
                let remoteRemark = (remoteInfo.remark ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !remoteRemark.isEmpty, meta.remark != remoteRemark {
                    meta.remark = remoteRemark
                    changed = true
                }
            } else {
                customerMetaLog("[CustomerDebug] skip remote remark merge because pendingRemarkSync=true")
            }
        }
        
        if let remoteFollowUps = try? await ChatService.shared.getFollowUps(phone: phone), !remoteFollowUps.isEmpty {
            customerMetaLog("[CustomerDebug] remote followUps count=\(remoteFollowUps.count) conversation=\(context.conversationKey)")
            var existingByRemoteID: [Int: String] = [:]
            for item in meta.followUps {
                if let rid = item.remoteID { existingByRemoteID[rid] = item.id }
            }
            for item in remoteFollowUps {
                let text = (item.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let ts = parseFollowUpTimestamp(item)
                let phoneValue = item.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
                let ownerName = followUpOwnerName(item)
                if let rid = item.id, let localID = existingByRemoteID[rid], let idx = meta.followUps.firstIndex(where: { $0.id == localID }) {
                    customerMetaLog("[CustomerDebug] merge remote followUp remoteID=\(rid) owner=\(ownerName ?? "-") localOwner=\(meta.followUps[idx].ownerName ?? "-")")
                    let mergedOwnerName: String? = {
                        let remoteOwner = (ownerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !remoteOwner.isEmpty { return remoteOwner }
                        return meta.followUps[idx].ownerName
                    }()
                    if meta.followUps[idx].text != text
                        || meta.followUps[idx].ts != ts
                        || meta.followUps[idx].ownerName != mergedOwnerName
                        || meta.followUps[idx].synced == false {
                        meta.followUps[idx].text = text
                        meta.followUps[idx].ts = ts
                        meta.followUps[idx].synced = true
                        meta.followUps[idx].phone = phoneValue
                        meta.followUps[idx].ownerName = mergedOwnerName
                        changed = true
                    }
                } else {
                    // 去重合并：本地刚新增且尚未绑定 remoteID 的记录，按“同内容+近时间”绑定为同一条。
                    if let mergeIdx = findLocalMergeCandidateIndex(meta.followUps, remoteText: text, remoteTimestamp: ts) {
                        customerMetaLog("[CustomerDebug] bind local followUp to remote remoteID=\(item.id ?? 0) owner=\(ownerName ?? "-")")
                        meta.followUps[mergeIdx].remoteID = item.id
                        meta.followUps[mergeIdx].synced = true
                        meta.followUps[mergeIdx].phone = phoneValue
                        if let ownerName, !ownerName.isEmpty {
                            meta.followUps[mergeIdx].ownerName = ownerName
                        }
                        changed = true
                    } else {
                        customerMetaLog("[CustomerDebug] append remote followUp remoteID=\(item.id ?? 0) owner=\(ownerName ?? "-")")
                        let newID = item.id.map { "remote_\($0)" } ?? "remote_\(UUID().uuidString)"
                        meta.followUps.append(
                            CustomerFollowUpRecord(
                                id: newID,
                                text: text,
                                ts: ts,
                                remoteID: item.id,
                                phone: phoneValue,
                                ownerName: ownerName,
                                synced: true
                            )
                        )
                        changed = true
                    }
                }
            }
            meta.followUps.sort { $0.ts > $1.ts }
        } else {
            customerMetaLog("[CustomerDebug] remote followUps empty conversation=\(context.conversationKey)")
        }
        
        if changed {
            save(meta, conversationKey: context.conversationKey)
            customerMetaLog("[CustomerDebug] pullRemoteAndMerge saved changed conversation=\(context.conversationKey) name=\(meta.name) remark=\(meta.remark) followUps=\(meta.followUps.count)")
        } else {
            customerMetaLog("[CustomerDebug] pullRemoteAndMerge no-change conversation=\(context.conversationKey) name=\(meta.name) remark=\(meta.remark) followUps=\(meta.followUps.count)")
        }
    }
    
    private func parseFollowUpTimestamp(_ item: FollowUpItem) -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let raw = (item.createAt ?? item.createdAt ?? item.created_at ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return now }
        
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "zh_CN")
        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: raw) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return now
    }
    
    private func followUpOwnerName(_ item: FollowUpItem) -> String? {
        let candidates = [
            item.creatorName,
            item.createdByName,
            item.ownerName,
            item.username,
            item.userName
        ]
        for raw in candidates {
            let clean = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        return nil
    }
    
    private func findLocalMergeCandidateIndex(
        _ localItems: [CustomerFollowUpRecord],
        remoteText: String,
        remoteTimestamp: Int64
    ) -> Int? {
        for (idx, local) in localItems.enumerated() {
            if local.remoteID != nil { continue }
            let localText = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if localText != remoteText { continue }
            let delta = abs(local.ts - remoteTimestamp)
            if delta <= 10 * 60 * 1000 { // 10 分钟窗口，覆盖服务端时间格式差异
                return idx
            }
        }
        return nil
    }
    
    private func mergeNonEmpty(_ remote: String?, into local: inout String) -> Bool {
        let clean = (remote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, local != clean else { return false }
        local = clean
        return true
    }
    
    private func buildProfileUpdateFields(_ meta: CustomerMeta) -> [String: Any] {
        var fields: [String: Any] = [:]
        let name = meta.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let remark = meta.remark.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = meta.age.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = meta.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let industry = meta.industry.trimmingCharacters(in: .whitespacesAndNewlines)
        let occupation = meta.occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyStatus = meta.familyStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let annualIncome = meta.annualIncome.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = meta.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !name.isEmpty { fields["name"] = name }
        if !remark.isEmpty { fields["remark"] = remark }
        if !age.isEmpty { fields["age"] = Int(age) ?? age }
        if !source.isEmpty { fields["source"] = source }
        if !industry.isEmpty { fields["industry"] = industry }
        if !occupation.isEmpty { fields["occupation"] = occupation }
        if !familyStatus.isEmpty { fields["family_status"] = familyStatus }
        if !annualIncome.isEmpty { fields["annual_income"] = annualIncome }
        if !profile.isEmpty { fields["profile"] = profile }
        return fields
    }
}
