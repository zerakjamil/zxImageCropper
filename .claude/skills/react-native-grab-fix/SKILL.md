---
name: react-native-grab-fix
description: Diagnose and fix React Native Grab selection failures (for example: only parent view is selectable, timers/text are not selectable, Grab misses overlays). Use when the user says Grab/Gram cannot select UI elements.
version: 1.0.0
license: MIT
---

# React Native Grab Fix

## When to Use

Use this skill when a user reports any of the following:
- React Native Grab can only select a parent container, not the intended child element.
- UI text, timers, cards, or overlays cannot be selected in Grab mode.
- Grab appears active but copied context points to a generic container instead of the real element.
- Grab works on some screens but not others.

## Outcome

Restore reliable element-level selection in React Native Grab with minimal UI behavior changes and no gameplay logic changes.

## Workflow

1. Confirm base integration first.
- Verify app root is wrapped with `ReactNativeGrabRoot` (in this repo: `App.js`).
- Verify each native-stack screen is wrapped with `ReactNativeGrabScreen` (in this repo via `withGrabScreen`).
- Verify the screen wrapper includes `ReactNativeGrabContextProvider` metadata.
- Verify Metro is configured with React Native Grab middleware if required by the current setup.

2. Confirm runtime prerequisites.
- Grab requires New Architecture + Fabric. If disabled, selection precision will fail.
- If the project uses custom navigator focus hooks, ensure `setFocusEffect(...)` is configured.

3. Triage native hit-testing blockers (most common root cause).
- Search near the target element for `pointerEvents="none"` on overlay ancestors.
- For overlay containers that should allow child selection, prefer `pointerEvents="box-none"`.
- Keep purely decorative overlays as `pointerEvents="none"`.
- Do not change board interaction layers blindly; apply minimal targeted edits.

4. Triage collapsed/optimized host nodes.
- If Grab keeps selecting a parent wrapper, ensure the target wrapper exists as a host node:
  - add `collapsable={false}` on the smallest stable wrapping `View`.
  - optionally add `nativeID` or `testID` for stable targeting.
- Avoid adding these props to many nodes; keep changes surgical.

5. Validate and iterate.
- Re-run Grab mode and target the previously failing element.
- Confirm copied context includes the correct source file/component.
- Run diagnostics on touched files.

## Guardrails

- Do not modify chess/gameplay logic while fixing Grab issues.
- Do not perform broad style refactors.
- Prefer two or three small patches over a large rewrite.
- Preserve existing touch behavior unless the blocker is exactly pointer-event related.

## Repo-Specific Known Failure Pattern

In `ClassicRankedScreen`, HUD overlays set to `pointerEvents="none"` can prevent Grab from selecting AI name/timer/bottom timer cards. Converting the overlay wrappers to `pointerEvents="box-none"` restores child selection while preserving overlay layout behavior.

## Completion Criteria

- User can select the exact intended element (not just parent containers).
- Grab output maps to the correct screen/component source.
- No new diagnostics in touched files.
