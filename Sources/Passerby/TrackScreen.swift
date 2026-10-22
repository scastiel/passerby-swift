import SwiftUI

extension View {
  /// Records a View of the named Screen on every `onAppear` of this view: a tab shown three
  /// times is three Views.
  public func trackScreen(_ name: String, props: [String: Property] = [:]) -> some View {
    onAppear { Passerby.view(name, props: props) }
  }
}
