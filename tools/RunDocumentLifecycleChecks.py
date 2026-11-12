#!/usr/bin/env python3
"""Verify one-document saving, recoverable history and explicit exports.
Uses the compression runner's existing-device, exclusive-gate implementation.
Default: generic iOS compilation. --runtime: focused service/model/UI tests.
"""
import RunCompressionChecks as runner

runner.OWNER = 'PaperPath/document lifecycle regression'
runner.TESTS = [
    'PaperPathTests/PDFDocumentLifecycleTests',
    'PaperPathTests/PDFCompressionDepthTests',
    'PaperPathTests/PDFCriticalFeatureContractTests/testRestoreVersion_sidecarCleanupFailureRollsBack_BitsUT',
    'PaperPathTests/PDFCriticalFeatureContractTests/testRestoreVersion_checkpointCleanupFailurePreservesPages_BitsUT',
    'PaperPathTests/PDFCriticalFeatureContractTests/testWorkingCopyTransaction_recoversAfterRollbackFailure_BitsUT',
    'PaperPathTests/PDFCriticalFeatureContractTests/testModel_cancelledCompressionReleasesProcessingState_BitsUT',
    'PaperPathTests/PaperPathTests/testModelCreatesCheckedEditableCopyFromSessionPassword',
    'PaperPathUITests/PaperPathUITests/testCompressionAndContentEditingStayInSameDocument',
    'PaperPathUITests/PaperPathUITests/testCompressionMethodsRemainActionableWithAdvisoryEstimate',
]

if __name__ == '__main__':
    raise SystemExit(runner.main())
