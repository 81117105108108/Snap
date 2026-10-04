@echo Off

mkdir "./bundle"
copy ".\src\Error.rbxmx" ".\bundle\Error.rbxmx"
copy ".\src\Widget.rbxmx" ".\bundle\Widget.rbxmx"

REM Bundle with larvae (root config, plugin profile). The canonical release flow
REM is `lune run build` from the repo root, which additionally folds
REM _G.RELEASE/_G.VERSION; this legacy path leaves those reads intact, so its
REM headers report 0.0.0 just like a dev build.
larvae bundle --config "../larvae.toml" --profile plugin --entry "./src/init.server.luau" --out "./bundle/init.server.lua"
rojo build --plugin "Blink.rbxmx"

cd ..
rojo sourcemap --output sourcemap.json --include-non-scripts
cd plugin