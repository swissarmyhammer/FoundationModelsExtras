import FoundationModels

/// An error encountered while fusing `AnyOperation` metadata into one
/// flat-union `GenerationSchema`.
///
/// Unlike `OperationError` — which covers failures at dispatch time, once a
/// `GeneratedContent` payload is in hand — `SchemaFusionError` surfaces a
/// problem in the *operation set itself*, caught once at fusion time (an
/// `OperationTool`'s `init`), well before any model call.
public enum SchemaFusionError: Error, Sendable, Equatable {
    /// An operation declares a parameter whose name normalizes to `"op"`
    /// (case-insensitively, ignoring `_`/`-` separators), colliding with
    /// the fused schema's required `op` discriminator field.
    ///
    /// `opString` identifies the offending operation (`"verb noun"`);
    /// `parameter` is the parameter's declared, pre-normalization name.
    case reservedParameterName(opString: String, parameter: String)
}

extension SchemaFusionError: CustomStringConvertible {
    /// A human-readable summary suitable for CLI and log output.
    public var description: String {
        switch self {
        case let .reservedParameterName(opString, parameter):
            return
                "operation '\(opString)' declares parameter '\(parameter)', which is reserved: "
                + "it normalizes to 'op', colliding with the fused-tool discriminator field"
        }
    }
}

/// Builds the flat-union `GenerationSchema` a fused `OperationTool` presents
/// to the model, from the `AnyOperation` metadata of every operation it
/// carries.
///
/// Per plan.md's "Schema fusion — DECIDED": one object schema with a
/// required `op` string enum (every operation's `opString`, in `operations`
/// order) plus the union of every operation's fields, all declared
/// `isOptional`. Per-operation requiredness is enforced at dispatch instead
/// of by the schema (see `OperationError`) — the decided design trades
/// schema-level requiredness for a schema roughly the size of one
/// operation's fields instead of `operations.count` copies of them, and
/// sidesteps an Apple-confirmed enum-enforcement bug on discriminated
/// `anyOf`-of-object schemas. Fields sharing a name across operations are
/// declared once: the first operation (in `operations` order) to declare a
/// name wins that property's description on collision. Field order is
/// deterministic: by the index of the first operation to declare each name,
/// then alphabetically among names first declared by the same operation.
public enum SchemaFusion {
    /// Fuses `operations` into one `GenerationSchema` named `name`.
    ///
    /// - Parameters:
    ///   - operations: The fused tool's operations. The `op` enum's value
    ///     order follows this array's order; the field union's order is
    ///     derived from it (see `SchemaFusion`'s type-level documentation).
    ///   - name: The schema's root type name.
    ///   - description: A human- and model-facing summary of the fused
    ///     tool, or `nil` for none.
    /// - Returns: The fused schema, ready to hand to
    ///   `FoundationModels.Tool.parameters`.
    /// - Throws: `SchemaFusionError.reservedParameterName` if any operation
    ///   declares a parameter whose name normalizes to `"op"`; rethrows
    ///   `GenerationSchema.SchemaError` if Apple's schema builder rejects
    ///   the assembled `DynamicGenerationSchema` for a reason this function
    ///   does not itself guard against.
    public static func fuse<Context>(
        _ operations: [AnyOperation<Context>],
        name: String,
        description: String? = nil
    ) throws -> GenerationSchema {
        let opName = OperationKeys.opFieldName
        let opDescription = OperationKeys.opFieldDescription
        let opProperty = DynamicGenerationSchema.Property(
            name: opName,
            description: opDescription,
            schema: DynamicGenerationSchema(
                name: opName,
                description: opDescription,
                anyOf: operations.map(\.opString)
            ),
            isOptional: false
        )

        let root = DynamicGenerationSchema(
            name: name,
            description: description,
            properties: [opProperty] + (try fieldProperties(for: operations))
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Builds the all-optional field union: one `Property` per uniquely
    /// named parameter across `operations`, ordered by first-seen operation
    /// index and then alphabetically by name within that operation, with
    /// the first-seen description on a name collision.
    private static func fieldProperties<Context>(
        for operations: [AnyOperation<Context>]
    ) throws -> [DynamicGenerationSchema.Property] {
        var firstSeen: [String: FirstSeenField] = [:]

        for (opIndex, operation) in operations.enumerated() {
            for parameter in operation.parameters {
                guard OperationKeys.normalized(parameter.name) != OperationKeys.opFieldName else {
                    throw SchemaFusionError.reservedParameterName(opString: operation.opString, parameter: parameter.name)
                }
                guard firstSeen[parameter.name] == nil else { continue }
                firstSeen[parameter.name] = FirstSeenField(opIndex: opIndex, meta: parameter)
            }
        }

        return firstSeen.values.sorted(by: FirstSeenField.orderedBeforeInFusedSchema).map { field in
            DynamicGenerationSchema.Property(
                name: field.meta.name,
                description: field.meta.description,
                schema: dynamicSchema(for: field.meta.type),
                isOptional: true
            )
        }
    }
}

/// A parameter name's place in the fused field union: the index (in
/// `operations` order) of the first operation to declare it, paired with
/// the metadata that operation declared for it.
///
/// Every `FirstSeenField` is keyed by a unique parameter name, so
/// `orderedBeforeInFusedSchema` is a strict total order — `.sorted` on a
/// collection of these always produces the same result regardless of the
/// input collection's own (possibly randomized, e.g. `Dictionary.values`)
/// iteration order.
fileprivate struct FirstSeenField {
    /// The index, in `operations` order, of the first operation to declare
    /// this parameter name.
    fileprivate let opIndex: Int

    /// The metadata the first-declaring operation gave this parameter.
    fileprivate let meta: ParamMeta

    /// The fused schema's deterministic field order: by `opIndex`, then
    /// alphabetically by `meta.name` among fields first declared by the
    /// same operation.
    fileprivate static func orderedBeforeInFusedSchema(_ lhs: FirstSeenField, _ rhs: FirstSeenField) -> Bool {
        if lhs.opIndex != rhs.opIndex {
            return lhs.opIndex < rhs.opIndex
        }
        return lhs.meta.name < rhs.meta.name
    }
}

/// Maps a `ParamMeta.type` to the `DynamicGenerationSchema` FoundationModels
/// uses to constrain that field's generated value.
///
/// Deliberately does not consult `ParamMeta.allowedValues`: per plan.md's
/// "Schema fusion — DECIDED", the fused schema's job is the flat-union
/// shape and the `op` discriminator, not per-field value constraints — and
/// the same enum-enforcement bug that ruled out a discriminated-`anyOf`
/// schema (see `SchemaFusion`'s type-level documentation) would make an
/// `allowedValues`-derived `anyOf` here just as unenforced. Closed-set
/// values are still validated at dispatch time, where `ParamMeta` remains
/// available.
private func dynamicSchema(for type: ParamType) -> DynamicGenerationSchema {
    switch type {
    case .string:
        return DynamicGenerationSchema(type: String.self)
    case .integer:
        return DynamicGenerationSchema(type: Int.self)
    case .number:
        return DynamicGenerationSchema(type: Double.self)
    case .boolean:
        return DynamicGenerationSchema(type: Bool.self)
    case .array(let element):
        return DynamicGenerationSchema(arrayOf: dynamicSchema(for: element))
    }
}

