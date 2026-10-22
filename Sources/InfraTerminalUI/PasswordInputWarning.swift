import Carbon
import Foundation

enum PasswordInputWarning {
    static func message(password: String, isFocused: Bool, koreanInputSource: Bool) -> String? {
        if password.unicodeScalars.contains(where: isHangul) {
            return "비밀번호에 한글이 포함되어 있어요. 의도한 입력인지 확인하세요."
        }
        return isFocused && koreanInputSource ? "영문 입력 상태가 아니에요. 입력기를 확인하세요." : nil
    }

    static func isKoreanInputSource(languages: [String], isASCIICapable: Bool) -> Bool {
        !isASCIICapable && languages.contains { $0.split(separator: "-").first == "ko" }
    }

    static var currentSourceIsKorean: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let languagesPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let asciiPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        let languages = Unmanaged<CFArray>.fromOpaque(languagesPointer).takeUnretainedValue() as? [String] ?? []
        let ascii = Unmanaged<CFBoolean>.fromOpaque(asciiPointer).takeUnretainedValue()
        return isKoreanInputSource(languages: languages, isASCIICapable: CFBooleanGetValue(ascii))
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC: return true
        default: return false
        }
    }
}
