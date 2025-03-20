//===-- Sema/AsyncCallerExecutionMigration.cpp ------------------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
///
/// \file
/// This file implements code migration support for the `AsyncCallerExecution`
/// feature.
///
//===----------------------------------------------------------------------===//

#include "AsyncCallerExecutionMigration.h"
#include "swift/AST/ASTContext.h"
#include "swift/AST/Decl.h"
#include "swift/AST/DiagnosticsSema.h"
#include "swift/AST/Expr.h"
#include "swift/AST/TypeRepr.h"
#include "swift/Basic/Assertions.h"
#include "swift/Basic/Feature.h"
#include "swift/Basic/TaggedUnion.h"
#include "llvm/ADT/PointerUnion.h"

using namespace swift;

namespace {
class AsyncCallerExecutionMigrationTarget {
  ASTContext &ctx;
  PointerUnion<ValueDecl *, AbstractClosureExpr *, FunctionTypeRepr *> node;
  TaggedUnion<ActorIsolation, FunctionTypeIsolation> isolation;

public:
  AsyncCallerExecutionMigrationTarget(ASTContext &ctx, ValueDecl *decl,
                                      ActorIsolation isolation)
      : ctx(ctx), node(decl), isolation(isolation) {}

  AsyncCallerExecutionMigrationTarget(ASTContext &ctx,
                                      AbstractClosureExpr *closure,
                                      ActorIsolation isolation)
      : ctx(ctx), node(closure), isolation(isolation) {}

  AsyncCallerExecutionMigrationTarget(ASTContext &ctx, FunctionTypeRepr *repr,
                                      FunctionTypeIsolation isolation)
      : ctx(ctx), node(repr), isolation(isolation) {}

  /// Warns that the behavior of nonisolated async functions will change under
  /// `AsyncCallerExecution` and suggests `@execution(concurrent)` to preserve
  /// the current behavior.
  void diagnose() const;
};
} // end anonymous namespace

void AsyncCallerExecutionMigrationTarget::diagnose() const {
  const auto feature = Feature::AsyncCallerExecution;

  ASSERT(node);
  ASSERT(ctx.LangOpts.getFeatureState(feature).isEnabledForAdoption());

  ValueDecl *decl = nullptr;
  ClosureExpr *closure = nullptr;
  FunctionTypeRepr *functionRepr = nullptr;

  if ((decl = node.dyn_cast<ValueDecl *>())) {
    // Diagnose only explicit nodes.
    if (decl->isImplicit()) {
      return;
    }

    // If the attribute cannot appear on this kind of declaration, we can't
    // diagnose it.
    if (!DeclAttribute::canAttributeAppearOnDecl(DeclAttrKind::Execution,
                                                 decl)) {
      return;
    }

    // For storage, make sure we have an explicit getter to diagnose.
    if (auto *storageDecl = dyn_cast<AbstractStorageDecl>(decl)) {
      if (!storageDecl->getParsedAccessor(AccessorKind::Get)) {
        return;
      }
    }
  } else if (auto *anyClosure = node.dyn_cast<AbstractClosureExpr *>()) {
    // Diagnose only explicit nodes.
    if (anyClosure->isImplicit()) {
      return;
    }

    // The only subclass that can be explicit is this one.
    closure = cast<ClosureExpr>(anyClosure);
  } else {
    functionRepr = node.get<FunctionTypeRepr *>();
  }

  // The execution behavior changes only for nonisolated functions.
  {
    bool isNonisolated;
    if (functionRepr) {
      isNonisolated = isolation.get<FunctionTypeIsolation>().isNonIsolated();
    } else {
      auto isolation = this->isolation.get<ActorIsolation>();
      isNonisolated = isolation.isNonisolated() || isolation.isUnspecified();
    }

    if (!isNonisolated) {
      return;
    }
  }

  // If the intended behavior is specified explicitly, don't diagnose.
  {
    const DeclAttributes *attrs = nullptr;
    if (decl) {
      attrs = &decl->getAttrs();
    } else if (closure) {
      attrs = &closure->getAttrs();
    }

    if (attrs && attrs->hasAttribute<ExecutionAttr>()) {
      return;
    }
  }

  // The execution behavior changes only for async functions.
  {
    bool isAsync = false;
    if (decl) {
      isAsync = decl->isAsync();
    } else if (closure) {
      isAsync = closure->isBodyAsync();
    } else {
      isAsync = functionRepr->isAsync();
    }

    if (!isAsync) {
      return;
    }
  }

  const ExecutionAttr attr(ExecutionKind::Concurrent, /*implicit=*/true);

  const auto featureName = getFeatureName(feature);
  if (decl) {
    // Diagnose the function, but slap the attribute on the storage declaration
    // instead if the function is an accessor.
    auto *functionDecl = dyn_cast<AbstractFunctionDecl>(decl);
    if (!functionDecl) {
      auto *storageDecl = cast<AbstractStorageDecl>(decl);

      // This whole logic assumes that an 'async' storage declaration only has
      // a getter. Yell for an update if this ever changes.
      ASSERT(!storageDecl->getAccessor(AccessorKind::Set));

      functionDecl = storageDecl->getParsedAccessor(AccessorKind::Get);
    }

    ctx.Diags
        .diagnose(functionDecl->getLoc(),
                  diag::attr_execution_nonisolated_behavior_will_change_decl,
                  featureName, functionDecl, &attr)
        .fixItInsertAttribute(
            decl->getAttributeInsertionLoc(/*forModifier=*/false), &attr);
  } else if (closure) {
    ctx.Diags
        .diagnose(closure->getLoc(),
                  diag::attr_execution_nonisolated_behavior_will_change_closure,
                  featureName, &attr)
        .fixItAddAttribute(&attr, closure);
  } else {
    ctx.Diags
        .diagnose(
            functionRepr->getStartLoc(),
            diag::attr_execution_nonisolated_behavior_will_change_typerepr,
            featureName, &attr)
        .fixItInsertAttribute(functionRepr->getStartLoc(), &attr);
  }
}

void swift::warnAboutNewNonisolatedAsyncExecutionBehavior(
    ASTContext &ctx, FunctionTypeRepr *repr, FunctionTypeIsolation isolation) {
  AsyncCallerExecutionMigrationTarget(ctx, repr, isolation).diagnose();
}

void swift::warnAboutNewNonisolatedAsyncExecutionBehavior(
    ASTContext &ctx, ValueDecl *decl, ActorIsolation isolation) {
  AsyncCallerExecutionMigrationTarget(ctx, decl, isolation).diagnose();
}

void swift::warnAboutNewNonisolatedAsyncExecutionBehavior(
    ASTContext &ctx, AbstractClosureExpr *closure, ActorIsolation isolation) {
  AsyncCallerExecutionMigrationTarget(ctx, closure, isolation).diagnose();
}
