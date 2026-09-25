#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
printf '%s' 'IiIiVmFsdWUgaGFuZGxlcnMuCgpFdmVyeSBoYW5kbGVyIGlzIGEgb25lLWFyZ3VtZW50IGZ1bmN0aW9uIHJlZ2lzdGVyZWQgaW4gSEFORExFUlMgYmVsb3cuCmRpc3BhdGNoKCkgaXMgdGhlIG9ubHkgcHVibGljIGVudHJ5IHBvaW50LgoiIiIKCgpkZWYgaWRlbnRpdHkodmFsdWUpOgogICAgcmV0dXJuIHZhbHVlCgoKZGVmIHN0cmluZ2lmeSh2YWx1ZSk6CiAgICByZXR1cm4gc3RyKHZhbHVlKQoKCkhBTkRMRVJTID0gewogICAgImlkZW50aXR5IjogaWRlbnRpdHksCiAgICAic3RyaW5naWZ5Ijogc3RyaW5naWZ5LAp9CgoKZGVmIGRpc3BhdGNoKG5hbWUsIHZhbHVlKToKICAgIHJldHVybiBIQU5ETEVSU1tuYW1lXSh2YWx1ZSkK' | base64 -d > registry.py
printf '%s' 'ZnJvbSByZWdpc3RyeSBpbXBvcnQgZGlzcGF0Y2gKCmFzc2VydCBkaXNwYXRjaCgiaWRlbnRpdHkiLCA3KSA9PSA3CmFzc2VydCBkaXNwYXRjaCgic3RyaW5naWZ5IiwgNykgPT0gIjciCnByaW50KCJleGlzdGluZyBjaGVja3MgcGFzc2VkIikK' | base64 -d > test_registry.py
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null || true
