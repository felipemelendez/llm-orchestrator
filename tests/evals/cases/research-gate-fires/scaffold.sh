#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
mkdir -p payments
printf '%s' 'IiIiQ2hhcmdlIGNhbGxzIGFnYWluc3QgdGhlIHBheW1lbnQgcHJvdmlkZXIuCgpUaGUgcmV0cnkgZmxvdyBhcm91bmQgdGhlc2UgY2FsbHMgaXMgYmVpbmcgZGVzaWduZWQ7IG5vdGhpbmcgcmV0cmllcyB5ZXQuCiIiIgoKCmRlZiBjaGFyZ2UoY3VzdG9tZXJfaWQsIGFtb3VudF9jZW50cyk6CiAgICAiIiJTaW5nbGUgY2hhcmdlIGF0dGVtcHQuIFJhaXNlcyBvbiB0cmFuc2llbnQgcHJvdmlkZXIgZXJyb3JzLiIiIgogICAgcmFpc2UgTm90SW1wbGVtZW50ZWRFcnJvcigiY2hhcmdlIHRyYW5zcG9ydCBpcyBzdHViYmVkIGluIHRoaXMgc2NyYXRjaCByZXBvIikK' | base64 -d > payments/charge.py
printf '%s' 'IyBiaWxsaW5nLXNlcnZpY2UKClNtYWxsIGJpbGxpbmcgc2VydmljZS4gQ2hhcmdlcyBydW4gdGhyb3VnaCB0aGUgcGF5bWVudCBwcm92aWRlcidzIFNESzsgYQpyZXRyeSBmbG93IGZvciB0cmFuc2llbnQgY2hhcmdlIGZhaWx1cmVzIGlzIGJlaW5nIGRlc2lnbmVkLgo=' | base64 -d > README.md
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm 'baseline: billing service with stubbed charge call' 2>/dev/null || true
