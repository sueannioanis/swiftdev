import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// avoids depending on SwiftifyImport.swift
// all instances are reparsed and reinstantiated by the macro anyways,
// so linking is irrelevant
enum SwiftifyExpr: Hashable {
  case param(_ index: Int)
  case `return`
  case `self`
}

extension SwiftifyExpr: CustomStringConvertible {
  var description: String {
    switch self {
    case .param(let index): return ".param(\(index))"
    case .return: return ".return"
    case .self: return ".self"
    }
  }
}

enum DependenceType {
  case borrow, copy
}

struct LifetimeDependence {
  let dependsOn: SwiftifyExpr
  let type: DependenceType
}

protocol ParamInfo: CustomStringConvertible {
  var description: String { get }
  var original: SyntaxProtocol { get }
  var pointerIndex: SwiftifyExpr { get }
  var nonescaping: Bool { get set }
  var dependencies: [LifetimeDependence] { get set }

  func getBoundsCheckedThunkBuilder(
    _ base: BoundsCheckedThunkBuilder, _ funcDecl: FunctionDeclSyntax,
    _ skipTrivialCount: Bool
  ) -> BoundsCheckedThunkBuilder
}

func tryGetParamName(_ funcDecl: FunctionDeclSyntax, _ expr: SwiftifyExpr) -> TokenSyntax? {
  switch expr {
  case .param(let i):
    let funcParam = getParam(funcDecl, i - 1)
    return funcParam.secondName ?? funcParam.firstName
  case .`self`:
    return .keyword(.self)
  default: return nil
  }
}

func getSwiftifyExprType(_ funcDecl: FunctionDeclSyntax, _ expr: SwiftifyExpr) -> TypeSyntax {
  switch expr {
  case .param(let i):
    let funcParam = getParam(funcDecl, i - 1)
    return funcParam.type
  case .return:
    return funcDecl.signature.returnClause!.type
  case .self:
    return TypeSyntax(IdentifierTypeSyntax(name: TokenSyntax("Self")))
  }
}

struct CxxSpan: ParamInfo {
  var pointerIndex: SwiftifyExpr
  var nonescaping: Bool
  var dependencies: [LifetimeDependence]
  var typeMappings: [String: String]
  var original: SyntaxProtocol

  var description: String {
    return "std::span(pointer: \(pointerIndex), nonescaping: \(nonescaping))"
  }

  func getBoundsCheckedThunkBuilder(
    _ base: BoundsCheckedThunkBuilder, _ funcDecl: FunctionDeclSyntax,
    _ skipTrivialCount: Bool
  ) -> BoundsCheckedThunkBuilder {
    switch pointerIndex {
    case .param(let i):
      return CxxSpanThunkBuilder(base: base, index: i - 1, signature: funcDecl.signature,
        typeMappings: typeMappings, node: original, nonescaping: nonescaping)
    case .return:
      if dependencies.isEmpty {
        return base
      }
      return CxxSpanReturnThunkBuilder(base: base, signature: funcDecl.signature,
        typeMappings: typeMappings, node: original)
    case .self:
      return base
    }
  }
}

struct CountedBy: ParamInfo {
  var pointerIndex: SwiftifyExpr
  var count: ExprSyntax
  var sizedBy: Bool
  var nonescaping: Bool
  var dependencies: [LifetimeDependence]
  var original: SyntaxProtocol

  var description: String {
    if sizedBy {
      return ".sizedBy(pointer: \(pointerIndex), size: \"\(count)\", nonescaping: \(nonescaping))"
    }
    return ".countedBy(pointer: \(pointerIndex), count: \"\(count)\", nonescaping: \(nonescaping))"
  }

  func getBoundsCheckedThunkBuilder(
    _ base: BoundsCheckedThunkBuilder, _ funcDecl: FunctionDeclSyntax,
    _ skipTrivialCount: Bool
  ) -> BoundsCheckedThunkBuilder {
    switch pointerIndex {
    case .param(let i):
      return CountedOrSizedPointerThunkBuilder(
        base: base, index: i-1, countExpr: count,
        signature: funcDecl.signature,
        nonescaping: nonescaping, isSizedBy: sizedBy, skipTrivialCount: skipTrivialCount)
    case .return:
      return CountedOrSizedReturnPointerThunkBuilder(
        base: base, countExpr: count,
        signature: funcDecl.signature,
        nonescaping: nonescaping, isSizedBy: sizedBy, dependencies: dependencies)
    case .self:
      return base
    }
  }
}

struct RuntimeError: Error {
  let description: String

  init(_ description: String) {
    self.description = description
  }

  var errorDescription: String? {
    description
  }
}

struct DiagnosticError: Error {
  let description: String
  let node: SyntaxProtocol
  let notes: [Note]

  init(_ description: String, node: SyntaxProtocol, notes: [Note] = []) {
    self.description = description
    self.node = node
    self.notes = notes
  }

  var errorDescription: String? {
    description
  }
}

enum Mutability {
  case Immutable
  case Mutable
}

func getUnattributedType(_ type: TypeSyntax) -> TypeSyntax {
  if let attributedType = type.as(AttributedTypeSyntax.self) {
    return attributedType.baseType.trimmed
  }
  return type.trimmed
}

func getTypeName(_ type: TypeSyntax) throws -> TokenSyntax {
  switch type.kind {
  case .memberType:
    let memberType = type.as(MemberTypeSyntax.self)!
    if !memberType.baseType.isSwiftCoreModule {
      throw DiagnosticError(
        "expected pointer type in Swift core module, got type \(type) with base type \(memberType.baseType)",
        node: type)
    }
    return memberType.name
  case .identifierType:
    return type.as(IdentifierTypeSyntax.self)!.name
  case .attributedType:
    return try getTypeName(type.as(AttributedTypeSyntax.self)!.baseType)
  default:
    throw DiagnosticError("expected pointer type, got \(type) with kind \(type.kind)", node: type)
  }
}

func replaceTypeName(_ type: TypeSyntax, _ name: TokenSyntax) throws -> TypeSyntax {
  if let memberType = type.as(MemberTypeSyntax.self) {
    return TypeSyntax(memberType.with(\.name, name))
  }
  guard let idType = type.as(IdentifierTypeSyntax.self) else {
    throw DiagnosticError("unexpected type \(type) with kind \(type.kind)", node: type)
  }
  return TypeSyntax(idType.with(\.name, name))
}

func replaceBaseType(_ type: TypeSyntax, _ base: TypeSyntax) -> TypeSyntax {
  if let attributedType = type.as(AttributedTypeSyntax.self) {
    return TypeSyntax(attributedType.with(\.baseType, base))
  }
  return base
}

// C++ type qualifiers, `const T` and `volatile T`, are encoded as fake generic
// types, `__cxxConst<T>` and `__cxxVolatile<T>` respectively. Remove those.
func dropQualifierGenerics(_ type: TypeSyntax) -> TypeSyntax {
  guard let identifier = type.as(IdentifierTypeSyntax.self) else { return type }
  guard let generic = identifier.genericArgumentClause else { return type }
  guard let genericArg = generic.arguments.first else { return type }
  guard case .type(let argType) = genericArg.argument else { return type }
  switch identifier.name.text {
  case "__cxxConst", "__cxxVolatile":
    return dropQualifierGenerics(argType)
  default:
    return type
  }
}

// The generated type names for template instantiations sometimes contain
// encoded qualifiers for disambiguation purposes. We need to remove those.
func dropCxxQualifiers(_ type: TypeSyntax) -> TypeSyntax {
  if let attributed = type.as(AttributedTypeSyntax.self) {
    return dropCxxQualifiers(attributed.baseType)
  }
  return dropQualifierGenerics(type)
}

func getPointerMutability(text: String) -> Mutability? {
  switch text {
  case "UnsafePointer": return .Immutable
  case "UnsafeMutablePointer": return .Mutable
  case "UnsafeRawPointer": return .Immutable
  case "UnsafeMutableRawPointer": return .Mutable
  case "OpaquePointer": return .Immutable
  default:
    return nil
  }
}

func isRawPointerType(text: String) -> Bool {
  switch text {
  case "UnsafeRawPointer": return true
  case "UnsafeMutableRawPointer": return true
  case "OpaquePointer": return true
  default:
    return false
  }
}

// Remove std. or std.__1. prefix
func getUnqualifiedStdName(_ type: String) -> String? {
  if (type.hasPrefix("std.")) {
    var ty = type.dropFirst(4)
    if (ty.hasPrefix("__1.")) {
      ty = ty.dropFirst(4)
    }
    return String(ty)
  }
  return nil
}

func getSafePointerName(mut: Mutability, generateSpan: Bool, isRaw: Bool) -> TokenSyntax {
  switch (mut, generateSpan, isRaw) {
  case (.Immutable, true, true): return "RawSpan"
  case (.Mutable, true, true): return "MutableRawSpan"
  case (.Immutable, false, true): return "UnsafeRawBufferPointer"
  case (.Mutable, false, true): return "UnsafeMutableRawBufferPointer"

  case (.Immutable, true, false): return "Span"
  case (.Mutable, true, false): return "MutableSpan"
  case (.Immutable, false, false): return "UnsafeBufferPointer"
  case (.Mutable, false, false): return "UnsafeMutableBufferPointer"
  }
}

func transformType(_ prev: TypeSyntax, _ generateSpan: Bool, _ isSizedBy: Bool) throws -> TypeSyntax {
  if let optType = prev.as(OptionalTypeSyntax.self) {
    return TypeSyntax(
      optType.with(\.wrappedType, try transformType(optType.wrappedType, generateSpan, isSizedBy)))
  }
  if let impOptType = prev.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
    return try transformType(impOptType.wrappedType, generateSpan, isSizedBy)
  }
  if let attrType = prev.as(AttributedTypeSyntax.self) {
    return TypeSyntax(
      attrType.with(\.baseType, try transformType(attrType.baseType, generateSpan, isSizedBy)))
  }
  let name = try getTypeName(prev)
  let text = name.text
  let isRaw = isRawPointerType(text: text)
  if isRaw && !isSizedBy {
    throw DiagnosticError("raw pointers only supported for SizedBy", node: name)
  }
  if !isRaw && isSizedBy {
    throw DiagnosticError("SizedBy only supported for raw pointers", node: name)
  }

  guard let kind: Mutability = getPointerMutability(text: text) else {
    throw DiagnosticError(
      "expected Unsafe[Mutable][Raw]Pointer type for type \(prev)"
        + " - first type token is '\(text)'", node: name)
  }
  let token = getSafePointerName(mut: kind, generateSpan: generateSpan, isRaw: isSizedBy)
  if isSizedBy {
    return TypeSyntax(IdentifierTypeSyntax(name: token))
  }
  return try replaceTypeName(prev, token)
}

protocol BoundsCheckedThunkBuilder {
  func buildFunctionCall(_ pointerArgs: [Int: ExprSyntax]) throws -> ExprSyntax
  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item]
  // The second component of the return value is true when only the return type of the
  // function signature was changed.
  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool)
}

func getParam(_ signature: FunctionSignatureSyntax, _ paramIndex: Int) -> FunctionParameterSyntax {
  let params = signature.parameterClause.parameters
  if paramIndex > 0 {
    return params[params.index(params.startIndex, offsetBy: paramIndex)]
  } else {
    return params[params.startIndex]
  }
}

func getParam(_ funcDecl: FunctionDeclSyntax, _ paramIndex: Int) -> FunctionParameterSyntax {
  return getParam(funcDecl.signature, paramIndex)
}

struct FunctionCallBuilder: BoundsCheckedThunkBuilder {
  let base: FunctionDeclSyntax

  init(_ function: FunctionDeclSyntax) {
    base = function
  }

  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item] {
    return []
  }

  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool) {
    var newParams = base.signature.parameterClause.parameters.enumerated().filter {
      let type = argTypes[$0.offset]
      // filter out deleted parameters, i.e. ones where argTypes[i] _contains_ nil
      return type == nil || type! != nil
    }.map { (i: Int, e: FunctionParameterSyntax) in
      e.with(\.type, (argTypes[i] ?? e.type)!)
    }
    if let last = newParams.popLast() {
      newParams.append(last.with(\.trailingComma, nil))
    }

    var sig = base.signature.with(\.parameterClause.parameters, FunctionParameterListSyntax(newParams))
    if returnType != nil {
      sig = sig.with(\.returnClause!.type, returnType!)
    }
    return (sig, (argTypes.count == 0 && returnType != nil))
  }

  func buildFunctionCall(_ pointerArgs: [Int: ExprSyntax]) throws -> ExprSyntax {
    let functionRef = DeclReferenceExprSyntax(baseName: base.name)
    let args: [ExprSyntax] = base.signature.parameterClause.parameters.enumerated()
      .map { (i: Int, param: FunctionParameterSyntax) in
        let name = param.secondName ?? param.firstName
        let declref = DeclReferenceExprSyntax(baseName: name)
        return pointerArgs[i] ?? ExprSyntax(declref)
      }
    let labels: [TokenSyntax?] = base.signature.parameterClause.parameters.map { param in
      let firstName = param.firstName.trimmed
      if firstName.text == "_" {
        return nil
      }
      return firstName
    }
    let labeledArgs: [LabeledExprSyntax] = zip(labels, args).enumerated().map { (i, e) in
      let (label, arg) = e
      var comma: TokenSyntax? = nil
      if i < args.count - 1 {
        comma = .commaToken()
      }
      let colon: TokenSyntax? = label != nil ? .colonToken() : nil
      return LabeledExprSyntax(label: label, colon: colon, expression: arg, trailingComma: comma)
    }
    return ExprSyntax(
      FunctionCallExprSyntax(
        calledExpression: functionRef, leftParen: .leftParenToken(),
        arguments: LabeledExprListSyntax(labeledArgs), rightParen: .rightParenToken()))
  }
}

struct CxxSpanThunkBuilder: ParamPointerBoundsThunkBuilder {
  public let base: BoundsCheckedThunkBuilder
  public let index: Int
  public let signature: FunctionSignatureSyntax
  public let typeMappings: [String: String]
  public let node: SyntaxProtocol
  public let nonescaping: Bool
  let isSizedBy: Bool = false

  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item] {
    return try base.buildBoundsChecks()
  }

  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool) {
    var types = argTypes
    let typeName = getUnattributedType(oldType).description
    guard let desugaredType = typeMappings[typeName] else {
      throw DiagnosticError(
        "unable to desugar type with name '\(typeName)'", node: node)
    }

    let parsedDesugaredType = TypeSyntax("\(raw: getUnqualifiedStdName(desugaredType)!)")
    let genericArg = TypeSyntax(parsedDesugaredType.as(IdentifierTypeSyntax.self)!
      .genericArgumentClause!.arguments.first!.argument)!
    types[index] = replaceBaseType(param.type,
      TypeSyntax("Span<\(raw: dropCxxQualifiers(genericArg))>"))
    return try base.buildFunctionSignature(types, returnType)
  }

  func buildFunctionCall(_ pointerArgs: [Int: ExprSyntax]) throws -> ExprSyntax {
    var args = pointerArgs
    let typeName = getUnattributedType(oldType).description
    assert(args[index] == nil)
    args[index] = ExprSyntax("\(raw: typeName)(\(raw: name))")
    return try base.buildFunctionCall(args)
  }
}

struct CxxSpanReturnThunkBuilder: BoundsCheckedThunkBuilder {
  public let base: BoundsCheckedThunkBuilder
  public let signature: FunctionSignatureSyntax
  public let typeMappings: [String: String]
  public let node: SyntaxProtocol

  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item] {
    return try base.buildBoundsChecks()
  }

  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool) {
    assert(returnType == nil)
    let typeName = getUnattributedType(signature.returnClause!.type).description
    guard let desugaredType = typeMappings[typeName] else {
      throw DiagnosticError(
        "unable to desugar type with name '\(typeName)'", node: node)
    }
    let parsedDesugaredType = TypeSyntax("\(raw: getUnqualifiedStdName(desugaredType)!)")
    let genericArg = TypeSyntax(parsedDesugaredType.as(IdentifierTypeSyntax.self)!
      .genericArgumentClause!.arguments.first!.argument)!
    let newType = replaceBaseType(signature.returnClause!.type,
      TypeSyntax("Span<\(raw: dropCxxQualifiers(genericArg))>"))
    return try base.buildFunctionSignature(argTypes, newType)
  }

  func buildFunctionCall(_ pointerArgs: [Int: ExprSyntax]) throws -> ExprSyntax {
    let call = try base.buildFunctionCall(pointerArgs)
    return "_cxxOverrideLifetime(Span(_unsafeCxxSpan: \(call)), copying: ())"
  }
}

protocol PointerBoundsThunkBuilder: BoundsCheckedThunkBuilder {
  var oldType: TypeSyntax { get }
  var newType: TypeSyntax { get throws }
  var nullable: Bool { get }
  var signature: FunctionSignatureSyntax { get }
  var nonescaping: Bool { get }
  var isSizedBy: Bool { get }
  var generateSpan: Bool { get }
}

extension PointerBoundsThunkBuilder {
  var nullable: Bool { return oldType.is(OptionalTypeSyntax.self) }

  var newType: TypeSyntax { get throws {
    return try transformType(oldType, generateSpan, isSizedBy) }
  }
}

protocol ParamPointerBoundsThunkBuilder: PointerBoundsThunkBuilder {
  var index: Int { get }
}

extension ParamPointerBoundsThunkBuilder {
  var generateSpan: Bool { nonescaping }

  var param: FunctionParameterSyntax {
    return getParam(signature, index)
  }

  var oldType: TypeSyntax {
    return param.type
  }

  var name: TokenSyntax {
    return param.secondName ?? param.firstName
  }
}

struct CountedOrSizedReturnPointerThunkBuilder: PointerBoundsThunkBuilder {
  public let base: BoundsCheckedThunkBuilder
  public let countExpr: ExprSyntax
  public let signature: FunctionSignatureSyntax
  public let nonescaping: Bool
  public let isSizedBy: Bool
  public let dependencies: [LifetimeDependence]

  var generateSpan: Bool { !dependencies.isEmpty }

  var oldType: TypeSyntax {
    return signature.returnClause!.type
  }

  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool) {
    assert(returnType == nil)
    return try base.buildFunctionSignature(argTypes, newType)
  }

  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item] {
    return []
  }

  func buildFunctionCall(_ pointerArgs: [Int: ExprSyntax]) throws -> ExprSyntax {
    let call = try base.buildFunctionCall(pointerArgs)
    let startLabel = if generateSpan {
      "_unsafeStart"
    } else {
      "start"
    }
    return
      """
      \(raw: try newType)(\(raw: startLabel): \(call), count: Int(\(countExpr)))
      """
  }
}

struct CountedOrSizedPointerThunkBuilder: ParamPointerBoundsThunkBuilder {
  public let base: BoundsCheckedThunkBuilder
  public let index: Int
  public let countExpr: ExprSyntax
  public let signature: FunctionSignatureSyntax
  public let nonescaping: Bool
  public let isSizedBy: Bool
  public let skipTrivialCount: Bool

  func buildFunctionSignature(_ argTypes: [Int: TypeSyntax?], _ returnType: TypeSyntax?) throws
    -> (FunctionSignatureSyntax, Bool) {
    var types = argTypes
    types[index] = try newType
    if skipTrivialCount {
      if let countVar = countExpr.as(DeclReferenceExprSyntax.self) {
        let i = try getParameterIndexForDeclRef(signature.parameterClause.parameters, countVar)
        types[i] = nil as TypeSyntax?
      }
    }
    return try base.buildFunctionSignature(types, returnType)
  }

  func buildBoundsChecks() throws -> [CodeBlockItemSyntax.Item] {
    var res = try base.buildBoundsChecks()
    let countName: TokenSyntax = "_\(raw: name)Count"
    let count: VariableDeclSyntax = try VariableDeclSyntax(
      "let \(countName): some BinaryInteger = \(countExpr)")
    res.append(CodeBlockItemSyntax.Item(count))

    let countCheck = ExprSyntax(
      """
        if \(getCount()) < \(countName) || \(countName) < 0 {
          fatalError("bounds check failure when calling unsafe function")
        }
      """)
    res.append(CodeBlockItemSyntax.Item(countCheck))
    return res
  }

  func unwrapIfNullable(_ expr: ExprSyntax) -> ExprSyntax {
    if nullable {
      return ExprSyntax(ForceUnwrapExprSyntax(expression: expr))
    }
    return expr
  }

  func unwrapIfNonnullable(_ expr: ExprSyntax) -> ExprSyntax {
    if !nullable {
      return ExprSyntax(ForceUnwrapExprSyntax(expression: expr))
    }
    return expr
  }

  func castIntToTargetType(expr: ExprSyntax, type: TypeSyntax) -> ExprSyntax {
    if type.canRepresentBasicType(type: Int.self) {
      return expr
    }
    return ExprSyntax("\(type)(exactly: \(expr))!")
  }

  func buildUnwrapCall(_ argOverrides: [Int: ExprSyntax]) throws -> ExprSyntax {
    let unwrappedName = TokenSyntax("_\(name)Ptr")
    var args = argOverrides
    let argExpr = ExprSyntax("\(unwrappedName).baseAddress")
    assert(args[index] == nil)
    args[index] = try castPointerToOpaquePointer(unwrapIfNonnullable(argExpr))
    let call = try base.buildFunctionCall(args)
    let ptrRef = unwrapIfNullable(ExprSyntax(DeclReferenceExprSyntax(baseName: name)))

    let funcName = isSizedBy ? "withUnsafeBytes" : "withUnsafeBufferPointer"
    let unwrappedCall = ExprSyntax(
      """
        \(ptrRef).\(raw: funcName) { \(unwrappedName) in
          return unsafe \(call)
        }
      """)
    return unwrappedCall
  }

  func getCount() -> ExprSyntax {
    let countName = isSizedBy && generateSpan ? "byteCount" : "count"
    if nullable {
      return ExprSyntax("\(name)?.\(raw: countName) ?? 0")
    }
    return ExprSyntax("\(name).\(raw: countName)")
  }

  func peelOptionalType(_ type: TypeSyntax) -> TypeSyntax {
    if let optType = type.as(OptionalTypeSyntax.self) {
      return optType.wrappedType
    }
    if let impOptType = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
      return impOptType.wrappedType
    }
    return type
  }

  func castPointerToOpaquePointer(_ baseAddress: ExprSyntax) throws -> ExprSyntax {
    let i = try getParameterIndexForParamName(signature.parameterClause.parameters, name)
    let type = peelOptionalType(getParam(signature, i).type)
    if type.canRepresentBasicType(type: OpaquePointer.self) {
      return ExprSyntax("OpaquePointer(\(baseAddress))")
    }
    return baseAddress
  }

  func getPointerArg() throws -> ExprSyntax {
    if nullable {
      return ExprSyntax("\(name)?.baseAddress")
    }
    return ExprSyntax("\(name).baseAddress!")
  }

  func buildFunctionCall(_ argOverrides: [Int: ExprSyntax]) throws -> ExprSyntax {
    var args = argOverrides
    if skipTrivialCount {
      assert(
        countExpr.is(DeclReferenceExprSyntax.self) || countExpr.is(IntegerLiteralExprSyntax.self))
      if let countVar = countExpr.as(DeclReferenceExprSyntax.self) {
        let i = try getParameterIndexForDeclRef(signature.parameterClause.parameters, countVar)
        assert(args[i] == nil)
        args[i] = castIntToTargetType(expr: getCount(), type: getParam(signature, i).type)
      }
    }
    assert(args[index] == nil)
    if generateSpan {
      assert(nonescaping)
      let unwrappedCall = try buildUnwrapCall(args)
      if nullable {
        var nullArgs = args
        nullArgs[index] = ExprSyntax(NilLiteralExprSyntax(nilKeyword: .keyword(.nil)))
        return ExprSyntax(
          """
            if \(name) == nil {
              unsafe \(try base.buildFunctionCall(nullArgs))
            } else {
              \(unwrappedCall)
            }
          """)
      }
      return unwrappedCall
    }

    args[index] = try castPointerToOpaquePointer(getPointerArg())
    return try base.buildFunctionCall(args)
  }
}

func getArgumentByName(_ argumentList: LabeledExprListSyntax, _ name: String) throws -> ExprSyntax {
  guard
    let arg = argumentList.first(where: {
      return $0.label?.text == name
    })
  else {
    throw DiagnosticError(
      "no argument with name '\(name)' in '\(argumentList)'", node: argumentList)
  }
  return arg.expression
}

func getOptionalArgumentByName(_ argumentList: LabeledExprListSyntax, _ name: String) -> ExprSyntax?
{
  return argumentList.first(where: {
    $0.label?.text == name
  })?.expression
}

func getParameterIndexForParamName(
  _ parameterList: FunctionParameterListSyntax, _ tok: TokenSyntax
) throws -> Int {
  let name = tok.text
  guard
    let index = parameterList.enumerated().first(where: {
      (_: Int, param: FunctionParameterSyntax) in
      let paramenterName = param.secondName ?? param.firstName
      return paramenterName.trimmed.text == name
    })?.offset
  else {
    throw DiagnosticError("no parameter with name '\(name)' in '\(parameterList)'", node: tok)
  }
  return index
}

func getParameterIndexForDeclRef(
  _ parameterList: FunctionParameterListSyntax, _ ref: DeclReferenceExprSyntax
) throws -> Int {
  return try getParameterIndexForParamName((parameterList), ref.baseName)
}

/// A macro that adds safe(r) wrappers for functions with unsafe pointer types.
/// Depends on bounds, escapability and lifetime information for each pointer.
/// Intended to map to C attributes like __counted_by, __ended_by and __no_escape,
/// for automatic application by ClangImporter when the C declaration is annotated
/// appropriately. Moreover, it can wrap C++ APIs using unsafe C++ types like
/// std::span with APIs that use their safer Swift equivalents.
public struct SwiftifyImportMacro: PeerMacro {
  static func parseEnumName(_ expr: ExprSyntax) throws -> String {
    var exprLocal = expr
    if let callExpr = expr.as(FunctionCallExprSyntax.self) {
      exprLocal = callExpr.calledExpression
    }
    guard let dotExpr = exprLocal.as(MemberAccessExprSyntax.self)
    else {
      throw DiagnosticError(
        "expected enum literal as argument, got '\(expr)'",
        node: expr)
    }
    return dotExpr.declName.baseName.text
  }

  static func parseEnumArgs(_ expr: ExprSyntax) throws -> LabeledExprListSyntax {
    guard let callExpr = expr.as(FunctionCallExprSyntax.self)
    else {
      throw DiagnosticError(
        "expected call to enum constructor, got '\(expr)'",
        node: expr)
    }
    return callExpr.arguments
  }

  static func getIntLiteralValue(_ expr: ExprSyntax) throws -> Int {
    guard let intLiteral = expr.as(IntegerLiteralExprSyntax.self) else {
      throw DiagnosticError("expected integer literal, got '\(expr)'", node: expr)
    }
    guard let res = intLiteral.representedLiteralValue else {
      throw DiagnosticError("expected integer literal, got '\(expr)'", node: expr)
    }
    return res
  }

  static func getBoolLiteralValue(_ expr: ExprSyntax) throws -> Bool {
    guard let boolLiteral = expr.as(BooleanLiteralExprSyntax.self) else {
      throw DiagnosticError("expected boolean literal, got '\(expr)'", node: expr)
    }
    switch boolLiteral.literal.tokenKind {
    case .keyword(.true):
      return true
    case .keyword(.false):
      return false
    default:
      throw DiagnosticError("expected bool literal, got '\(expr)'", node: expr)
    }
  }

  static func parseSwiftifyExpr(_ expr: ExprSyntax) throws -> SwiftifyExpr {
    let enumName = try parseEnumName(expr)
    switch enumName {
    case "param":
      let argumentList = try parseEnumArgs(expr)
      if argumentList.count != 1 {
        throw DiagnosticError(
          "expected single argument to _SwiftifyExpr.param, got \(argumentList.count) arguments",
          node: expr)
      }
      let pointerParamIndexArg = argumentList[argumentList.startIndex]
      let pointerParamIndex: Int = try getIntLiteralValue(pointerParamIndexArg.expression)
      return .param(pointerParamIndex)
    case "return": return .return
    case "self": return .`self`
    default:
      throw DiagnosticError(
        "expected 'param', 'return', or 'self', got '\(enumName)'",
        node: expr)
    }
  }

  static func parseCountedByEnum(
    _ enumConstructorExpr: FunctionCallExprSyntax, _ signature: FunctionSignatureSyntax
  ) throws -> ParamInfo {
    let argumentList = enumConstructorExpr.arguments
    let pointerExprArg = try getArgumentByName(argumentList, "pointer")
    let pointerExpr: SwiftifyExpr = try parseSwiftifyExpr(pointerExprArg)
    let countExprArg = try getArgumentByName(argumentList, "count")
    guard let countExprStringLit = countExprArg.as(StringLiteralExprSyntax.self) else {
      throw DiagnosticError(
        "expected string literal for 'count' parameter, got \(countExprArg)", node: countExprArg)
    }
    let unwrappedCountExpr = ExprSyntax(stringLiteral: countExprStringLit.representedLiteralValue!)
    if let countVar = unwrappedCountExpr.as(DeclReferenceExprSyntax.self) {
      // Perform this lookup here so we can override the position to point to the string literal
      // instead of line 1, column 1
      do {
        _ = try getParameterIndexForDeclRef(signature.parameterClause.parameters, countVar)
      } catch let error as DiagnosticError {
        throw DiagnosticError(error.description, node: countExprStringLit, notes: error.notes)
      }
    }
    return CountedBy(
      pointerIndex: pointerExpr, count: unwrappedCountExpr, sizedBy: false,
      nonescaping: false, dependencies: [], original: ExprSyntax(enumConstructorExpr))
  }

  static func parseSizedByEnum(_ enumConstructorExpr: FunctionCallExprSyntax) throws -> ParamInfo {
    let argumentList = enumConstructorExpr.arguments
    let pointerExprArg = try getArgumentByName(argumentList, "pointer")
    let pointerExpr: SwiftifyExpr = try parseSwiftifyExpr(pointerExprArg)
    let sizeExprArg = try getArgumentByName(argumentList, "size")
    guard let sizeExprStringLit = sizeExprArg.as(StringLiteralExprSyntax.self) else {
      throw DiagnosticError(
        "expected string literal for 'size' parameter, got \(sizeExprArg)", node: sizeExprArg)
    }
    let unwrappedCountExpr = ExprSyntax(stringLiteral: sizeExprStringLit.representedLiteralValue!)
    return CountedBy(
      pointerIndex: pointerExpr, count: unwrappedCountExpr, sizedBy: true, nonescaping: false,
      dependencies: [], original: ExprSyntax(enumConstructorExpr))
  }

  static func parseEndedByEnum(_ enumConstructorExpr: FunctionCallExprSyntax) throws -> ParamInfo {
    let argumentList = enumConstructorExpr.arguments
    let startPointerExprArg = try getArgumentByName(argumentList, "start")
    let _: SwiftifyExpr = try parseSwiftifyExpr(startPointerExprArg)
    let endPointerExprArg = try getArgumentByName(argumentList, "end")
    let _: SwiftifyExpr = try parseSwiftifyExpr(endPointerExprArg)
    throw RuntimeError("endedBy support not yet implemented")
  }

  static func parseNonEscaping(_ enumConstructorExpr: FunctionCallExprSyntax) throws -> Int {
    let argumentList = enumConstructorExpr.arguments
    let pointerExprArg = try getArgumentByName(argumentList, "pointer")
    let pointerExpr: SwiftifyExpr = try parseSwiftifyExpr(pointerExprArg)
    let pointerParamIndex: Int = paramOrReturnIndex(pointerExpr)
    return pointerParamIndex
  }

  static func parseLifetimeDependence(_ enumConstructorExpr: FunctionCallExprSyntax) throws -> (SwiftifyExpr, LifetimeDependence) {
    let argumentList = enumConstructorExpr.arguments
    let pointer: SwiftifyExpr = try parseSwiftifyExpr(try getArgumentByName(argumentList, "pointer"))
    let dependsOnArg = try getArgumentByName(argumentList, "dependsOn")
    let dependsOn: SwiftifyExpr = try parseSwiftifyExpr(dependsOnArg)
    if dependsOn == .`return` {
        throw DiagnosticError("lifetime cannot depend on the return value", node: dependsOnArg)
    }
    let type = try getArgumentByName(argumentList, "type") 
    let depType: DependenceType
    switch try parseEnumName(type) {
      case "borrow":
        depType = DependenceType.borrow
      case "copy":
        depType = DependenceType.copy
      default:
        throw DiagnosticError("expected '.copy' or '.borrow', got '\(type)'", node: type)
    }
    let dependence = LifetimeDependence(dependsOn: dependsOn, type: depType)
    return (pointer, dependence)
  }

  static func parseTypeMappingParam(_ paramAST: LabeledExprSyntax?) throws -> [String: String]? {
    guard let unwrappedParamAST = paramAST else {
      return nil
    }
    let paramExpr = unwrappedParamAST.expression
    guard let dictExpr = paramExpr.as(DictionaryExprSyntax.self) else {
      return nil
    }
    var dict : [String: String] = [:]
    switch dictExpr.content {
      case .colon(_):
        return dict
      case .elements(let types):
        for element in types {
          guard let key = element.key.as(StringLiteralExprSyntax.self) else {
            throw DiagnosticError("expected a string literal, got '\(element.key)'", node: element.key)
          }
          guard let value = element.value.as(StringLiteralExprSyntax.self) else {
            throw DiagnosticError("expected a string literal, got '\(element.value)'", node: element.value)
          }
          dict[key.representedLiteralValue!] = value.representedLiteralValue!
        }
      @unknown default:
        throw DiagnosticError("unknown dictionary literal", node: dictExpr)
    }
    return dict
  }

  static func parseCxxSpansInSignature(
    _ signature: FunctionSignatureSyntax,
    _ typeMappings: [String: String]?
  ) throws -> [ParamInfo] {
    guard let typeMappings else {
      return []
    }
    var result : [ParamInfo] = []
    let process : (TypeSyntax, SwiftifyExpr, SyntaxProtocol) throws -> () = { type, expr, orig in
      let typeName = getUnattributedType(type).description
      if let desugaredType = typeMappings[typeName] {
        if let unqualifiedDesugaredType = getUnqualifiedStdName(desugaredType) {
          if unqualifiedDesugaredType.starts(with: "span<") {
            result.append(CxxSpan(pointerIndex: expr, nonescaping: false,
              dependencies: [], typeMappings: typeMappings, original: orig))
          }
        }
      }
    }
    for (idx, param) in signature.parameterClause.parameters.enumerated() {
      try process(param.type, .param(idx + 1), param)
    }
    if let retClause = signature.returnClause {
      try process(retClause.type, .`return`, retClause)
    }
    return result
  }

  static func parseMacroParam(
    _ paramAST: LabeledExprSyntax, _ signature: FunctionSignatureSyntax,
    nonescapingPointers: inout Set<Int>,
    lifetimeDependencies: inout [SwiftifyExpr: [LifetimeDependence]]
  ) throws -> ParamInfo? {
    let paramExpr = paramAST.expression
    guard let enumConstructorExpr = paramExpr.as(FunctionCallExprSyntax.self) else {
      throw DiagnosticError(
        "expected _SwiftifyInfo enum literal as argument, got '\(paramExpr)'", node: paramExpr)
    }
    let enumName = try parseEnumName(paramExpr)
    switch enumName {
    case "countedBy": return try parseCountedByEnum(enumConstructorExpr, signature)
    case "sizedBy": return try parseSizedByEnum(enumConstructorExpr)
    case "endedBy": return try parseEndedByEnum(enumConstructorExpr)
    case "nonescaping":
      let index = try parseNonEscaping(enumConstructorExpr)
      nonescapingPointers.insert(index)
      return nil
    case "lifetimeDependence":
      let (expr, dependence) = try parseLifetimeDependence(enumConstructorExpr)
      lifetimeDependencies[expr, default: []].append(dependence)
      // We assume pointers annotated with lifetimebound do not escape.
      let fromIdx = paramOrReturnIndex(dependence.dependsOn)
      if dependence.type == DependenceType.copy && fromIdx != 0 {
        nonescapingPointers.insert(fromIdx)
      }
      // The escaping is controlled when a parameter is the target of a lifetimebound.
      // So we want to do the transformation to Swift's Span.
      let idx = paramOrReturnIndex(expr)
      if idx != -1 {
        nonescapingPointers.insert(idx)
      }
      return nil
    default:
      throw DiagnosticError(
        "expected 'countedBy', 'sizedBy', 'endedBy', 'nonescaping' or 'lifetimeDependence', got '\(enumName)'",
        node: enumConstructorExpr)
    }
  }

  static func hasTrivialCountVariants(_ parsedArgs: [ParamInfo]) -> Bool {
    let countExprs = parsedArgs.compactMap {
      switch $0 {
      case let c as CountedBy: return c.count
      default: return nil
      }
    }
    let trivialCounts = countExprs.filter {
      $0.is(DeclReferenceExprSyntax.self) || $0.is(IntegerLiteralExprSyntax.self)
    }
    // don't generate trivial count variants if there are any non-trivial counts
    if trivialCounts.count < countExprs.count {
      return false
    }
    let countVars = trivialCounts.filter { $0.is(DeclReferenceExprSyntax.self) }
    let distinctCountVars = Set(
      countVars.map {
        return $0.as(DeclReferenceExprSyntax.self)!.baseName.text
      })
    // don't generate trivial count variants if two count expressions refer to the same parameter
    return countVars.count == distinctCountVars.count
  }

  static func checkArgs(_ args: [ParamInfo], _ funcDecl: FunctionDeclSyntax) throws {
    var argByIndex: [Int: ParamInfo] = [:]
    var ret: ParamInfo? = nil
    let paramCount = funcDecl.signature.parameterClause.parameters.count
    try args.forEach { pointerInfo in
      switch pointerInfo.pointerIndex {
      case .param(let i):
      if i < 1 || i > paramCount {
        let noteMessage =
          paramCount > 0
          ? "function \(funcDecl.name) has parameter indices 1..\(paramCount)"
          : "function \(funcDecl.name) has no parameters"
        throw DiagnosticError(
          "pointer index out of bounds", node: pointerInfo.original,
          notes: [
            Note(node: Syntax(funcDecl.name), message: MacroExpansionNoteMessage(noteMessage))
          ])
      }
      if argByIndex[i] != nil {
        throw DiagnosticError(
          "multiple _SwiftifyInfos referring to parameter with index "
            + "\(i): \(pointerInfo) and \(argByIndex[i]!)", node: pointerInfo.original)
      }
      argByIndex[i] = pointerInfo
      case .return:
      if ret != nil {
        throw DiagnosticError(
          "multiple _SwiftifyInfos referring to return value: \(pointerInfo) and \(ret!)", node: pointerInfo.original)
      }
      ret = pointerInfo
      case .self:
        throw DiagnosticError("do not annotate self", node: pointerInfo.original)
      }
    }
  }

  static func paramOrReturnIndex(_ expr: SwiftifyExpr) -> Int {
    switch expr {
    case .param(let i): return i
    case .`self`: return 0
    case .return: return -1
    }
  }

  static func setNonescapingPointers(_ args: inout [ParamInfo], _ nonescapingPointers: Set<Int>) {
    if args.isEmpty {
      return
    }
    for i in 0...args.count - 1 where nonescapingPointers.contains(paramOrReturnIndex(args[i].pointerIndex)) {
      args[i].nonescaping = true
    }
  }

  static func setLifetimeDependencies(_ args: inout [ParamInfo], _ lifetimeDependencies: [SwiftifyExpr: [LifetimeDependence]]) {
    if args.isEmpty {
      return
    }
    for i in 0...args.count - 1 where lifetimeDependencies.keys.contains(args[i].pointerIndex) {
      args[i].dependencies = lifetimeDependencies[args[i].pointerIndex]!
    }
  }

  static func lifetimeAttributes(_ funcDecl: FunctionDeclSyntax,
    _ dependencies: [SwiftifyExpr: [LifetimeDependence]]) -> [AttributeListSyntax.Element] {
    let returnDependencies = dependencies[.`return`, default: []]
    if returnDependencies.isEmpty {
      return []
    }
    var args : [LabeledExprSyntax] = []
    for dependence in returnDependencies {
      switch dependence.type {
      case .borrow:
        args.append(LabeledExprSyntax(expression: 
                                        DeclReferenceExprSyntax(baseName: TokenSyntax("borrow"))))
      case .copy:
        args.append(LabeledExprSyntax(expression:
                                        DeclReferenceExprSyntax(baseName: TokenSyntax("copy"))))
      }
      args.append(LabeledExprSyntax(expression: 
        DeclReferenceExprSyntax(baseName: TokenSyntax(tryGetParamName(funcDecl, dependence.dependsOn))!),
        trailingComma: .commaToken()))
    }
    args[args.count - 1] = args[args.count - 1].with(\.trailingComma, nil)
    return [.attribute(AttributeSyntax(
              atSign: .atSignToken(),
              attributeName: IdentifierTypeSyntax(name: "lifetime"),
              leftParen: .leftParenToken(),
              arguments: .argumentList(LabeledExprListSyntax(args)),
              rightParen: .rightParenToken()))]
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    do {
      guard let funcDecl = declaration.as(FunctionDeclSyntax.self) else {
        throw DiagnosticError("@_SwiftifyImport only works on functions", node: declaration)
      }

      let argumentList = node.arguments!.as(LabeledExprListSyntax.self)!
      var arguments = Array<LabeledExprSyntax>(argumentList)
      let typeMappings = try parseTypeMappingParam(arguments.last)
      if typeMappings != nil {
        arguments = arguments.dropLast()
      }
      var nonescapingPointers = Set<Int>()
      var lifetimeDependencies : [SwiftifyExpr: [LifetimeDependence]] = [:]
      var parsedArgs = try arguments.compactMap {
        try parseMacroParam($0, funcDecl.signature, nonescapingPointers: &nonescapingPointers,
          lifetimeDependencies: &lifetimeDependencies)
      }
      parsedArgs.append(contentsOf: try parseCxxSpansInSignature(funcDecl.signature, typeMappings))
      setNonescapingPointers(&parsedArgs, nonescapingPointers)
      setLifetimeDependencies(&parsedArgs, lifetimeDependencies)
      // We only transform non-escaping spans.
      parsedArgs = parsedArgs.filter {
        if let cxxSpanArg = $0 as? CxxSpan {
          return cxxSpanArg.nonescaping || cxxSpanArg.pointerIndex == .return
        } else {
          return true
        }
      }
      try checkArgs(parsedArgs, funcDecl)
      parsedArgs.sort { a, b in
        // make sure return value cast to Span happens last so that withUnsafeBufferPointer
        // doesn't return a ~Escapable type
        if a.pointerIndex != .return && b.pointerIndex == .return {
          return true
        }
        if a.pointerIndex == .return && b.pointerIndex != .return {
          return false
        }
        return paramOrReturnIndex(a.pointerIndex) < paramOrReturnIndex(b.pointerIndex)
      }
      let baseBuilder = FunctionCallBuilder(funcDecl)

      let skipTrivialCount = hasTrivialCountVariants(parsedArgs)

      let builder: BoundsCheckedThunkBuilder = parsedArgs.reduce(
        baseBuilder,
        { (prev, parsedArg) in
          parsedArg.getBoundsCheckedThunkBuilder(prev, funcDecl, skipTrivialCount)
        })
      let (newSignature, onlyReturnTypeChanged) = try builder.buildFunctionSignature([:], nil)
      let checks =
        skipTrivialCount
        ? [] as [CodeBlockItemSyntax]
        : try builder.buildBoundsChecks().map { e in
          CodeBlockItemSyntax(leadingTrivia: "\n", item: e)
        }
      let call = CodeBlockItemSyntax(
        item: CodeBlockItemSyntax.Item(
          ReturnStmtSyntax(
            returnKeyword: .keyword(.return, trailingTrivia: " "),
            expression: ExprSyntax("unsafe \(try builder.buildFunctionCall([:]))"))))
      let body = CodeBlockSyntax(statements: CodeBlockItemListSyntax(checks + [call]))
      let lifetimeAttrs = lifetimeAttributes(funcDecl, lifetimeDependencies)
      let disfavoredOverload : [AttributeListSyntax.Element] = (onlyReturnTypeChanged ? [
        .attribute(
          AttributeSyntax(
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(name: "_disfavoredOverload")))
      ] : [])
      let newFunc =
        funcDecl
        .with(\.signature, newSignature)
        .with(\.body, body)
        .with(
          \.attributes,
          funcDecl.attributes.filter { e in
            switch e {
            case .attribute(let attr):
              // don't apply this macro recursively, and avoid dupe _alwaysEmitIntoClient
              let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text
              return name == nil || (name != "_SwiftifyImport" && name != "_alwaysEmitIntoClient")
            default: return true
            }
          } + [
            .attribute(
              AttributeSyntax(
                atSign: .atSignToken(),
                attributeName: IdentifierTypeSyntax(name: "_alwaysEmitIntoClient")))
          ]
          + lifetimeAttrs
          + disfavoredOverload)
      return [DeclSyntax(newFunc)]
    } catch let error as DiagnosticError {
      context.diagnose(
        Diagnostic(
          node: error.node, message: MacroExpansionErrorMessage(error.description),
          notes: error.notes))
      return []
    }
  }
}

// MARK: syntax utils
extension TypeSyntaxProtocol {
  public var isSwiftCoreModule: Bool {
    guard let identifierType = self.as(IdentifierTypeSyntax.self) else {
      return false
    }
    return identifierType.name.text == "Swift"
  }

  /// Check if this syntax could resolve to the type passed. Only supports types where the canonical type
  /// can be named using only IdentifierTypeSyntax and MemberTypeSyntax. A non-exhaustive list of unsupported
  /// types includes:
  /// * array types
  /// * function types
  /// * optional types
  /// * tuple types (including Void!)
  /// The type syntax is allowed to use any level of qualified name for the type, e.g. Swift.Int.self
  /// will match against both "Swift.Int" and "Int".
  ///
  /// - Parameter type: Type to check against. NB: if passing a type alias, the canonical type will be used.
  /// - Returns: true if `self` spells out some suffix of the fully qualified name of `type`, otherwise false
  public func canRepresentBasicType(type: Any.Type) -> Bool {
    let qualifiedTypeName = String(reflecting: type)
    var typeNames = qualifiedTypeName.split(separator: ".")
    var currType: TypeSyntaxProtocol = self

    while !typeNames.isEmpty {
      let typeName = typeNames.popLast()!
      if let identifierType = currType.as(IdentifierTypeSyntax.self) {
        // It doesn't matter whether this is the final element of typeNames, because we don't know
        // surrounding context - the Foo.Bar.Baz type can be referred to as `Baz` inside Foo.Bar
        return identifierType.name.text == typeName
      } else if let memberType = currType.as(MemberTypeSyntax.self) {
        if memberType.name.text != typeName {
          return false
        }
        currType = memberType.baseType
      } else {
        return false
      }
    }

    return false
  }
}
