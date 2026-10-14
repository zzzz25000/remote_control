import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testEmergencyFrameClearsOutputsAndAdvancesSequence() throws {
    let previous = Data([
      0xA5, 0x5A, 0x01, 0xFF, 0xE8, 0x03, 0x18, 0xFC,
      0x64, 0x00, 0x9C, 0xFF, 0x02, 0x00, 0x01, 0x00,
      0xFF, 0x80, 0x00, 0x00,
    ])
    let disabled = try XCTUnwrap(BleBridge.disabledFrame(after: previous))
    XCTAssertEqual(disabled.count, 20)
    XCTAssertEqual(Array(disabled.prefix(18)), [0xA5, 0x5A, 1, 0] + [UInt8](repeating: 0, count: 14))
    // CCITT-FALSE over version/sequence and fourteen zero payload bytes.
    XCTAssertEqual(Array(disabled.suffix(2)), [0x2E, 0xC2])
  }

  func testEmergencyFramePreservesProtocolAndAdvancesNonWrappingSequence() throws {
    let previous = Data([0xA5, 0x5A, 1, 42] + [UInt8](repeating: 0xFF, count: 16))
    let disabled = try XCTUnwrap(BleBridge.disabledFrame(after: previous))
    XCTAssertEqual(Array(disabled.prefix(4)), [0xA5, 0x5A, 1, 43])
    XCTAssertEqual(Array(disabled[4..<18]), [UInt8](repeating: 0, count: 14))
  }

  func testEmergencyFrameRejectsUnknownProtocol() {
    XCTAssertNil(BleBridge.disabledFrame(after: Data()))
    XCTAssertNil(BleBridge.disabledFrame(after: Data(repeating: 0, count: 20)))
    XCTAssertNil(BleBridge.disabledFrame(after: Data([0xA5, 0x5A, 2] + [UInt8](repeating: 0, count: 17))))
  }

}
