//===--- _SwiftCxxInteroperability.h - C++ Interop support ------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  Defines types and support functions required by C++ bindings generated
//  by the Swift compiler that allow C++ code to call Swift APIs.
//
//===----------------------------------------------------------------------===//
#ifndef SWIFT_CXX_INTEROPERABILITY_H
#define SWIFT_CXX_INTEROPERABILITY_H

#ifdef __cplusplus

#include <cstdint>
#include <stdlib.h>
#include <cstdint>
#if defined(_WIN32)
#include <malloc.h>
#endif
#if !defined(SWIFT_CALL)
# define SWIFT_CALL __attribute__((swiftcall))
#endif

// FIXME: Use always_inline, artificial.
#define SWIFT_INLINE_THUNK inline

namespace swift {
namespace _impl {

extern "C" void *_Nonnull swift_retain(void *_Nonnull) noexcept;

extern "C" void swift_release(void *_Nonnull) noexcept;

inline void *_Nonnull opaqueAlloc(size_t size, size_t align) noexcept {
#if defined(_WIN32)
  void *r = _aligned_malloc(size, align);
#else
  if (align < sizeof(void *))
    align = sizeof(void *);
  void *r = nullptr;
  int res = posix_memalign(&r, align, size);
  (void)res;
#endif
  return r;
}

inline void opaqueFree(void *_Nonnull p) noexcept {
#if defined(_WIN32)
  _aligned_free(p);
#else
  free(p);
#endif
}

/// Base class for a container for an opaque Swift value, like resilient struct.
class OpaqueStorage {
public:
  inline OpaqueStorage() noexcept : storage(nullptr) {}
  inline OpaqueStorage(size_t size, size_t alignment) noexcept
      : storage(reinterpret_cast<char *>(opaqueAlloc(size, alignment))) {}
  inline OpaqueStorage(OpaqueStorage &&other) noexcept
      : storage(other.storage) {
    other.storage = nullptr;
  }
  inline OpaqueStorage(const OpaqueStorage &) noexcept = delete;

  inline ~OpaqueStorage() noexcept {
    if (storage) {
      opaqueFree(static_cast<char *_Nonnull>(storage));
    }
  }

  void operator=(OpaqueStorage &&other) noexcept {
    auto temp = storage;
    storage = other.storage;
    other.storage = temp;
  }
  void operator=(const OpaqueStorage &) noexcept = delete;

  inline char *_Nonnull getOpaquePointer() noexcept {
    return static_cast<char *_Nonnull>(storage);
  }
  inline const char *_Nonnull getOpaquePointer() const noexcept {
    return static_cast<char *_Nonnull>(storage);
  }

private:
  char *_Nullable storage;
};

/// Base class for a Swift reference counted class value.
class RefCountedClass {
public:
  inline ~RefCountedClass() { swift_release(_opaquePointer); }
  inline RefCountedClass(const RefCountedClass &other) noexcept
      : _opaquePointer(other._opaquePointer) {
    swift_retain(_opaquePointer);
  }
  inline RefCountedClass &operator=(const RefCountedClass &other) noexcept {
    swift_retain(other._opaquePointer);
    swift_release(_opaquePointer);
    _opaquePointer = other._opaquePointer;
    return *this;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-noreturn"
  // FIXME: implement 'move'?
  inline RefCountedClass(RefCountedClass &&) noexcept { abort(); }
#pragma clang diagnostic pop

protected:
  inline RefCountedClass(void *_Nonnull ptr) noexcept : _opaquePointer(ptr) {}

private:
  void *_Nonnull _opaquePointer;
  friend class _impl_RefCountedClass;
};

class _impl_RefCountedClass {
public:
  static inline void *_Nonnull getOpaquePointer(const RefCountedClass &object) {
    return object._opaquePointer;
  }
  static inline void *_Nonnull &getOpaquePointerRef(RefCountedClass &object) {
    return object._opaquePointer;
  }
};

} // namespace _impl

/// Swift's Int type.
using Int = ptrdiff_t;

/// Swift's UInt type.
using UInt = size_t;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc++17-extensions"

/// True if the given type is a Swift type that can be used in a generic context
/// in Swift.
template <class T>
static inline const constexpr bool isUsableInGenericContext = false;

/// Returns the type metadata for the given Swift type T.
template <class T> struct TypeMetadataTrait {
  static inline void *_Nonnull getTypeMetadata();
};

namespace _impl {

/// Type trait that returns the `_impl::_impl_<T>` class type for the given
/// class T.
template <class T> struct implClassFor {
  // using type = ...;
};

/// True if the given type is a Swift value type.
template <class T> static inline const constexpr bool isValueType = false;

/// True if the given type is a Swift value type with opaque layout that can be
/// boxed.
template <class T> static inline const constexpr bool isOpaqueLayout = false;

/// True if the given type is a C++ record that was bridged to Swift, giving
/// Swift ability to work with it in a generic context.
template <class T>
static inline const constexpr bool isSwiftBridgedCxxRecord = false;

/// Returns the opaque pointer to the given value.
template <class T>
inline const void *_Nonnull getOpaquePointer(const T &value) {
  if constexpr (isOpaqueLayout<T>)
    return reinterpret_cast<const OpaqueStorage &>(value).getOpaquePointer();
  return reinterpret_cast<const void *>(&value);
}

template <class T> inline void *_Nonnull getOpaquePointer(T &value) {
  if constexpr (isOpaqueLayout<T>)
    return reinterpret_cast<OpaqueStorage &>(value).getOpaquePointer();
  return reinterpret_cast<void *>(&value);
}

} // namespace _impl

extern "C" void *_Nonnull swift_errorRetain(void *_Nonnull swiftError) noexcept;

extern "C" void swift_errorRelease(void *_Nonnull swiftError) noexcept;

extern "C" int $ss5ErrorMp; // external global %swift.protocol, align 4

extern "C"
    const void * _Nullable
    swift_getTypeByMangledNameInContext(
        const char *_Nullable typeNameStart,
        size_t typeNameLength,
        const void *_Nullable context,
        const void *_Nullable const *_Nullable genericArgs) SWIFT_CALL;

extern "C" bool swift_dynamicCast(void *_Nullable dest, void *_Nullable src,
                                  const void *_Nullable srcType,
                                  const void * _Nullable targetType,
                                  uint32_t flags);

struct SymbolicP {
  alignas(2) uint8_t _1;
  uint32_t _2;
  uint8_t _3[2];
  uint8_t _4;
} __attribute__((packed));

inline const void *_Nullable testErrorCall() {
  static swift::SymbolicP errorSymbol;
  static int *_Nonnull got_ss5ErrorMp = &$ss5ErrorMp;
  errorSymbol._1 = 2;
  errorSymbol._2 = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(&got_ss5ErrorMp) - reinterpret_cast<uintptr_t>(&errorSymbol._2));
  errorSymbol._3[0] = '_';
  errorSymbol._3[1] = 'p';
  errorSymbol._4 = 0;
  static_assert(sizeof(errorSymbol) == 8, "");
  auto charErrorSymbol = reinterpret_cast<const char *>(&errorSymbol);

  const void *ptr2 =
      swift::swift_getTypeByMangledNameInContext(charErrorSymbol,
                                                 sizeof(errorSymbol) - 1,
                                                 nullptr, nullptr);
  return ptr2;
}

class Error {
public:
  Error() {}
  Error(void* _Nonnull swiftError) { opaqueValue = swiftError; }
  ~Error() {
    if (opaqueValue)
      swift_errorRelease(opaqueValue);
  }
  void* _Nonnull getPointerToOpaquePointer() { return opaqueValue; }
  Error(Error &&other) : opaqueValue(other.opaqueValue) {
    other.opaqueValue = nullptr;
  }
  Error(const Error &other) {
    if (other.opaqueValue)
      swift_errorRetain(other.opaqueValue);
    opaqueValue = other.opaqueValue;
  }

  // FIXME: Return a Swift::Optional instead.
  template<class T>
  T as() {
    alignas(alignof(T)) char buffer[sizeof(T)];
    const void *em = testErrorCall();
    void *ep = getPointerToOpaquePointer();
    auto metadata = swift::TypeMetadataTrait<T>::getTypeMetadata();

    // Dynamic cast will release the error, so we need to retain it.
    swift::swift_errorRetain(ep);
    bool dynamicCast =
        swift::swift_dynamicCast(buffer, &ep, em, metadata,
                                 /*take on success  destroy on failure*/ 6);

    if (dynamicCast) {
      return swift::_impl::implClassFor<T>::type::returnNewValue([&](char *dest) {
            swift::_impl::implClassFor<T>::type::initializeWithTake(dest, buffer);
          });
    }
    abort();
    // FIXME: return nil.
  }

private:
  void * _Nonnull opaqueValue = nullptr;
};

#pragma clang diagnostic pop

} // namespace swift
#endif

#endif // SWIFT_CXX_INTEROPERABILITY_H
