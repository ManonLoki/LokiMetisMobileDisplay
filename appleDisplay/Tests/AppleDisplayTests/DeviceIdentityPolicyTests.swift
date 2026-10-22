import Foundation
import XCTest
@testable import AppleDisplay

/// 注入存储读写闭包验证身份恢复与失败关闭；不访问真实 Keychain，也不旋转已有身份。
final class DeviceIdentityPolicyTests: XCTestCase {
    private let phone = "12345678-1234-4abc-8def-123456789abc"
    private let otherPhone = "22345678-1234-4abc-8def-123456789abc"
    private let desktop = "32345678-1234-4abc-8def-123456789abc"
    private let otherDesktop = "42345678-1234-4abc-8def-123456789abc"

    func test_reinstall_uses_keychain_identity_without_replacing_it_or_reading_old_pairings() throws {
        let result = try DeviceIdentityPolicy.load(readIdentity: { self.phone },
            pairingAccounts: { XCTFail("Stable identity must not be guessed from pairings"); return [] },
            saveIdentity: { _ in XCTFail("Existing identity must not be overwritten") },
            generateIdentity: { XCTFail("Reinstall must not rotate an existing identity"); return self.phone })
        XCTAssertEqual(result, phone)
    }

    func test_missing_identity_restores_unique_old_identity_from_multiple_desktops() throws {
        var saved: String?
        let result = try DeviceIdentityPolicy.load(readIdentity: { nil },
            pairingAccounts: { [self.desktop + "." + self.phone, self.otherDesktop + "." + self.phone] },
            saveIdentity: { saved = $0 }, generateIdentity: { XCTFail("Old identity exists"); return self.otherPhone })
        XCTAssertEqual(result, phone)
        XCTAssertEqual(saved, phone)
    }

    func test_first_install_generates_only_after_both_sources_are_confirmed_absent() throws {
        var checks: [String] = []
        let result = try DeviceIdentityPolicy.load(readIdentity: { checks.append("keychain"); return nil },
            pairingAccounts: { checks.append("pairings"); return [] },
            saveIdentity: { checks.append("saved:" + $0) },
            generateIdentity: { checks.append("generated"); return self.phone })
        XCTAssertEqual(result, phone)
        XCTAssertEqual(checks, ["keychain", "pairings", "generated", "saved:" + phone])
    }

    func test_ambiguous_old_identities_never_choose_largest_or_first_group() throws {
        let accounts = [desktop + "." + phone, otherDesktop + "." + otherPhone]
        for order in [accounts, accounts.reversed().map { $0 }] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { nil },
                pairingAccounts: { order }, saveIdentity: { _ in XCTFail("Ambiguous identity must not be committed") },
                generateIdentity: { XCTFail("Ambiguity is not first install"); return self.phone })) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, .ambiguousPairedIdentity)
            }
        }
    }

    func test_locked_keychain_or_pairing_index_failure_cannot_become_a_new_identity() {
        for failingSource in ["keychain", "pairings"] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: {
                if failingSource == "keychain" { throw DeviceIdentityFailure.keychainUnavailable }; return nil
            }, pairingAccounts: {
                throw DeviceIdentityFailure.keychainUnavailable
            }, saveIdentity: { _ in XCTFail("Read failure must not write") },
                generateIdentity: { XCTFail("Read failure must not generate"); return self.phone }))
        }
    }

    func test_corrupt_existing_identity_does_not_rebind_credentials() {
        for saved in ["bad", SharedValidation.zeroId] {
            XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { saved },
                pairingAccounts: { XCTFail("Do not inspect credentials after corruption"); return [] },
                saveIdentity: { _ in XCTFail("Do not overwrite corrupt identity") })) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, .invalidIdentity)
            }
        }
    }

    func test_failed_identity_write_does_not_report_an_active_identity() {
        XCTAssertThrowsError(try DeviceIdentityPolicy.load(readIdentity: { nil },
            pairingAccounts: { [self.desktop + "." + self.phone] }, saveIdentity: { _ in throw DeviceIdentityFailure.keychainWriteFailed })) {
            XCTAssertEqual($0 as? DeviceIdentityFailure, .keychainWriteFailed)
        }
    }

    func test_pairing_index_rejects_malformed_zero_duplicate_self_pair_and_oversized_sets() {
        let valid = desktop + "." + phone
        let cases = [["bad"], [valid + ".extra"], [desktop + "." + phone.uppercased()],
            [SharedValidation.zeroId + "." + phone], [desktop + "." + SharedValidation.zeroId],
            [phone + "." + phone], [valid, valid], Array(repeating: valid, count: 65)]
        for accounts in cases {
            XCTAssertThrowsError(try DeviceIdentityPolicy.uniquePairedIdentity(accounts: accounts)) {
                XCTAssertEqual($0 as? DeviceIdentityFailure, .invalidPairingIndex)
            }
        }
    }
}
