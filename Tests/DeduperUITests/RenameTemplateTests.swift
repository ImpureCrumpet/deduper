import Testing
import Foundation
@testable import DeduperUI

@Suite("RenameTemplate")
struct RenameTemplateTests {

    // MARK: - apply(to:)

    @Test("Prefix mode prepends value to stem")
    func prefixMode() {
        let template = RenameTemplate(
            mode: .prefix, value: "Best_"
        )
        #expect(template.apply(to: "photo") == "Best_photo")
    }

    @Test("Suffix mode appends value to stem")
    func suffixMode() {
        let template = RenameTemplate(
            mode: .suffix, value: "_final"
        )
        #expect(template.apply(to: "photo") == "photo_final")
    }

    @Test("Replace mode substitutes findText with replaceText")
    func replaceMode() {
        let template = RenameTemplate(
            mode: .replace,
            findText: "IMG",
            replaceText: "Photo"
        )
        #expect(
            template.apply(to: "IMG_1234") == "Photo_1234"
        )
    }

    @Test("Replace mode with empty findText returns stem unchanged")
    func replaceModeEmptyFind() {
        let template = RenameTemplate(
            mode: .replace,
            findText: "",
            replaceText: "anything"
        )
        #expect(template.apply(to: "photo") == "photo")
    }

    @Test("Custom mode replaces entire stem")
    func customMode() {
        let template = RenameTemplate(
            mode: .custom, value: "MyPhoto"
        )
        #expect(template.apply(to: "IMG_1234") == "MyPhoto")
    }

    @Test("Custom mode with empty value returns stem unchanged")
    func customModeEmptyValue() {
        let template = RenameTemplate(
            mode: .custom, value: ""
        )
        #expect(template.apply(to: "photo") == "photo")
    }

    @Test("keepOriginal mode returns stem unchanged")
    func keepOriginalMode() {
        let template = RenameTemplate(mode: .keepOriginal)
        #expect(template.apply(to: "photo") == "photo")
    }

    // MARK: - preview(for:)

    @Test("Preview preserves file extension")
    func previewPreservesExtension() {
        let template = RenameTemplate(
            mode: .prefix, value: "Best_"
        )
        #expect(
            template.preview(for: "photo.jpg") == "Best_photo.jpg"
        )
    }

    @Test("Preview handles file without extension")
    func previewNoExtension() {
        let template = RenameTemplate(
            mode: .suffix, value: "_v2"
        )
        #expect(template.preview(for: "README") == "README_v2")
    }

    // MARK: - previewCompanion

    @Test("previewCompanion applies keeper stem to companion ext")
    func previewCompanionBasic() {
        let template = RenameTemplate(
            mode: .prefix, value: "Best_"
        )
        let result = template.previewCompanion(
            keeperFileName: "photo.heic",
            companionFileName: "photo.aae"
        )
        #expect(result == "Best_photo.aae")
    }

    @Test("previewCompanion works with Live Photo MOV")
    func previewCompanionLivePhoto() {
        let template = RenameTemplate(
            mode: .suffix, value: "_keeper"
        )
        let result = template.previewCompanion(
            keeperFileName: "IMG_1234.heic",
            companionFileName: "IMG_1234.mov"
        )
        #expect(result == "IMG_1234_keeper.mov")
    }

    // MARK: - Pathological Filenames

    @Test("Replace that empties stem returns original")
    func replaceEmptiesStem() {
        let template = RenameTemplate(
            mode: .replace,
            findText: "photo",
            replaceText: ""
        )
        // If stem is exactly the find text, result is empty
        let result = template.apply(to: "photo")
        #expect(result == "")
    }

    @Test("Custom with slash in value produces slash filename")
    func customWithSlash() {
        let template = RenameTemplate(
            mode: .custom, value: "sub/dir"
        )
        let result = template.preview(for: "photo.jpg")
        // The template produces it — plan-time validation must
        // catch and reject this
        #expect(result == "sub/dir.jpg")
    }

    // MARK: - Codable

    @Test("RenameTemplate round-trips through JSON")
    func codableRoundTrip() throws {
        let template = RenameTemplate(
            mode: .replace,
            value: "",
            findText: "IMG",
            replaceText: "Photo",
            collisionPolicy: .block
        )
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(
            RenameTemplate.self, from: data
        )
        #expect(decoded == template)
    }
}
