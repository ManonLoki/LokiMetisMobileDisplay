import Foundation
import XCTest
@testable import AppleDisplay

final class DeviceIdentityPolicyTests: XCTestCase {
    private let phone = "12345678-1234-4abc-8def-123456789abc"
    private let otherPhone = "22345678-1234-4abc-8def-123456789abc"
    private let desktop = "32345678-1234-4abc-8def-123456789abc"
    private let otherDesktop = "42345678-1234-4abc-8def-123456789abc"

    func test_reinstall_uses_keychain_identity_without_replacing_it_or_reading_old_pairings() throws {
        let result = try DeviceIdentityPolicy.load(readIdentity: { self.phone }, readLegacyFile: { nil },
            legacyPairingAccounts: { XCTFail("Stable identity must not be guessed from pairings"); return [] },
            saveIdentity: { _ in XCTFail("Existing identity must not be overwritten") },
            generateIdentity: { XCTFail("Reinstall must not rotate an existing identity"); return self.otherPhone })
        XCTAssertEqual(result, phone)
    }

    func test_upgrade_migrates_original_file_uuid_even_when_stale_pairing_groups_exist() throws {
        var writes: [String] = []
        let result = try DeviceIdentityPolicy.load(readIdentity: { nil }, readLegacyFile: { self.phone },
            legacyPairingAccounts: { XCTFail("Original file is authoritative for migration"); return [] },
            saveIdentity: { writes.append($0) })
        XCTAssertEqual(result, phone)
        XCTAssertEqual(writes, [phone])
    }

    func test_missing_identity_and_file_restore_unique_old_identity_from_multiple_desktops() throws {
        var saved: String?
        let result = try DeviceIdentityPolicy.load(readIdentity: { nil }, readLegacyFile: { nil },
            legacyPairingAccounts: { [self.desktop + "." + self.phone, self.otherDesktop + "." + self.phone] },
            saveIdentity: { saved = $0 }, generateIdentity: { XCTFail("Old identity exists"); return self.otherPhone })
        XCTAssertEqual(result, phone)
        XCTAssertEqual(saved, phone)
    }

    func test_first_install_generates_only_after_all_three_sources_are_confirmed_absent() throws {
        var checks: [String] = []
        let result = try DeviceIdentityPolicy.load(readIdentity: { checks.append("keychain"); return nil },
            readLegacyFile: { checks.append("file"); return nil },
            legacyPairingAccounts: { checks.append("pairings"); return [] },
            saveIdentity: { checks.append("saved:" + $0) },
            generateIdentity: { checks.append("generated"); return self.phone })
        XCTAssertEqual(result, phone)
        XCTAssertEqual(checks, ["keychain", "file", "pairings", "generated", "saved:" + phone])
    }

    func test_ambiguous_old_identities_never_choose_largest_or_first_group() throws {
        let accounts = [desktop + "." + phone, otherDesktop + "." + otherPhone]
        for order in [accounts, accounts.reversed().map { $0 }] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { nil }, readLegacyFile: { nil },
                legacyPairingAccounts: { order }, saveIdentity: { _ in XCTFail("Ambiguous identity must not be committed") },
                generateIdentity: { XCTFail("Ambiguity is not first install"); return self.phone })) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, .ambiguousLegacyIdentity)
            }
        }
    }

    func test_locked_keychain_or_pairing_index_failure_cannot_become_a_new_identity() {
        for failingSource in ["keychain", "file", "pairings"] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: {
                if failingSource == "keychain" { throw DeviceIdentityFailure.keychainUnavailable }; return nil
            }, readLegacyFile: {
                if failingSource == "file" { throw DeviceIdentityFailure.legacyStorageUnavailable }; return nil
            }, legacyPairingAccounts: {
                throw DeviceIdentityFailure.keychainUnavailable
            }, saveIdentity: { _ in XCTFail("Read failure must not write") },
                generateIdentity: { XCTFail("Read failure must not generate"); return self.phone }))
        }
    }

    func test_corrupt_or_conflicting_existing_identity_does_not_rebind_credentials() {
        for (saved, legacy, expected) in [
            ("bad", phone, DeviceIdentityFailure.invalidIdentity),
            (phone, "bad", .legacyStorageInvalid),
            (phone, otherPhone, .conflictingIdentity),
            (SharedValidation.zeroId, phone, .invalidIdentity)
        ] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { saved }, readLegacyFile: { legacy },
                legacyPairingAccounts: { XCTFail("Do not inspect credentials after corruption"); return [] },
                saveIdentity: { _ in XCTFail("Do not overwrite corrupt/conflicting identity") })) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, expected)
            }
        }
    }

    func test_unsaved_migration_does_not_report_an_active_identity() {
        XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { nil }, readLegacyFile: { self.phone },
            legacyPairingAccounts: { [] }, saveIdentity: { _ in throw DeviceIdentityFailure.keychainWriteFailed })) {
            XCTAssertEqual($0 as? DeviceIdentityFailure, .keychainWriteFailed)
        }
    }

    func test_legacy_index_rejects_malformed_zero_duplicate_self_pair_and_oversized_sets() {
        let valid = desktop + "." + phone
        let cases = [["bad"], [valid + ".extra"], [desktop + "." + phone.uppercased()],
            [SharedValidation.zeroId + "." + phone], [desktop + "." + SharedValidation.zeroId],
            [phone + "." + phone], [valid, valid], Array(repeating: valid, count: 65)]
        for accounts in cases {
            XCTAssertThrowsError(try DeviceIdentityPolicy.uniqueLegacyIdentity(accounts: accounts)) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, .invalidPairingIndex)
            }
        }
    }

    func test_pending_recovery_can_only_resume_same_package_before_or_after_identity_commit() throws {
        let digest = String(repeating: "a", count: 64)
        let pending = try DeviceIdentityRecovery(previousId: phone, targetId: otherPhone, fingerprint: digest)
        XCTAssertNoThrow(try pending.accepts(currentId: phone, targetId: otherPhone, fingerprint: digest))
        XCTAssertNoThrow(try pending.accepts(currentId: otherPhone, targetId: otherPhone, fingerprint: digest))
        for current in [nil, desktop] as [String?] {
            XCTAssertThrowsError(try pending.accepts(currentId: current, targetId: otherPhone, fingerprint: digest))
        }
        XCTAssertThrowsError(try pending.accepts(currentId: phone, targetId: desktop, fingerprint: digest))
        XCTAssertThrowsError(try pending.accepts(currentId: phone, targetId: otherPhone, fingerprint: String(repeating: "b", count: 64)))
        let encoded = try JSONEncoder().encode(pending)
        let decoded = try JSONDecoder().decode(DeviceIdentityRecovery.self, from: encoded)
        XCTAssertEqual(decoded, pending)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
        XCTAssertThrowsError(try DeviceIdentityRecovery(previousId: phone, targetId: SharedValidation.zeroId, fingerprint: digest))
        XCTAssertThrowsError(try DeviceIdentityRecovery(previousId: phone, targetId: otherPhone, fingerprint: "bad"))
    }

    func test_recovery_package_explicitly_selects_only_a_complete_exact_existing_identity_group() throws {
        let first: [String: Any] = ["clientId": desktop, "deviceId": phone, "name": "桌面一",
            "secret": Data(repeating: 1, count: 32).base64EncodedString()]
        let second: [String: Any] = ["clientId": otherDesktop, "deviceId": phone, "name": "桌面二",
            "secret": Data(repeating: 2, count: 32).base64EncodedString()]
        let accounts = [desktop + "." + phone, otherDesktop + "." + phone, desktop + "." + otherPhone]
        XCTAssertThrowsError(try DeviceIdentityPolicy.uniqueLegacyIdentity(accounts: accounts))
        XCTAssertNoThrow(try DeviceIdentityPolicy.verifyRecoverySelection(deviceId: phone, materials: [first, second],
            accounts: accounts, storedMaterials: [second, first]))
        // 所选组遗漏一条、未知身份、或名称/secret发生变化，都不能以选择为由改写存量材料。
        XCTAssertThrowsError(try DeviceIdentityPolicy.verifyRecoverySelection(deviceId: phone, materials: [first],
            accounts: accounts, storedMaterials: [first, second]))
        XCTAssertThrowsError(try DeviceIdentityPolicy.verifyRecoverySelection(deviceId: phone, materials: [first, second],
            accounts: accounts, storedMaterials: [first]))
        for (key, value) in [("name", "另一个名称"), ("secret", Data(repeating: 3, count: 32).base64EncodedString())] {
            var changed = second; changed[key] = value
            XCTAssertThrowsError(try DeviceIdentityPolicy.verifyRecoverySelection(deviceId: phone, materials: [first, changed],
                accounts: accounts, storedMaterials: [first, second]))
        }
        XCTAssertThrowsError(try DeviceIdentityPolicy.verifyRecoverySelection(deviceId: phone, materials: [first, second],
            accounts: [desktop + "." + otherPhone], storedMaterials: [first, second]))
    }
}
