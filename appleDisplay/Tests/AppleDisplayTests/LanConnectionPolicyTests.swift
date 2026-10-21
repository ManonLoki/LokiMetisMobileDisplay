import XCTest
@testable import AppleDisplay

/// 自动发现跟随前后台，自动连接只使用已保存信任。
final class LanConnectionPolicyTests: XCTestCase {
    /// 初装也自动发现；发现未配对候选不能隐式选择或开启配对码。
    func test_first_foreground_discovers_without_starting_first_pairing() {
        var policy = LanConnectionPolicy()
        XCTAssertFalse(policy.requested)
        policy.enterForeground()
        XCTAssertTrue(policy.requested)
        XCTAssertNil(policy.automaticSelection(selectedId: nil, paired: [], available: ["new-desktop"]))
    }

    /// 后台暂停且重试不能绕过前台条件，返回前台继续发现与已有信任认证。
    func test_background_pauses_and_foreground_resumes_paired_connection() {
        var policy = LanConnectionPolicy()
        policy.enterForeground()
        XCTAssertEqual(policy.automaticSelection(selectedId: nil, paired: ["trusted"], available: ["new", "trusted"]), "trusted")
        policy.leaveForeground(); policy.discover()
        XCTAssertFalse(policy.requested)
        XCTAssertNil(policy.nextDelay())
        XCTAssertNil(policy.automaticSelection(selectedId: "trusted", paired: ["trusted"], available: ["trusted"]))
        policy.enterForeground()
        XCTAssertTrue(policy.requested)
        XCTAssertEqual(policy.automaticSelection(selectedId: "trusted", paired: ["trusted"], available: ["trusted"]), "trusted")
    }

    /// 已取消或过期的首次配对保留候选选择，但不能在返回前台后自动重开密码窗口。
    func test_unpaired_selection_requires_another_explicit_selection_after_pause() {
        var policy = LanConnectionPolicy(); policy.enterForeground()
        policy.leaveForeground(); policy.enterForeground()
        XCTAssertNil(policy.automaticSelection(selectedId: "new", paired: ["trusted"], available: ["new", "trusted"]))
        XCTAssertNil(policy.automaticSelection(selectedId: "trusted", paired: ["trusted"], available: ["new"]))
    }

    /// 八次退避耗尽后不循环重试，真正的前台恢复才重新发放预算。
    func test_foreground_reopens_only_the_transport_retry_budget() {
        var policy = LanConnectionPolicy(); policy.enterForeground()
        XCTAssertEqual((0..<8).compactMap { _ in policy.nextDelay() }, [0.5, 1, 2, 4, 8, 8, 8, 8])
        XCTAssertNil(policy.nextDelay())
        XCTAssertNil(policy.automaticSelection(selectedId: "trusted", paired: ["trusted"], available: ["trusted"]))
        policy.leaveForeground(); policy.enterForeground()
        XCTAssertEqual(policy.nextDelay(), 0.5)
    }

    /// 新端点事件可恢复耗尽预算，但在后台不能启动网络。
    func test_endpoint_renewal_does_not_start_background_networking() {
        var policy = LanConnectionPolicy(); policy.enterForeground()
        for _ in 0..<8 { _ = policy.nextDelay() }
        policy.renewedEndpoint(); XCTAssertEqual(policy.nextDelay(), 0.5)
        policy.leaveForeground(); policy.renewedEndpoint(); XCTAssertNil(policy.nextDelay())
    }
}
