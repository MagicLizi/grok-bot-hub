import SwiftUI

/// 与 `@State` 等价的视图状态。
///
/// macOS 27 SDK 里 `@State` 改成了宏，宏实现（SwiftUIMacros）只随完整 Xcode 提供；
/// 用这个包装器后，只装 Command Line Tools 也能编译。SwiftUI 会递归识别 DynamicProperty 里的 State。
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
