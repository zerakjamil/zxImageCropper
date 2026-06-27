# React Native Grab Quick Checklist

Use this checklist in order. Stop as soon as selection works.

1. Root and screen wrappers
- `App.js` has `ReactNativeGrabRoot`.
- Native-stack screens are wrapped with `withGrabScreen(...)`.
- `withGrabScreen` uses both `ReactNativeGrabScreen` and `ReactNativeGrabContextProvider`.

2. Runtime compatibility
- New Architecture + Fabric enabled.
- If custom router focus handling exists, configure `setFocusEffect`.

3. Pointer event blockers
- Find ancestors of the unselectable element.
- Replace blocking overlay `pointerEvents="none"` with `pointerEvents="box-none"` when children should remain targetable.
- Keep purely decorative overlays as `none`.

4. Native host visibility
- Add `collapsable={false}` to the smallest wrapper around the target element if Grab only returns parent nodes.
- Optionally add `nativeID` or `testID` for stable targeting.

5. Verify
- Re-open Grab mode and target exact element.
- Confirm copied context references the expected source file and component.
- Run file diagnostics.
