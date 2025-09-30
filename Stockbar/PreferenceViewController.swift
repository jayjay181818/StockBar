import Cocoa
import SwiftUI

class PreferenceViewController: NSViewController {
    private let userdata: DataModel
    
    init(userdata: DataModel) {
        self.userdata = userdata
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let preferenceView = PreferenceView(userdata: userdata)
        let hostingController = NSHostingController(rootView: preferenceView)
        self.addChild(hostingController)
        self.view = hostingController.view
    }
}