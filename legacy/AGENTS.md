# AGENTS.md

## Photo Wagon — AI Agent Guide

This file describes how AI assistants should interact with the Photo Wagon codebase.

Project goal: build a modern open-source photo manager with optional P2P sharing.

### Rules for AI contributions

1. Do not introduce cloud dependencies.
   - The project is local-first. User data must not require a remote service.

2. Preserve open metadata.
   - Keep compatibility with EXIF / XMP / IPTC where applicable.

3. Keep the code simple.
   - Avoid over-engineering and unnecessary dependencies.

4. Prefer offline computation.
   - Photo analysis should be performed locally (OpenCV).

5. Respect the layered architecture.
   - UI must not access storage directly.
   - UI talks to the backend service API.

### Coding style

#### C++
- Use modern C++ (C++17+).
- Prefer RAII and smart pointers.
- Avoid manual ownership and global mutable state.

#### QML
- Keep components small and composable.
- Avoid heavy logic in QML.
- Move business logic to backend modules.

### P2P notes
P2P sharing uses libp2p for:
- peer discovery
- DHT routing
- QUIC transport
- NAT traversal

### Goal
Maintain a small, readable, hackable codebase.
