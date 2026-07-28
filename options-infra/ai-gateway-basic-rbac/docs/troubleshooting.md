# Troubleshooting

## `azd up` fails at `preprovision-rbac-sps`

- **`Insufficient privileges to complete the operation`** — the deploying identity needs `Application Developer` (or higher) in the Entra tenant to create SPs. Ask a tenant admin to grant it, then rerun.
- **`az ad app credential reset` returns 429** — you're hitting the Graph credential-add rate limit. Wait a few minutes and re-run; existing app regs are reused.

## Pytest can't authenticate as a persona

- The `.env` file may be stale after a redeploy. Re-run the postprovision hook: `sh ../scripts/postprovision-write-tests-env.sh`.
- Check `RBAC_SP_SECRETS_JSON` in `tests/.env` — if it's `{}`, the preprovision hook didn't rotate secrets. Re-run `azd provision`.

## `test_role_definitions.py` fails

- Microsoft may have renamed a role. Check `tests/output/foundry-role-definitions.actual.json` and update `config/role-definitions.expected.json` if the change is intentional.

## Negative tests report `ManualRequired` for N-07 (Teams publish)

Expected. There is no stable ARM/data-plane API for `/microsoft365/publish` accessible to a plain builder token. Validate via `docs/manual-ui-test-plan.md` UI-11.

## Positive tests report `ManualRequired` for B-03..B-05, B-07

Expected. Tool/knowledge/guardrail/workflow creation is UI-driven or uses tenant-rollout endpoints not stable across Foundry versions. Validate via the manual UI checklist.

## Builder can create resource X (test unexpectedly passes negative side)

This is a **Fail** per the spec — the access model isn't enforced. Verify:
1. The builder SP really only has `Foundry User` at project scope (`test_assignments.py` catches broad inherited roles).
2. The deploying identity didn't accidentally leave the builder SP with `Contributor` on the subscription/RG.
3. No Azure Policy is loosening RBAC.
