//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if !$Embedded && os(Windows)

import Swift

// The default executors for now are Dispatch-based
typealias PlatformMainExecutor = DispatchMainExecutor
typealias PlatformDefaultExecutor = DispatchTaskExecutor

#endif // os(Windows)
