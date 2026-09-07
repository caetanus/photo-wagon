# Photo Wagon – AI / Agent README

This document explains the architecture and conventions of the Photo Wagon project for AI assistants.

Photo Wagon is an open-source desktop application focused on local-first photo management with optional peer-to-peer sharing.

---

# Core Philosophy

Photo Wagon follows a few key principles:

- Local-first: Photos never leave the user’s machine by default.
- Content-addressed storage: Files are stored by cryptographic hash.
- Simple UX: Disktop gallery experience similar to Apple Photos.
- Optional decentralization: Sharing works over P2P networking.
- This project always follow the SOLID structure, if we violate a domain, we should split the files accordingly
- We never use Megazord files whatsoever.

---

# Architecture

The project has three layers:

UI (4t/QML)
 down
 Photo Library Service
 down
Content Store

---

# UI layer

Technology:
 - Qt
 - QML

Features:
 - Gallery view
 - Timeline
 - Photo viewer
  - Editing tools

 The UI never accesses files directly. All data comes from the backend service.

---

# Photo Library

Responsibilities:

- indexing photos
- metadata extraction
- album management
- search

Implementation:
 - SQLite
 - OpenCV
  - C++ modules

---

# Content Store

All binary assets are stored by cryptographic hash.

Example structure:

store/
  ab/
    cdef1234
  91/
    ff22a8

Benefits:

- deduplication
- data integrity
- efficient P2P sharing

---

# Metadata

Photo Wagon preserves standard metadata:

- EXIF
- XMP
- IPTC

Important fields:

- timestamp
- GPS coordinates
- camera model
- orientation

---

# Computer Vision

Optional features use OpenCV:

- face detection
- object recognition
- scene classification

---

# Peer-to-Peer Sharing

Sharing uses libp2p2:

- DHT discovery
- QUIC transport
- NAT hole punching
- relay fallback

Albums are shared as content-addressed manifests.

---

# Editing

Editing is non-destructive.

The original image is never modified.

Edits are stored as recipes.

---

# Performance Goals

Large libraries should still feel fast.

Target: 100k photos with smooth scrolling and instant thumbnails.

---

# Project Goal

Photo Wagon aims to be a simple, modern, open-source alternative to Apple Photos with built-in decentralized sharing.
