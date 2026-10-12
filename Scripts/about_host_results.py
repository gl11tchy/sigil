"""Require the one native About app-host fixture, without retries or skips."""


EXPECTED = "AboutBuildIdentityHostTests/nativeAboutPanelShowsIdentityAndClosePreservesTabs()"


def validate(summary, tree, test_status):
    def cases(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                yield node
            yield from cases(node.get("children", []))

    nodes = list(cases(tree.get("testNodes", [])))
    if (test_status != 0 or len(nodes) != 1 or nodes[0].get("nodeIdentifier") != EXPECTED
            or nodes[0].get("result") != "Passed"
            or tuple(summary.get(key) for key in ("passedTests", "failedTests", "skippedTests")) != (1, 0, 0)):
        raise ValueError("Expected the exact native About fixture to pass with no retries or skips")
    return "native About identity/Close passed, no retries or skips"
