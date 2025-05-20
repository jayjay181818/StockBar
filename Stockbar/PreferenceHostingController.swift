import Cocoa
import SwiftUI

class PreferenceHostingController: NSHostingController<PreferenceView> {
    init(userData: DataModel) {
        super.init(rootView: PreferenceView(userdata: userData))
    }
    
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}