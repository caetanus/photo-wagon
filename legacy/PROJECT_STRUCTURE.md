# PROJECT_STRUCTURE.md

## Repository Layout

PhotoWagon/
  README.md
  AGENTS.md
  ARCHITECTURE.md
  PROJECT_STRUCTURE.md
  ROADMAP.md

src/
  photowagond/
    api/
    core/
    store/
    metadata/
    thumbs/
    indexer/
    db/
    jobs/
    util/

ui/
  qml/
  assets/
  cpp/

p2p/
  photowagon-p2pd/
  proto/

tests/
  unit/
  integration/

scripts/
  dev/

### Boundaries

Backend:
- owns database
- owns blob store

UI:
- presentation only
- talks to backend API

P2P:
- networking sidecar
- content distribution
