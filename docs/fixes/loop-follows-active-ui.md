# Periodic loop stays on the file manager after opening a book

Status: fixed on branch [`fix/loop-follows-active-ui`](https://github.com/ardyln/hatelemetry.koplugin/tree/fix/loop-follows-active-ui), not yet proposed upstream. Affects v0.4.0 (upstream `806d038`).

## Symptoms

With **Periodic updates while awake** turned on, start KOReader on the file manager (or any library screen) and then open a book. Until the device next sleeps and wakes:

- Home Assistant shows the book fields as `unknown` while you are reading: `sensor.koreader_book_title`, `sensor.koreader_current_page` and the rest.
- The ha-koreader **Next page** / **Previous page** buttons do nothing. The same goes for every command that acts on the open book: `page_turn`, `goto_page`, `goto_chapter` and `toggle_bookmark`.
- Device-level commands (frontlight, warmth, Wi-Fi, messages) still work.

The shorter the update interval, the worse it gets: with an interval of a few seconds, nearly every check-in comes from the loop, so page turns from Home Assistant look completely broken.

One sleep/wake cycle with the book open makes everything work again, until KOReader restarts.

## Cause

KOReader creates a new instance of each plugin whenever it switches between the file manager and the reader. `HATelemetry:init()` starts the periodic loop only on the first one:

```lua
if not HATelemetry._initialized then
    HATelemetry._initialized = true
    if self.settings.loop_enabled then
        self:pushLoop(true)
    end
    ...
end
```

So the loop stays bound to whichever instance KOReader created first. If that was the file manager, every periodic push runs `collect()` and `commandDeps()` against the file manager's `self.ui`. That UI has no document, so the book fields are empty, and `GotoViewRel` / `GotoPage` / `ToggleBookmark` events sent to it are ignored.

Two things hide the bug:

- `onReaderReady()` and `onCloseDocument()` push from the reader's own instance, so HA sees the book briefly when it opens. The next loop push then overwrites it with `unknown`.
- `onResume()` calls `self:pushLoop(true)` on the instance that is active at that moment, which moves the loop to the reader. That is why a sleep/wake cycle fixes it.

## Fix

Each new instance takes the loop over. `pushLoop` is the same function for all instances, so `UIManager:unschedule(self.pushLoop)` removes the previous instance's loop before starting it again on `self`. The one-time startup push stays behind `_initialized`.

```diff
     self.ui.menu:registerToMainMenu(self)
     self:loadSettings()

+    -- KOReader creates a new plugin instance on every reader/file manager switch.
+    -- Move the periodic loop to it, so pushes and commands use the UI on screen.
+    if self.settings.loop_enabled then
+        UIManager:unschedule(self.pushLoop)
+        self:pushLoop(true)
+    end
+
     if not HATelemetry._initialized then
         HATelemetry._initialized = true
-        if self.settings.loop_enabled then
-            self:pushLoop(true)
-        end
         if self.settings.enabled then
             self:push(true)
         end
```

## Tests

`spec/main_spec.lua` loads `main.lua` with small fakes for the KOReader modules it needs. It creates a file manager instance and then a reader instance, and checks that:

- exactly one loop is scheduled, and it belongs to the reader instance;
- a page turn from the loop's command handlers reaches the reader's UI, not the file manager's;
- no loop is scheduled when periodic updates are off.

The first two fail on v0.4.0 and pass with the fix. The full suite passes: 55 tests on Lua 5.1, the same setup as the repo's CI.

## Tested on

- Boox Go Color 7 Gen II, Android 13
- KOReader v2026.03
- ha-koreader v0.6.0, webhook mode, update interval 1 s

Steps: start KOReader on the library screen, open a book, press Next page and Previous page in Home Assistant.

- **Before the fix:** the book shows as `unknown` in HA and the page does not turn.
- **After the fix:** when the book opens, the loop moves to `ReaderUI`. HA shows the book and page, and both page turns arrive in about 1.2 s, with no sleep/wake.

Not yet tested on a device: closing the book, going back to the library and opening another one. The same handover in `init()` covers that path, and the spec exercises it in isolation.

## Proposed pull request

- **Branch:** [`fix/loop-follows-active-ui`](https://github.com/ardyln/hatelemetry.koplugin/tree/fix/loop-follows-active-ui), one commit with the change to `main.lua` and the new spec.
- **Compare against upstream:** [hudsonbrendon/hatelemetry.koplugin `main`...`fix/loop-follows-active-ui`](https://github.com/hudsonbrendon/hatelemetry.koplugin/compare/main...ardyln:hatelemetry.koplugin:fix/loop-follows-active-ui)
- **Title:** `fix: move the periodic loop to the active UI instance`
