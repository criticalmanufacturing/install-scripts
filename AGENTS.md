# Repository guidance

For changes or reviews involving `platform/v11.3`, `platform/v12.0`, their Helm charts, or shared installer/chart code, read [.agents/skills/helm-dependency-examples/SKILL.md](.agents/skills/helm-dependency-examples/SKILL.md).

The skill describes the version-specific layout, version-specific invariants, Helm lifecycle boundaries and explicit storage recovery. Keep changes scoped to the requested versions and verify affected consumers of shared code.
