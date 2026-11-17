import Foundation

enum Assets {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Ribbon_Ribbon", withExtension: "bundle"),
           let resources = Bundle(url: url) {
            return resources
        }
        return .module
    }()
}
