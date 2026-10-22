import Testing
@testable import InfraTerminalUI

struct HexColorInputTests {
    @Test func acceptsSixHexDigitsWithOptionalPrefix() {
        #expect(HexColorInput.parse("FBFAF7") == 0xFBFAF7)
        #expect(HexColorInput.parse("#a65D3d") == 0xA65D3D)
        #expect(HexColorInput.parse("  #000000\n") == 0)
        #expect(HexColorInput.parse("FFFFFF") == 0xFFFFFF)
    }

    @Test func rejectsPartialOrMalformedColorWithoutPublishingIt() {
        for input in ["", "#", "ABC", "#12345", "1234567", "#12345678", "+12345", "##123456", "12 456", "GGGGGG", "１２３４５６"] {
            #expect(HexColorInput.parse(input) == nil, "Reject \(input)")
        }
    }
}
