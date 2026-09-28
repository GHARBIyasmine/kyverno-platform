#!/usr/bin/env bash
#
# Applies each demo manifest in order and reports whether the outcome
# matched what the filename promises (allowed-and-possibly-mutated vs
# blocked). For the auto-fixed cases, also prints the specific field the
# mutation changed, so you can see the paved-roads policies working
# without having to diff the whole object by hand.
#
# Usage: ./demo.sh          (run the demo)
#        ./demo.sh cleanup  (delete demo-orders and demo-no-labels only)

set -uo pipefail
cd "$(dirname "$0")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ "${1:-}" == "cleanup" ]]; then
  echo "Deleting demo namespaces..."
  kubectl delete namespace demo-orders demo-no-labels --ignore-not-found
  exit 0
fi

pass_count=0
fail_count=0

expect_allowed() {
  local file="$1" label="$2"
  if kubectl apply -f "$file" >/tmp/demo-out 2>&1; then
    echo -e "${GREEN}✔ ALLOWED${NC} (expected)  $label"
    ((pass_count++))
  else
    echo -e "${RED}✘ BLOCKED${NC} (unexpected) $label"
    sed 's/^/    /' /tmp/demo-out
    ((fail_count++))
  fi
}

expect_blocked() {
  local file="$1" label="$2"
  if kubectl apply -f "$file" >/tmp/demo-out 2>&1; then
    echo -e "${RED}✘ ALLOWED${NC} (unexpected) $label"
    ((fail_count++))
  else
    echo -e "${GREEN}✔ BLOCKED${NC} (expected)  $label"
    ((pass_count++))
  fi
}

show_field() {
  # show_field <kind> <name> <namespace> <jsonpath> <description>
  local kind="$1" name="$2" ns="$3" path="$4" desc="$5"
  local val
  val=$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath="$path" 2>/dev/null)
  echo -e "    ${YELLOW}mutated:${NC} $desc = $val"
}

echo "=== 1. Namespace + scaffolding ==="
expect_allowed 01-compliant-namespace.yaml "demo-orders namespace (should trigger 4 generated resources)"
sleep 2  # give the generate policies a moment to react before we check
for gvk in "resourcequota default-resource-quota" "limitrange default-limit-range" "networkpolicy default-deny-all" "externalsecret default-external-secret"; do
  kind=$(echo "$gvk" | cut -d' ' -f1)
  name=$(echo "$gvk" | cut -d' ' -f2)
  if kubectl get "$kind" "$name" -n demo-orders >/dev/null 2>&1; then
    echo -e "    ${GREEN}✔ generated:${NC} $kind/$name"
  else
    echo -e "    ${RED}✘ missing:${NC} $kind/$name (scaffolding didn't fire yet -- check background-controller)"
  fi
done

echo
echo "=== 2. Clean workload ==="
expect_allowed 02-clean-deployment.yaml "clean-app (fully compliant already)"

echo
echo "=== 3. Paved-roads auto-fixes (should be ALLOWED despite non-compliant input) ==="
expect_allowed 03-auto-fixed-missing-resources.yaml "missing-resources-app (no resources block)"
show_field deployment missing-resources-app demo-orders '{.spec.template.spec.containers[0].resources}' "backfilled resources"

expect_blocked 04-block-unverified-images.yaml "unsigned images (ghcr.io/gharbiyasmine/kyverno-demo-unsigned:1.0.0)"

expect_allowed 05-auto-fixed-privileged.yaml "privileged-app (allowPrivilegeEscalation: true, runAsUser: 0)"
show_field deployment privileged-app demo-orders '{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' "corrected allowPrivilegeEscalation"
show_field deployment privileged-app demo-orders '{.spec.template.spec.containers[0].securityContext.runAsUser}' "corrected runAsUser"

echo
echo "=== 4. Guardrails with no auto-fix (should be BLOCKED) ==="
expect_blocked 06-blocked-latest-tag.yaml "latest-tag-app (:latest tag)"
expect_blocked 07-blocked-hostnetwork.yaml "hostnetwork-app (hostNetwork: true)"
expect_blocked 08-blocked-hostpath.yaml "hostpath-app (hostPath volume)"
expect_blocked 09-blocked-raw-secret.yaml "raw-demo-secret (direct Secret creation)"
expect_blocked 10-blocked-namespace-no-labels.yaml "demo-no-labels (missing team/environment labels)"

echo
echo "=== Summary ==="
echo -e "${GREEN}$pass_count matched expectation${NC}, ${RED}$fail_count did not${NC}"
echo
echo "Run './demo.sh cleanup' to remove demo-orders / demo-no-labels."

[[ $fail_count -eq 0 ]]
