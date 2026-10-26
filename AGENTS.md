# Release checks

- Before every version update, recheck official model pricing for the providers in `Resources/pricing.json`, even when the release is primarily a bug fix or performance improvement.
- Update confirmed price changes and missing current model mappings in the same release. Preserve complete previous entries in dated `price_history` segments; never apply a new rate indiscriminately to older usage.
- Record the audit date, sources, actual changes and any unverified scope in `docs/`. If prices did not change, leave the pricing JSON untouched so a documentation-only recheck does not invalidate usage caches.
- Keep release commit messages factual about application behavior and network overhead; do not include user-specific network providers, routes or traffic measurements.
