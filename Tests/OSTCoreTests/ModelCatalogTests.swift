import OSTCore
import Testing

@Test func bundledManifestIsExactAndValid() throws {
    let catalog = try ModelCatalog.bundled()
    #expect(catalog.models.count == 4)
    #expect(Set(catalog.models.map(\.adapter)) == [.qwen3ASR, .qwen3Translation])
    for model in catalog.models {
        #expect(model.downloadBytes == model.files.reduce(0) { $0 + $1.bytes })
        #expect(model.revision.count == 40)
        #expect(model.files.allSatisfy { $0.sha256.count == 64 })
        #expect(model.license.spdxID == "Apache-2.0")
    }
}

@Test func bundledThirdPartyNoticesAreReadable() throws {
    let apache = try ThirdPartyNotices.text(at: "ThirdParty/Apache-2.0.txt")
    let runtime = try ThirdPartyNotices.text(at: ThirdPartyNotices.runtimeResource)
    #expect(apache.contains("Apache License"))
    #expect(runtime.contains("mlx-swift 0.31.6"))
    #expect(throws: ThirdPartyNoticeError.self) {
        try ThirdPartyNotices.text(at: "../outside.txt")
    }
}

@Test func manifestRejectsAChangedFileHash() throws {
    let catalog = try ModelCatalog.bundled()
    let original = catalog.models[0]
    var files = original.files
    files[0] = ModelFileDescriptor(
        path: files[0].path,
        bytes: files[0].bytes,
        sha256: "not-a-sha"
    )
    let changed = ModelDescriptor(
        id: original.id,
        revision: original.revision,
        adapter: original.adapter,
        task: original.task,
        quantization: original.quantization,
        supportedLanguages: original.supportedLanguages,
        capabilities: original.capabilities,
        downloadBytes: original.downloadBytes,
        estimatedPeakBytes: original.estimatedPeakBytes,
        license: original.license,
        files: files
    )
    let invalid = ModelCatalog(
        schemaVersion: catalog.schemaVersion,
        models: [changed] + catalog.models.dropFirst()
    )
    #expect(throws: ModelCatalogError.self) { try invalid.validate() }
}
