import CarPlay
import Combine
import NovaKit
import NovaNav
import NovaVoice
import UIKit

/// T-080 / ios-architecture §11.5: a CarPlay template scene with no logic of its own. It shows the
/// assistant state and the choice list from the same snapshots as the phone screen, and a row tap sends
/// the same `UIIntent` (I-6). Inert until the CarPlay entitlement exists and the scene is declared in the
/// Info.plist scene manifest (OQ-IOS-8 decides the category); nothing references it before that.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var observation: AnyCancellable?
    private let list = CPListTemplate(title: "小诺", sections: [])

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let runtime = RuntimeHolder.shared.runtime
        interfaceController.setRootTemplate(list, animated: false, completion: nil)
        render(runtime.model)
        observation = runtime.model.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires before the change lands: read on the next turn of the run loop.
            DispatchQueue.main.async { self?.render(runtime.model) }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        observation = nil
        self.interfaceController = nil
    }

    private func render(_ model: DriveModel) {
        let status = CPListItem(text: Self.chipText(model.view.chip), detailText: model.view.subtitle)
        var sections = [CPListSection(items: [status], header: "状态", sectionIndexTitle: nil)]
        let presentation = MapPresentation(model.nav)
        let rows: [CPListItem]
        switch presentation.list {
        case .places:
            rows = model.nav.places.map { CPListItem(text: $0.name, detailText: $0.address) }
        case .routes:
            rows = model.nav.routes.map { route in
                CPListItem(text: "\(max(1, route.durationSeconds / 60)) 分钟",
                           detailText: "\(Double(route.lengthMeters / 100) / 10) 公里")
            }
        case nil:
            rows = []
        }
        for (index, row) in rows.enumerated() {
            row.handler = { _, completion in
                Task { @MainActor in
                    await RuntimeHolder.shared.runtime.tapChoice(row: index)
                    completion()
                }
            }
        }
        if !rows.isEmpty { sections.append(CPListSection(items: rows, header: "请选择", sectionIndexTitle: nil)) }
        list.updateSections(sections)
    }

    static func chipText(_ chip: AssistantChip) -> String {
        switch chip {
        case .idle: "未连接"
        case .listening: "请说"
        case .processing: "处理中"
        case .speaking: "说话中"
        case .error: "出错"
        }
    }
}
