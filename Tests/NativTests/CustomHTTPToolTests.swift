import XCTest
@testable import NativServerKit

final class CustomHTTPToolTests: XCTestCase {
    func testMakesAStableToolDefinitionFromAnHTTPTool() throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather lookup",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        )

        XCTAssertEqual(tool.toolName, "custom__weather_lookup")
        XCTAssertEqual(try tool.definition().function.name, "custom__weather_lookup")
    }

    func testRejectsAnInvalidEndpointAndSchema() {
        XCTAssertThrowsError(try CustomHTTPTool.make(
            name: "Weather",
            summary: "",
            endpoint: "example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        ))
        XCTAssertThrowsError(try CustomHTTPTool.make(
            name: "Weather",
            summary: "",
            endpoint: "https://example.com/weather",
            parametersJSON: "[]"
        ))
    }

    func testSettingsRoundTripCustomTools() throws {
        let tool = try CustomHTTPTool.make(
            name: "Weather",
            summary: "Looks up a forecast.",
            endpoint: "https://example.com/weather",
            parametersJSON: CustomHTTPTool.defaultParametersJSON
        )
        let settings = NativSettings(customTools: [tool])
        let decoded = try PropertyListDecoder().decode(
            NativSettings.self,
            from: PropertyListEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.customTools, [tool])
    }
}
