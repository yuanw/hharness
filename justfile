# Justfile for hharness monorepo

# Regenerate .cabal files from package.yaml
regen-cabal:
    cd hharness-ai && hpack --force
    cd hharness-agent && hpack --force
    cabal-fmt --inplace hharness-ai/hharness-ai.cabal
    cabal-fmt --inplace hharness-agent/hharness-agent.cabal

# Build everything
cabal-build:
    cabal build all

# Run tests
test:
    cabal test all

# Check formatting and lints
check:
    fourmolu --mode check hharness-ai/src/ hharness-agent/src/
    cabal-fmt --check hharness-ai/hharness-ai.cabal hharness-agent/hharness-agent.cabal
    hlint .

# Auto-format everything
fmt:
    fourmolu --mode inplace hharness-ai/src/ hharness-agent/src/
    cabal-fmt --inplace hharness-ai/hharness-ai.cabal hharness-agent/hharness-agent.cabal
