import SwiftUI

/// Stand-in for SwiftUI's `@State` when building with the Command Line Tools, whose toolchain
/// ships without the SwiftUI macro plugin. Wraps a plain `SwiftUI.State` (a nested DynamicProperty).
@propertyWrapper
struct FState<Value>: DynamicProperty {
    private let storage: SwiftUI.State<Value>
    init(wrappedValue: Value) { storage = SwiftUI.State(initialValue: wrappedValue) }
    init(initialValue: Value) { storage = SwiftUI.State(initialValue: initialValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}

extension FState where Value: ExpressibleByNilLiteral {
    init() { self.init(wrappedValue: nil) }
}
