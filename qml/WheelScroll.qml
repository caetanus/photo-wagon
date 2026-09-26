import QtQuick

// The one scroll-wheel behaviour of every desktop view (the grid, Years/Months, People,
// Places, Memories, Moments, the sidebar): the same distance per notch whatever the view's
// tile size, a touchpad's pixel deltas taken the same way, and a short glide instead of a
// jump — notches in quick succession add up to one target. Each view had its own (a row and
// a half of photos here, one card there, 384 px in People, the touchpad falling back to Qt's
// own flick physics in two of them), so scrolling felt different from view to view.
WheelHandler {
    id: wheel
    required property Flickable flick
    /// pixels per notch of a mouse wheel
    property real notch: 240
    /// multiplier of a touchpad's pixel deltas
    property real touchpadGain: 3
    /// after each wheel event (a view that pages more in near the end listens)
    signal scrolled()

    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    property real target: 0
    property real lastWritten: 0
    function bounded(y) {
        const min = flick.originY
        const max = flick.originY + Math.max(0, flick.contentHeight - flick.height)
        return Math.max(min, Math.min(max, y))
    }
    onWheel: (ev) => {
        ev.accepted = true
        if (ev.pixelDelta.y !== 0) {
            // a touchpad: follow the fingers directly (its own deltas are already smooth)
            glide.stop()
            flick.contentY = wheel.bounded(flick.contentY - ev.pixelDelta.y * wheel.touchpadGain)
        } else {
            // a mouse notch: glide to the target; notches during a glide extend it
            const from = glide.running ? wheel.target : flick.contentY
            wheel.target = wheel.bounded(from - ev.angleDelta.y / 120 * wheel.notch)
            if (!glide.running) {
                wheel.lastWritten = flick.contentY
                glide.start()
            }
        }
        wheel.scrolled()
    }
    // A glide approached frame by frame (about 120 ms): each frame re-bounds the target (the
    // content may shrink or its origin move meanwhile) and gives up at once if something else
    // moved the view since the last frame (a key, the scroll bar, a drag) — it never writes
    // over another interaction.
    property FrameAnimation glide: FrameAnimation {
        onTriggered: {
            const f = wheel.flick
            if (Math.abs(f.contentY - wheel.lastWritten) > 0.5 || f.moving) { stop(); return }
            const t = wheel.bounded(wheel.target)
            let next = f.contentY + (t - f.contentY) * (1 - Math.exp(-frameTime / 0.035))
            if (Math.abs(t - next) < 0.5) next = t
            f.contentY = next
            wheel.lastWritten = next
            if (next === t) stop()
        }
    }
}
