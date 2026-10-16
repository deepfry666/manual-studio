import Foundation

// MARK: - 已提交
//
// 标成「已提交」的项目只读：不能运行、改文字、改图、换模板、重新导出；批量操作自动跳过。要改先取消标记。

public func isSubmitted(_ state: JSON?) -> Bool { state?["submitted"]?["at"].isTruthy ?? false }

func assertNotSubmitted(_ state: JSON?) throws {
    if isSubmitted(state) { throw StudioError("这个项目已标为「已提交」，只能查看；要修改请先取消已提交") }
}
