import Testing
@testable import MPPCore

@Suite("MPP metadata")
struct MPPMetadataTests {
    @Test("version is a three-component semantic version")
    func versionIsSemanticVersion() {
        let components = MPP.version.split(separator: ".")
        #expect(components.count == 3)
        for component in components {
            #expect(Int(component) != nil, "version component \(component) is not numeric")
        }
    }

    @Test("declares the core protocol drafts it targets")
    func declaresCoreSpecificationDrafts() {
        #expect(MPP.supportedSpecifications.contains("draft-httpauth-payment-00"))
        #expect(MPP.supportedSpecifications.contains("draft-payment-transport-mcp-00"))
    }

    @Test("specification list has no duplicates")
    func specificationListHasNoDuplicates() {
        #expect(Set(MPP.supportedSpecifications).count == MPP.supportedSpecifications.count)
    }
}
