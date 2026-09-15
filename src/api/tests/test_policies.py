"""Offline structural contracts for the shipped APIM policies and their bindings.

These checks do not execute APIM's C# expressions; deployment tests cover runtime
behavior. XML input is trusted, checked-in repository content only.
"""

import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

MODULES = Path(__file__).resolve().parents[3] / "infra" / "modules"
POLICIES = MODULES / "policies"
POLICY_FILES = sorted(POLICIES.glob("*.xml"))


def policy(name):
    return ET.fromstring((POLICIES / name).read_text())  # noqa: S314


@pytest.mark.parametrize("path", POLICY_FILES, ids=lambda path: path.name)
def test_all_shipped_policies_are_strict_xml_without_cache(path):
    root = ET.fromstring(path.read_text())  # noqa: S314
    assert root.tag == "policies"
    assert [child.tag for child in root] == ["inbound", "backend", "outbound", "on-error"]
    assert not any(element.tag.startswith("cache-") for element in root.iter())


def test_only_current_policy_files_are_shipped():
    assert {path.name for path in POLICY_FILES} == {
        "api-base.xml", "stateless.xml", "blocklist-routing.xml", "analyze-text.xml",
    }


def test_retry_budget_is_only_for_reads_and_not_idempotency_headers():
    roots = [policy(path.name) for path in POLICY_FILES]
    retries = [element for root in roots for element in root.iter("retry")]
    forwards = [element for root in roots for element in root.iter("forward-request")]
    assert len(retries) == len(forwards) == 1
    retry = retries[0]
    condition = retry.attrib["condition"]
    methods = re.findall(r'context\.Request\.Method == "([A-Z]+)"', condition)
    assert methods == ["GET", "HEAD", "OPTIONS"]
    assert condition.startswith(
        '@((context.Request.Method == "GET" || context.Request.Method == "HEAD"'
        ' || context.Request.Method == "OPTIONS") && ',
    )
    assert "Idempotency" not in condition
    assert retry.attrib["count"] == "3"
    assert retry.attrib["max-interval"] == "5"
    assert retry.attrib["first-fast-retry"] == "false"
    assert retry.find("forward-request") is forwards[0]
    timeout = forwards[0].attrib["timeout"]
    assert timeout == "10" or ' ? 10 : 50)' in timeout


def test_direct_gateway_idempotency_is_rejected_before_backend():
    inbound = policy("api-base.xml").find("inbound")
    rejection = inbound.find("choose/when")
    assert rejection.attrib["condition"] == (
        '@(context.Request.Headers.ContainsKey("Idempotency-Key"))'
    )
    status = rejection.find("return-response/set-status")
    assert status.attrib == {"code": "400", "reason": "IdempotencyRequiresFunction"}
    children = list(inbound)
    assert children.index(inbound.find("choose")) < children.index(
        inbound.find("set-backend-service"),
    )


def test_every_named_blocklist_operation_has_the_owner_policy():
    source = (MODULES / "apim.bicep").read_text()
    resources = re.findall(
        r"^resource (\w+) '([^']+)' = \{(.*?)^\}",
        source, flags=re.MULTILINE | re.DOTALL,
    )
    named_operations = {
        symbol for symbol, kind, body in resources
        if "/operations@" in kind and "{blocklistName}" in body
    }
    assert len(named_operations) == 7
    policy_bindings = {}
    for _, kind, body in resources:
        if "/operations/policies@" not in kind:
            continue
        parent = re.search(r"parent:\s*(\w+)", body).group(1)
        value = re.search(r"value:\s*(\w+)", body).group(1)
        assert parent not in policy_bindings
        policy_bindings[parent] = value
    assert all(policy_bindings[name] == "blocklistPolicy" for name in named_operations)
    assert "var blocklistPolicy = loadTextContent('policies/blocklist-routing.xml')" in source
    assert "var analyzeTextPolicy = loadTextContent('policies/analyze-text.xml')" in source
    assert policy_bindings["opAnalyzeText"] == "analyzeTextPolicy"
    assert policy_bindings["opListBlocklists"] == "statelessPolicy"


def test_named_routes_and_text_analysis_use_identical_owner_algorithm():
    named = policy("blocklist-routing.xml")
    analyze = policy("analyze-text.xml")
    for root in (named, analyze):
        expression = root.find("inbound/set-variable").attrib["value"]
        assert re.search(
            r"System\.Security\.Cryptography\.SHA256\.Create\(\)\.ComputeHash\("
            r"System\.Text\.Encoding\.UTF8\.GetBytes\((?:\(string\))?name\)\)",
            expression,
        )
        assert 'hash[0] % 2 == 0 ? "cs-primary" : "cs-secondary"' in expression
        assert not list(root.iter("retry"))
        assert [element.attrib["backend-id"] for element in root.iter("set-backend-service")] == [
            '@((string)context.Variables["blocklistBackend"])',
        ]
        assert root.find("inbound/base") is not None
    named_expression = named.find("inbound/set-variable").attrib["value"]
    assert 'MatchedParameters["blocklistName"]' in named_expression
    analyze_expression = analyze.find("inbound/set-variable").attrib["value"]
    assert "preserveContent: true" in analyze_expression
    assert 'body["blocklistNames"]' in analyze_expression
    assert 'if (owner != "" && owner != backend) { return "mixed"; }' in analyze_expression
    branches = analyze.findall("inbound/choose/when")
    assert '"mixed"' in branches[0].attrib["condition"]
    assert '"invalid"' in branches[0].attrib["condition"]
    assert branches[0].find("return-response/set-status").attrib["code"] == "400"
    assert branches[1].find("set-backend-service") is not None
