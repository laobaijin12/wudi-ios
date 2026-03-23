//
//  QuickTemplateStore.swift
//  WudiApp
//
//  账号绑定的本地模板存储：话术模板 + 图片模板
//

import Foundation
import UIKit

struct QuickScriptTemplate: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var category: String
    var content: String
    var updatedAt: Date
}

struct QuickImageTemplate: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var imageBase64: String
    var updatedAt: Date
    
    func uiImage() -> UIImage? {
        guard !imageBase64.isEmpty, let data = Data(base64Encoded: imageBase64) else { return nil }
        return UIImage(data: data)
    }
    
    static func make(title: String, image: UIImage) -> QuickImageTemplate? {
        guard let data = image.jpegData(compressionQuality: 0.86) else { return nil }
        return QuickImageTemplate(
            id: UUID().uuidString,
            title: title,
            imageBase64: data.base64EncodedString(),
            updatedAt: Date()
        )
    }
}

enum QuickTemplateStore {
    private static let scriptPrefix = "script_templates_v2"
    private static let imagePrefix = "image_templates_v1"
    
    static func loadScriptTemplates() -> [QuickScriptTemplate] {
        load([QuickScriptTemplate].self, key: scopedKey(prefix: scriptPrefix))
    }
    
    static func saveScriptTemplate(_ item: QuickScriptTemplate) {
        var all = loadScriptTemplates()
        if let idx = all.firstIndex(where: { $0.id == item.id }) {
            all[idx] = item
        } else {
            all.append(item)
        }
        save(all, key: scopedKey(prefix: scriptPrefix))
    }
    
    static func deleteScriptTemplate(id: String) {
        let all = loadScriptTemplates().filter { $0.id != id }
        save(all, key: scopedKey(prefix: scriptPrefix))
    }
    
    static func loadImageTemplates() -> [QuickImageTemplate] {
        load([QuickImageTemplate].self, key: scopedKey(prefix: imagePrefix))
    }
    
    static func saveImageTemplate(_ item: QuickImageTemplate) {
        var all = loadImageTemplates()
        if let idx = all.firstIndex(where: { $0.id == item.id }) {
            all[idx] = item
        } else {
            all.append(item)
        }
        save(all, key: scopedKey(prefix: imagePrefix))
    }
    
    static func deleteImageTemplate(id: String) {
        let all = loadImageTemplates().filter { $0.id != id }
        save(all, key: scopedKey(prefix: imagePrefix))
    }
    
    private static func scopedKey(prefix: String) -> String {
        let uid = APIClient.shared.userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !uid.isEmpty { return "\(prefix)_uid_\(uid)" }
        let login = (UserDefaults.standard.string(forKey: "user_login_name") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !login.isEmpty { return "\(prefix)_login_\(login)" }
        return "\(prefix)_guest"
    }
    
    private static func load<T: Codable>(_ type: T.Type, key: String) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            if let empty = [] as? T { return empty }
            fatalError("Unsupported default decode type")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(type, from: data) else {
            if let empty = [] as? T { return empty }
            fatalError("Unsupported decode failure fallback")
        }
        return decoded
    }
    
    private static func save<T: Codable>(_ value: T, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
