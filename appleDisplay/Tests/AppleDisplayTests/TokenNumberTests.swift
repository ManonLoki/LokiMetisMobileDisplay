import XCTest
@testable import AppleDisplay

/// 核对整数格式器在单位晋级、舍入和 UInt64 最大值处的结果，并区分缺失与精确零。
final class TokenNumberTests: XCTestCase {
    func testCompactThresholdsRoundingAndFullUInt64Range() {
        let cases = [
            ("0", "0"), ("999", "999"), ("1000", "1K"), ("1004", "1K"),
            ("1005", "1.01K"), ("1250", "1.25K"), ("999994", "999.99K"),
            ("999995", "1M"), ("1000000", "1M"), ("221193571", "221.19M"),
            ("999995000", "1B"), ("999999999", "1B"), ("1000000000", "1B"),
            ("18446744073709551615", "18446744073.71B")
        ]
        for (raw, expected) in cases { XCTAssertEqual(TokenNumber.compact(raw), expected, raw) }
        XCTAssertEqual(TokenNumber.grouped("18446744073709551615"), "18,446,744,073,709,551,615")
        XCTAssertEqual(TokenNumber.grouped("0"), "0")
    }

    func testMissingValuesAndQualityRemainDistinctFromNumericZero() {
        let zero = WidgetAmount(total: "0", availability: .available, completeness: .partial, confidence: .derived)
        let missing = WidgetAmount(total: nil, availability: .noRecords, completeness: .unknown, confidence: .exact)
        let unavailable = WidgetAmount(total: nil, availability: .unavailable, completeness: .unknown, confidence: .exact)
        XCTAssertTrue(zero.hasNumericValue)
        XCTAssertEqual(zero.compactText, "0")
        XCTAssertEqual(zero.exactText, "0")
        XCTAssertEqual(zero.quality, "部分·估算")
        XCTAssertFalse(missing.hasNumericValue)
        XCTAssertEqual(missing.compactText, "无记录")
        XCTAssertEqual(unavailable.compactText, "不可用")
        XCTAssertEqual(TokenNumber.grouped("不可用"), "不可用")
    }
}
