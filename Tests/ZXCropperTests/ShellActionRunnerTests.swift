import XCTest
@testable import ZXCropper

final class ShellActionRunnerTests: XCTestCase {
    func testRemgreenFuzzDefaultsTo25WhenEmpty() {
        let viewModel = EditorViewModel(imagePath: nil)

        viewModel.updateRemgreenFuzz("")

        XCTAssertEqual(viewModel.remgreenFuzzLabel, "25")
    }

    func testRemgreenFuzzFiltersToDigits() {
        let viewModel = EditorViewModel(imagePath: nil)

        viewModel.updateRemgreenFuzz("ab40%")

        XCTAssertEqual(viewModel.remgreenFuzz, "40")
        XCTAssertEqual(viewModel.remgreenFuzzLabel, "40")
    }

    func testBuildCommandQuotesArguments() {
        let command = ShellActionRunner.buildCommand(
            commandName: "remgreen",
            arguments: ["25", "/tmp/green image's copy.png"]
        )

        XCTAssertEqual(command, "remgreen '25' '/tmp/green image'\"'\"'s copy.png'")
    }

    func testRemgreenActionProducesSingleImageOutput() {
        XCTAssertTrue(ShellImageAction.remgreen.expectsSingleImageOutput)
        XCTAssertEqual(ShellImageAction.remgreen.title, "REMGREEN")
    }
}