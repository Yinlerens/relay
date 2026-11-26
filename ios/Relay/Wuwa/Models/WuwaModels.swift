import Foundation
import SwiftUI

// MARK: - Session & Auth

struct WuwaSecureSession: Codable, Sendable, Equatable {
    var token: String
    var deviceId: String
    var mobileMasked: String
    var userId: String
    var userName: String
    var signature: String
}

struct WuwaCaptchaPayload: Codable, Sendable, Equatable {
    var captchaId: String
    var lotNumber: String
    var passToken: String
    var genTime: String
    var captchaOutput: String
}

// MARK: - Community Snapshot & Role Details

struct WuwaCommunityProfile: Codable, Sendable, Equatable {
    var userId: String
    var userName: String
    var mobileMasked: String
    var signature: String
    var level: Int
    var goldNum: Int
}

struct WuwaCommunityRole: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var userId: String
    var serverId: String
    var serverName: String
    var roleId: String
    var roleName: String
    var isDefault: Bool
    var gameLevel: String
    var roleNum: Int
    var phantomPercent: Double
    var achievementCount: Int
}

struct WuwaRoleSkin: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var iconUrl: String
    var pictureUrl: String
    var quality: Int
    var qualityName: String
    var isAddition: Bool
}

struct WuwaResonator: Codable, Sendable, Equatable, Identifiable {
    var roleId: Int
    var name: String
    var level: Int
    var breach: Int
    var iconUrl: String
    var pictureUrl: String
    var rarity: Int
    var attributeId: Int
    var attributeName: String
    var weaponTypeId: Int
    var weaponTypeName: String
    var chainLevel: Int
    var totalSkillLevel: Int
    var isMainRole: Bool
    var skin: WuwaRoleSkin?

    var id: Int { roleId }
}

struct WuwaAttribute: Codable, Sendable, Equatable {
    var name: String
    var value: String
    var iconUrl: String
    var sort: Int
}

struct WuwaChain: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var iconUrl: String
    var order: Int
    var unlocked: Bool
}

struct WuwaSkill: Codable, Sendable, Equatable {
    var id: Int
    var skillType: String
    var name: String
    var description: String
    var iconUrl: String
    var level: Int
}

struct WuwaSkillBranch: Codable, Sendable, Equatable {
    var branchId: Int
    var name: String
    var description: String
    var iconUrl: String
    var activeIconUrl: String
}

struct WuwaProp: Codable, Sendable, Equatable {
    var name: String
    var value: String
    var iconUrl: String
}

struct WuwaWeapon: Codable, Sendable, Equatable {
    var weaponId: Int
    var name: String
    var weaponType: Int
    var rarity: Int
    var iconUrl: String
    var effectName: String
    var effectDescription: String
    var level: Int
    var breach: Int
    var resonanceLevel: Int
    var mainProps: [WuwaProp]
}

struct WuwaEcho: Codable, Sendable, Equatable {
    var phantomId: Int
    var name: String
    var iconUrl: String
    var cost: Int
    var level: Int
    var quality: Int
    var skillDescription: String
    var setName: String
    var setIconUrl: String
    var setCount: Int
    var mainProps: [WuwaProp]
    var subProps: [WuwaProp]
}

struct WuwaResonatorDetail: Codable, Sendable, Equatable {
    var role: WuwaResonator
    var activeBranchId: Int
    var attributes: [WuwaAttribute]
    var bonusAttributes: [WuwaProp]
    var chains: [WuwaChain]
    var skills: [WuwaSkill]
    var skillBranches: [WuwaSkillBranch]
    var weapon: WuwaWeapon?
    var echoes: [WuwaEcho]
    var totalEchoCost: Int
}

struct WuwaCommunitySnapshot: Codable, Sendable, Equatable {
    var loggedIn: Bool
    var profile: WuwaCommunityProfile?
    var roles: [WuwaCommunityRole]
    var selectedRoleId: String?
    var resonators: [WuwaResonator]
    var lastSyncedAt: String?
    var notice: String?

    static let signedOut = WuwaCommunitySnapshot(
        loggedIn: false,
        profile: nil,
        roles: [],
        selectedRoleId: nil,
        resonators: [],
        lastSyncedAt: nil,
        notice: nil
    )
}

// MARK: - History & Gacha Persistence

struct WuwaResonatorHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var gameRoleId: String
    var resonatorId: Int
    var fingerprint: String
    var recordedAt: String
    var level: Int
    var chainLevel: Int
    var weaponName: String
    var weaponLevel: Int
    var weaponResonanceLevel: Int
    var attributes: [WuwaAttribute]
    var echoes: [WuwaEcho]
    var detail: WuwaResonatorDetail?
}

struct WuwaPullRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var playerId: String
    var poolType: Int
    var resourceId: Int
    var qualityLevel: Int
    var resourceType: String
    var name: String
    var count: Int
    var pulledAt: String
    var languageCode: String
    var occurrence: Int
    var importedAt: String
}

struct WuwaCatalogState: Codable, Sendable, Equatable {
    var entityType: String
    var entityId: String
    var favorite: Bool
    var owned: Bool
}

struct WuwaBackupBundle: Codable, Sendable {
    var schemaVersion: Int
    var exportedAt: String
    var pulls: [WuwaPullRecord]
    var settings: [String: String]?
    var catalogStates: [WuwaCatalogState]?
}

// MARK: - Navigation & Sections

enum WuwaSection: String, CaseIterable, Identifiable, Sendable {
    case roles
    case gacha
    case calc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roles: return "角色"
        case .gacha: return "唤取"
        case .calc: return "伤害计算"
        }
    }
}

enum WuwaRoute: Hashable, Sendable {
    case resonator(Int)
}

// MARK: - Canonical Wuthering Waves Element Styling

enum WuwaElementStyle {
    static func color(for elementName: String) -> Color {
        switch elementName {
        case "冷凝": return Color(hex: 0x2B93CF)
        case "热熔": return Color(hex: 0xDC5232)
        case "导电": return Color(hex: 0x8A50CF)
        case "气动": return Color(hex: 0x16A077)
        case "衍射": return Color(hex: 0xBE9010)
        case "湮灭": return Color(hex: 0xAE3670)
        default: return Palette.textSecondary
        }
    }

    static func gradeColor(_ grade: String) -> Color {
        switch grade.lowercased() {
        case "sss": return Color(hex: 0xE19A35)
        case "ss": return Palette.success
        case "s": return Color(hex: 0x2B93CF)
        case "a": return Color(hex: 0x8A50CF)
        case "b": return Palette.warning
        default: return Palette.textSecondary
        }
    }

    static func importanceColor(_ importance: String) -> Color {
        switch importance {
        case "s": return Palette.success
        case "a": return Color(hex: 0x2B93CF)
        case "b": return Palette.textPrimary
        default: return Palette.textTertiary
        }
    }
}
