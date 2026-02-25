import Testing
@testable import OsaurusCore

struct OpenClawProviderPresetTests {
    @Test
    func moonshotPreset_usesKimiDefaults() {
        let preset = OpenClawProviderPreset.moonshot
        #expect(preset.providerId == "moonshot")
        #expect(preset.baseUrl == "https://api.moonshot.ai/v1")
        #expect(preset.apiCompatibility == "openai-completions")
        #expect(preset.needsKey == true)
        #expect(preset.consoleURL == "https://platform.moonshot.ai/console/api-keys")
    }

    @Test
    func kimiCodingPreset_usesCanonicalKimiCodingEndpoint() {
        let preset = OpenClawProviderPreset.kimiCoding
        #expect(preset.providerId == "kimi-coding")
        #expect(preset.baseUrl == "https://api.kimi.com/coding")
        #expect(preset.apiCompatibility == "anthropic-messages")
        #expect(preset.needsKey == true)
        #expect(preset.consoleURL == "https://www.kimi.com/code/en")
    }
}
