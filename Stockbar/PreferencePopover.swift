import Cocoa
import SwiftUI

class PreferencePopover: NSPopover {
    private let userdata: DataModel
    
    init(data: DataModel) {
        self.userdata = data
        super.init()
        
        let preferenceViewController = PreferenceViewController(userdata: userdata)
        self.contentViewController = preferenceViewController
        self.behavior = .transient
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}