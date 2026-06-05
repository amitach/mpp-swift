import Testing
@testable import MPPCore

// B10: MPPSensitiveSurfaces is the canonical registry of secret-bearing surfaces (the credential
// and receipt headers, the signing-secret env vars) so a logging/capture consumer redacts them in
// one place. These pin the names and the convenience collections; a separate test in MPPServerTests
// pins that the server's secret loader derives its env-var names from here (single source).
@Suite("MPPSensitiveSurfaces")
struct SensitiveSurfacesTests {
    @Test("the surface names are the protocol's secret-bearing header and env-var identifiers")
    func names() {
        #expect(MPPSensitiveSurfaces.credentialHeader == "Authorization")
        #expect(MPPSensitiveSurfaces.receiptHeader == "Payment-Receipt")
        #expect(MPPSensitiveSurfaces.currentSecretEnvironmentVariable == "MPP_SECRET_KEY")
        #expect(MPPSensitiveSurfaces.previousSecretEnvironmentVariable == "MPP_SECRET_KEY_PREVIOUS")
    }

    @Test("headerNames lists exactly the credential and receipt headers")
    func headerNames() {
        #expect(MPPSensitiveSurfaces.headerNames == ["Authorization", "Payment-Receipt"])
    }

    @Test("environmentVariableNames lists exactly the current and previous secret variables")
    func environmentVariableNames() {
        #expect(MPPSensitiveSurfaces.environmentVariableNames == [
            "MPP_SECRET_KEY", "MPP_SECRET_KEY_PREVIOUS",
        ])
    }

    @Test("the credential header is the standard Authorization header (carries the Payment scheme)")
    func credentialHeaderIsAuthorization() {
        // The credential travels as `Authorization: Payment ...`, so redacting the Authorization
        // header covers it; the scheme token itself is PaymentAuthScheme.name.
        #expect(MPPSensitiveSurfaces.credentialHeader == "Authorization")
        #expect(PaymentAuthScheme.name == "Payment")
    }
}
