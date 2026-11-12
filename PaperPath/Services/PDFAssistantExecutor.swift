#if DEBUG && !PAPERPATH_REVIEW_BUILD
import Foundation

@MainActor
struct PDFAssistantExecutor {
    /// Only validated, reviewed plans reach the existing PDF engine. Each intermediate
    /// copy is committed to Library and reported immediately, even if a later step fails.
    func execute(_ plan: PDFAssistantPlan, model: PaperPathModel,
                 completed: (Int, DocumentRecord) -> Void,
                 progress: (Int) -> Void) async throws {
        try plan.validate()
        var previous: DocumentRecord?
        for (index, step) in plan.steps.enumerated() {
            try Task.checkCancellation()
            guard plan.files.allSatisfy({ file in
                let current = model.record(id: file.id)
                return current?.contentRevisionID == file.revisionID && current?.deletedAt == nil
            }) else { throw PDFAssistantError.changedFiles }
            let records = try step.inputs.map { number -> DocumentRecord in
                if number == 0, let previous,
                   let current = model.record(id: previous.id), current.contentRevisionID == previous.contentRevisionID {
                    return current
                }
                guard let file = plan.files.first(where: { $0.number == number }),
                      let record = model.record(id: file.id), !record.profile.isLocked else {
                    throw PDFAssistantError.changedFiles
                }
                return record
            }
            progress(index)
            let result: DocumentRecord?
            switch step.action {
            case .merge:
                result = await model.combineDocuments(recordIDs: records.map(\.id), name: "Assistant combined copy".localizedUI)
            case .extract:
                let source = records[0]
                result = await model.extractPages(recordID: source.id,
                    indices: Set((step.firstPage...step.lastPage).map { $0 - 1 }),
                    expectedContentRevisionID: source.contentRevisionID)
            case .compress:
                let source = records[0]
                result = await model.createCompressedCopy(recordID: source.id, quality: .balanced,
                    mode: .preserveContent, expectedContentRevisionID: source.contentRevisionID)
            }
            guard let result else {
                if Task.isCancelled { throw CancellationError() }
                throw PDFAssistantError.failedOperation
            }
            previous = result
            completed(index, result)
        }
    }
}

#endif
