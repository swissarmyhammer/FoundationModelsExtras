import Foundation
import FoundationModelsExtras
import Testing

/// ``GGUFFileSet``: the files of one GGUF model, chosen from the file list of a
/// repository or a folder and the path of a ``ModelRef``. No test uses the
/// network or the disk.
@Suite("GGUF file set: the model, its shards, and its projector from a file list")
struct GGUFFileSetTests {
    /// The shards of a split set in the folder `Q8_0`.
    private static let splitSet = [
        "Q8_0/model-Q8_0-00001-of-00003.gguf",
        "Q8_0/model-Q8_0-00002-of-00003.gguf",
        "Q8_0/model-Q8_0-00003-of-00003.gguf",
    ]

    @Test("a folder with one GGUF file loads that file")
    func folderWithOneFile() throws {
        let paths = ["Q4_K_M/model-Q4_K_M.gguf", "README.md"]

        let set = try GGUFFileSet.select(from: paths, under: "Q4_K_M")

        #expect(set.model == "Q4_K_M/model-Q4_K_M.gguf")
        #expect(set.shards == ["Q4_K_M/model-Q4_K_M.gguf"])
        #expect(set.projector == nil)
    }

    @Test("a folder with a split set loads its first shard, and keeps every shard in order")
    func folderWithASplitSet() throws {
        let set = try GGUFFileSet.select(from: Self.splitSet.reversed(), under: "Q8_0")

        #expect(set.model == "Q8_0/model-Q8_0-00001-of-00003.gguf")
        #expect(set.shards == Self.splitSet)
    }

    @Test("a path to one shard of a split set gives the whole set")
    func pathToAShard() throws {
        let set = try GGUFFileSet.select(from: Self.splitSet, under: "Q8_0/model-Q8_0-00002-of-00003.gguf")

        #expect(set.model == "Q8_0/model-Q8_0-00001-of-00003.gguf")
        #expect(set.shards == Self.splitSet)
    }

    @Test("a path to one file gives that file, also when its folder holds other models")
    func pathToOneFile() throws {
        let paths = ["model-Q4_K_M.gguf", "model-Q8_0.gguf"]

        let set = try GGUFFileSet.select(from: paths, under: "model-Q8_0.gguf")

        #expect(set.model == "model-Q8_0.gguf")
        #expect(set.shards == ["model-Q8_0.gguf"])
    }

    @Test("the repository root with one GGUF file loads that file")
    func rootWithOneFile() throws {
        let set = try GGUFFileSet.select(from: ["model.gguf", "config.json"], under: nil)

        #expect(set.model == "model.gguf")
    }

    @Test("more than one model fails with an error that lists the choices")
    func moreThanOneModelFails() {
        let paths = ["model-Q4_K_M.gguf", "model-Q5_K_M.gguf"] + Self.splitSet

        #expect(throws: GGUFSelectionError.ambiguous(
            path: nil,
            choices: ["Q8_0/model-Q8_0-00001-of-00003.gguf", "model-Q4_K_M.gguf", "model-Q5_K_M.gguf"])
        ) {
            try GGUFFileSet.select(from: paths, under: nil)
        }
    }

    @Test("the error of more than one model names each choice")
    func ambiguousErrorNamesTheChoices() {
        let error = GGUFSelectionError.ambiguous(path: "Q4", choices: ["Q4/a.gguf", "Q4/b.gguf"])

        #expect(error.errorDescription?.contains("Q4/a.gguf") == true)
        #expect(error.errorDescription?.contains("Q4/b.gguf") == true)
    }

    @Test("a folder with no GGUF model fails")
    func noModelFails() {
        #expect(throws: GGUFSelectionError.noModel(path: "Q4_K_M")) {
            try GGUFFileSet.select(from: ["Q8_0/model.gguf", "Q4_K_M/README.md"], under: "Q4_K_M")
        }
    }

    @Test("a path to a file that the list does not hold fails")
    func missingFileFails() {
        #expect(throws: GGUFSelectionError.noModel(path: "model-Q8_0.gguf")) {
            try GGUFFileSet.select(from: ["model-Q4_K_M.gguf"], under: "model-Q8_0.gguf")
        }
    }

    @Test("a split set with a missing shard fails, and names the missing shard")
    func incompleteSplitSetFails() {
        let paths = [Self.splitSet[0], Self.splitSet[2]]

        #expect(throws: GGUFSelectionError.incompleteSplitSet(
            model: Self.splitSet[0], missing: [Self.splitSet[1]])
        ) {
            try GGUFFileSet.select(from: paths, under: "Q8_0")
        }
    }

    @Test("an mmproj file beside the model is the projector, not a model and not a shard")
    func projectorBesideTheModel() throws {
        let paths = ["Q4_K_M/model-Q4_K_M.gguf", "Q4_K_M/mmproj-F16.gguf"]

        let set = try GGUFFileSet.select(from: paths, under: "Q4_K_M")

        #expect(set.model == "Q4_K_M/model-Q4_K_M.gguf")
        #expect(set.shards == ["Q4_K_M/model-Q4_K_M.gguf"])
        #expect(set.projector == "Q4_K_M/mmproj-F16.gguf")
        #expect(set.files == ["Q4_K_M/model-Q4_K_M.gguf", "Q4_K_M/mmproj-F16.gguf"])
    }

    @Test("an mmproj file in a folder above the model is the projector")
    func projectorAboveTheModel() throws {
        let paths = ["mmproj-BF16.gguf"] + Self.splitSet

        let set = try GGUFFileSet.select(from: paths, under: "Q8_0")

        #expect(set.projector == "mmproj-BF16.gguf")
    }

    @Test("the nearest folder with mmproj files gives the projector, the first by name")
    func nearestProjectorWins() throws {
        let paths = ["mmproj-BF16.gguf", "Q4/model.gguf", "Q4/mmproj-F32.gguf", "Q4/mmproj-F16.gguf"]

        let set = try GGUFFileSet.select(from: paths, under: "Q4")

        #expect(set.projector == "Q4/mmproj-F16.gguf")
    }

    @Test("an mmproj file alone is not a model")
    func projectorAloneIsNotAModel() {
        #expect(throws: GGUFSelectionError.noModel(path: nil)) {
            try GGUFFileSet.select(from: ["mmproj-F16.gguf"], under: nil)
        }
    }
}
