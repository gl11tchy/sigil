"""Accept only the owner-approved REA-1350 pointer-permission skip exception."""

POINTER_TESTS = {
    "SidebarVersionNoticeTests/theRenderedSeamReceivesRealMouseEventsAtBothEdges()",
    "SidebarVersionNoticeTests/clickingACappedRenderedSeamPreservesThePreferenceAndFocusesIt()",
    "SidebarVersionNoticeTests/terminalSelectionKeepsTheWindowStationary()",
    "SidebarVersionNoticeTests/notesEditorSelectionKeepsTheWindowStationary()",
}
OTHER_TESTS = {
    "SidebarVersionNoticeTests/thousandSessionTwentyRowHoverSweep()",
    "SidebarVersionNoticeTests/threeNoticesPreserveTheListViewportInANarrowShortSidebar()",
}


def validate(summary, tree, test_status):
    def cases(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                yield node
            yield from cases(node.get("children", []))

    nodes = list(cases(tree.get("testNodes", [])))
    outcomes = {node.get("nodeIdentifier"): node.get("result") for node in nodes}
    if test_status != 0 or len(nodes) != 6 or set(outcomes) != POINTER_TESTS | OTHER_TESTS:
        raise ValueError("Expected one successful run of the exact six hosted fixtures")
    if any(outcomes[test] != "Passed" for test in OTHER_TESTS):
        raise ValueError("Both unrelated hosted fixtures must pass without skips")
    counts = tuple(summary.get(key) for key in ("passedTests", "failedTests", "skippedTests"))
    if counts == (6, 0, 0) and all(outcomes[test] == "Passed" for test in POINTER_TESTS):
        return "six fixtures passed, no retries or skips"
    if counts == (2, 0, 4) and all(outcomes[test] == "Skipped" for test in POINTER_TESTS):
        return (
            "two fixtures passed; four REA-1350 pointer fixtures skipped because event-posting "
            "permission is unavailable. Owner-approved manual verification remains pending"
        )
    raise ValueError("Only all four REA-1350 permission skips are allowed; pointer failures remain failures")
